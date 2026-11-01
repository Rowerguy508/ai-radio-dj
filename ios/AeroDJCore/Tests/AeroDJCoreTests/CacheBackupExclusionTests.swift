import XCTest
@testable import AeroDJCore

/// Records every folder it is asked to mark; optionally fails, as a sandbox or volume can.
private final class RecordingExclusion: BackupExclusionMarking, @unchecked Sendable {
    private let lock = NSLock()
    private var _marked: [String] = []
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    /// Folder paths (no trailing slash), in call order.
    var marked: [String] { lock.withLock { _marked } }
    func markExcluded(_ directory: URL) throws {
        lock.withLock { _marked.append(Self.path(directory)) }
        if fails { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: directory.path]) }
    }
    func isExcluded(_ directory: URL) -> Bool? { lock.withLock { _marked.contains(Self.path(directory)) } }
    static func path(_ url: URL) -> String { url.standardizedFileURL.path.hasSuffix("/") ? String(url.standardizedFileURL.path.dropLast()) : url.standardizedFileURL.path }
}

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
}

private struct OneShotVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data("pcm".utf8), durationSeconds: 1.5, billableUnits: 0, provider: "avspeech", cacheKey: nil)
    }
}

/// Voice/Cache (the spoken-clip cache) is excluded from iCloud and computer backup.
final class CacheBackupExclusionTests: XCTestCase {
    private var root: URL!
    private var dir: URL { root.appendingPathComponent("Voice/Cache") }
    private var p: String { RecordingExclusion.path(dir) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-backup-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func clip() -> CachedAudio {
        CachedAudio(data: Data([1, 2, 3]), seconds: 1, providerID: "avspeech", voiceID: "v")
    }

    func testCreatingTheFolderMarksItExcluded() async {
        let marker = RecordingExclusion()
        let cache = FileAudioCache(directory: dir, backupExclusion: marker)
        XCTAssertEqual(marker.marked, [], "no folder yet: nothing to mark, nothing created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        await cache.store(clip(), for: "a")
        XCTAssertEqual(marker.marked, [p], "marked once when store creates the folder")
        XCTAssertEqual(marker.isExcluded(dir), true)

        await cache.store(clip(), for: "b")
        XCTAssertEqual(marker.marked, [p], "an existing folder is not re-created")
    }

    func testReopeningAnExistingFolderReappliesTheFlag() async {
        await FileAudioCache(directory: dir, backupExclusion: RecordingExclusion()).store(clip(), for: "a")
        // Next launch (or after a restore that dropped the flag): opening re-applies it.
        let marker = RecordingExclusion()
        _ = FileAudioCache(directory: dir, backupExclusion: marker)
        XCTAssertEqual(marker.marked, [p])
        _ = FileAudioCache(directory: dir, backupExclusion: marker)
        XCTAssertEqual(marker.marked, [p, p], "every open applies it")
    }

    func testDeletingAndRecreatingTheFolderMarksItAgain() async throws {
        let marker = RecordingExclusion()
        let cache = FileAudioCache(directory: dir, backupExclusion: marker)
        await cache.store(clip(), for: "a")
        XCTAssertEqual(marker.marked.count, 1)

        try FileManager.default.removeItem(at: dir)
        await cache.store(clip(), for: "b")
        XCTAssertEqual(marker.marked, [p, p], "the re-created folder is marked again")
        let served = await cache.audio(for: "b")
        XCTAssertNotNil(served)
    }

    func testAFailureIsLoggedWithoutPrivateDataAndPlaybackContinues() async throws {
        let marker = RecordingExclusion(fails: true)
        let sink = LogSink()
        // A path a real user could have: the log line must carry none of it.
        let personal = root.appendingPathComponent("Ana Lopez/Voice/Cache")
        let cache = FileAudioCache(directory: personal, backupExclusion: marker, backupExclusionLog: { sink.append($0) })
        let sourced = CachedAudio(data: Data([9]), seconds: 1, providerID: "avspeech", voiceID: "v", sourceItemIDs: [UUID()])
        await cache.store(sourced, for: "secretkey123")
        let read = await cache.audio(for: "secretkey123")
        XCTAssertEqual(read?.data, Data([9]), "the clip is still stored and served")

        _ = FileAudioCache(directory: personal, backupExclusion: marker, backupExclusionLog: { sink.append($0) })
        XCTAssertEqual(sink.lines, ["AeroDJ.cache backup exclusion failed moment=create",
                                    "AeroDJ.cache backup exclusion failed moment=open"])
        for line in sink.lines {
            for needle in ["Ana", "Lopez", "Voice", "Cache", "secretkey123", root.lastPathComponent, "/", "denied", "permission"] {
                XCTAssertFalse(line.contains(needle), "log line leaks \(needle)")
            }
        }

        // Rendering through the cache still plays.
        let renderer = VoiceRenderer(
            routes: [VoiceRoute(providerID: "avspeech", provider: OneShotVoice(), voice: VoiceProfile(id: "host", name: "Host"),
                                timeout: .seconds(5), acceptsSSML: true)],
            budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let cue = NarrationCue(id: UUID(), order: 1, group: 1, kind: .transition, text: "That was Song 1.", estimatedSeconds: 2,
                               maxSeconds: 12, sourceItemID: nil, source: nil, provenance: nil)
        let rendered = try await renderer.render(cue, userID: "u", stationID: "s").get()
        XCTAssertEqual(rendered.attempts.map(\.result), [.rendered])
    }

    func testDefaultMarkerIsFoundationAndReadsTheFlagBackFromTheURL() async throws {
        let cache = FileAudioCache(directory: dir)
        XCTAssertTrue(cache.backupExclusion is FoundationBackupExclusion, "production uses the real resource value")
        await cache.store(clip(), for: "a")
        #if canImport(Darwin)
        let values = try URL(fileURLWithPath: dir.path, isDirectory: true).resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, "Voice/Cache is excluded from iCloud and computer backup")
        try FileManager.default.removeItem(at: dir)
        await cache.store(clip(), for: "b")
        let again = try URL(fileURLWithPath: dir.path, isDirectory: true).resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(again.isExcludedFromBackup, true, "re-created folder is excluded too")
        #else
        // Linux has no backup and no such resource value: the marker is a no-op and reports nil.
        XCTAssertNoThrow(try FoundationBackupExclusion().markExcluded(dir))
        XCTAssertNil(FoundationBackupExclusion().isExcluded(dir))
        #endif
    }
}
