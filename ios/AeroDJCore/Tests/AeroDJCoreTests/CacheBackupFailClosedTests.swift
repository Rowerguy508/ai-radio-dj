import XCTest
@testable import AeroDJCore

/// A marker whose mark can throw, or succeed but read back as not excluded.
private final class FlakyExclusion: BackupExclusionMarking, @unchecked Sendable {
    enum Mode { case works, throwsOnMark, readsBackUnset }
    private let lock = NSLock()
    private var _calls = 0
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }
    var calls: Int { lock.withLock { _calls } }
    func markExcluded(_ directory: URL) throws {
        lock.withLock { _calls += 1 }
        if mode == .throwsOnMark { throw CocoaError(.fileWriteNoPermission) }
    }
    func isExcluded(_ directory: URL) -> Bool? {
        switch mode {
        case .works: return true
        case .throwsOnMark: return false
        case .readsBackUnset: return false
        }
    }
}

private struct OneShotVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data("pcm".utf8), durationSeconds: 1.5, billableUnits: 0, provider: "avspeech", cacheKey: nil)
    }
}

/// #278 P1 (Sentinel): if Voice/Cache cannot be marked excluded from backup, no clip is written to
/// it, and personal clips already in it are deleted on open. Playback continues from memory.
final class CacheBackupFailClosedTests: XCTestCase {
    private var root: URL!
    private var dir: URL { root.appendingPathComponent("Voice/Cache") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-failclosed-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func personal(_ byte: UInt8 = 7) -> CachedAudio {
        CachedAudio(data: Data([byte]), seconds: 1, providerID: "avspeech", voiceID: "v", sourceItemIDs: [UUID()])
    }

    private func shared(_ byte: UInt8 = 1) -> CachedAudio {
        CachedAudio(data: Data([byte]), seconds: 1, providerID: "avspeech", voiceID: "v")
    }

    /// Names of every file under the cache folder (empty if the folder is missing).
    private func filesOnDisk() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func cache(_ mode: FlakyExclusion.Mode, log: @escaping @Sendable (String) -> Void = { _ in }) -> FileAudioCache {
        FileAudioCache(directory: dir, backupExclusion: FlakyExclusion(mode), backupExclusionLog: log)
    }

    // MARK: 1. A failed mark writes nothing

    func testAThrowingMarkOnCreateWritesNoFileAndStillServesTheClip() async throws {
        let cache = cache(.throwsOnMark)
        await cache.store(personal(9), for: "secretkey123")
        await cache.store(shared(2), for: "station-id")

        XCTAssertEqual(filesOnDisk(), [], "no clip may land in a folder that is not excluded from backup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("secretkey123.json").path))
        let personalRead = await cache.audio(for: "secretkey123")
        let sharedRead = await cache.audio(for: "station-id")
        XCTAssertEqual(personalRead?.data, Data([9]), "served from memory for this session")
        XCTAssertEqual(sharedRead?.data, Data([2]))
        let count = await cache.fileCount()
        XCTAssertEqual(count.files, 0)

        // Rendering through the closed cache still plays, and still writes nothing.
        let renderer = VoiceRenderer(
            routes: [VoiceRoute(providerID: "avspeech", provider: OneShotVoice(), voice: VoiceProfile(id: "host", name: "Host"),
                                timeout: .seconds(5), acceptsSSML: true)],
            budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let cue = NarrationCue(id: UUID(), order: 1, group: 1, kind: .transition, text: "That was Song 1.", estimatedSeconds: 2,
                               maxSeconds: 12, sourceItemID: nil, source: nil, provenance: nil)
        let rendered = try await renderer.render(cue, userID: "u", stationID: "s").get()
        XCTAssertEqual(rendered.attempts.map(\.result), [.rendered])
        XCTAssertEqual(filesOnDisk(), [])
    }

    func testAMarkThatReadsBackUnsetCountsAsAFailure() async {
        let lines = LockedLines()
        let cache = cache(.readsBackUnset, log: { lines.append($0) })
        await cache.store(personal(), for: "p")
        XCTAssertEqual(filesOnDisk(), [], "set without error but not excluded: still fail closed")
        XCTAssertEqual(lines.all, ["AeroDJ.cache backup exclusion failed moment=create"])
        let read = await cache.audio(for: "p")
        XCTAssertNotNil(read)
    }

    func testOnceClosedTheSessionStaysClosedEvenIfTheFolderIsRecreated() async throws {
        let cache = cache(.throwsOnMark)
        await cache.store(personal(), for: "a")
        try? FileManager.default.removeItem(at: dir)
        await cache.store(personal(), for: "b")
        XCTAssertEqual(filesOnDisk(), [])
        // A copy of the value shares the closed gate.
        let copy = cache
        await copy.store(shared(), for: "c")
        XCTAssertEqual(filesOnDisk(), [])
    }

    func testPurgesReachClipsHeldInMemory() async {
        let cache = cache(.throwsOnMark)
        let item = UUID()
        await cache.store(CachedAudio(data: Data([3]), seconds: 1, providerID: "avspeech", voiceID: "v", sourceItemIDs: [item]), for: "one")
        await cache.store(personal(), for: "two")
        await cache.store(shared(), for: "s")
        await cache.purge(sourceItemIDs: [item])
        let one = await cache.audio(for: "one")
        XCTAssertNil(one, "a revoked item's clip is gone from memory too")
        await cache.purgeAllPersonal()
        let two = await cache.audio(for: "two")
        let s = await cache.audio(for: "s")
        XCTAssertNil(two)
        XCTAssertNotNil(s, "shared clips are not personal")
    }

    // MARK: 2. A failed mark on open purges personal clips

    func testAFailedMarkOnOpenDeletesPersonalClipsAndWritesNothingMore() async throws {
        let good = cache(.works)
        await good.store(personal(), for: "personal-a")
        await good.store(personal(), for: "personal-b")
        await good.store(shared(), for: "station-id")
        // Unattributable audio (no metadata) counts as personal, as in purgeAllPersonal.
        try Data([0]).write(to: dir.appendingPathComponent("orphan.caf"))
        XCTAssertEqual(filesOnDisk(), ["orphan.caf", "personal-a.json", "personal-b.json", "station-id.json"])

        // Next launch: the restore dropped the flag and it cannot be set again.
        let lines = LockedLines()
        let reopened = cache(.throwsOnMark, log: { lines.append($0) })
        XCTAssertEqual(lines.all, ["AeroDJ.cache backup exclusion failed moment=open"])
        XCTAssertEqual(filesOnDisk(), ["station-id.json"], "personal clips are deleted before the cache is used")
        let gone = await reopened.audio(for: "personal-a")
        let kept = await reopened.audio(for: "station-id")
        XCTAssertNil(gone)
        XCTAssertNotNil(kept, "non-personal clips are not purged")

        await reopened.store(personal(5), for: "personal-c")
        XCTAssertEqual(filesOnDisk(), ["station-id.json"], "and nothing new is written this session")
        let held = await reopened.audio(for: "personal-c")
        XCTAssertEqual(held?.data, Data([5]))
    }

    func testAnOpenThatReadsBackUnsetAlsoPurges() async {
        await cache(.works).store(personal(), for: "p")
        _ = cache(.readsBackUnset)
        XCTAssertEqual(filesOnDisk(), [])
    }

    func testTheNextOpenRetriesTheMarkAndResumesDiskWrites() async {
        let failing = FlakyExclusion(.throwsOnMark)
        await FileAudioCache(directory: dir, backupExclusion: failing, backupExclusionLog: { _ in }).store(personal(), for: "a")
        XCTAssertEqual(failing.calls, 1)
        XCTAssertEqual(filesOnDisk(), [])

        let working = FlakyExclusion(.works)
        let next = FileAudioCache(directory: dir, backupExclusion: working, backupExclusionLog: { _ in })
        XCTAssertEqual(working.calls, 1, "the next open tries the mark again")
        await next.store(personal(), for: "b")
        XCTAssertEqual(filesOnDisk(), ["b.json"], "once marked, clips are cached on disk again")
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func append(_ line: String) { lock.withLock { lines.append(line) } }
}
