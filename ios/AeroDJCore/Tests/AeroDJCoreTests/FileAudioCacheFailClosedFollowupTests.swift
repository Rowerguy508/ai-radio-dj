import XCTest
@testable import AeroDJCore

/// A marker whose mark fails, and which runs `duringMark` while the first mark is in progress
/// (the window in which a concurrent store used to write into the unmarked folder).
private final class RacingExclusion: BackupExclusionMarking, @unchecked Sendable {
    private let lock = NSLock()
    private var _marks = 0
    var duringMark: (@Sendable () -> Void)?
    func markExcluded(_ directory: URL) throws {
        let first = lock.withLock { () -> Bool in _marks += 1; return _marks == 1 }
        if first { duringMark?() }
        throw CocoaError(.fileWriteNoPermission)
    }
    func isExcluded(_ directory: URL) -> Bool? { false }
}

/// A marker whose mark succeeds but whose read-back throws (Darwin read failure).
private struct ThrowingReadBack: BackupExclusionMarking {
    func markExcluded(_ directory: URL) throws {}
    func isExcluded(_ directory: URL) throws -> Bool? { throw CocoaError(.fileReadUnknown) }
}

/// #412 follow-ups (Fry 6630564311 n1-n5, Echo's #412 nits).
final class FileAudioCacheFailClosedFollowupTests: XCTestCase {
    private var root: URL!
    private var dir: URL { root.appendingPathComponent("Voice/Cache") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-followup-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func clip(_ byte: UInt8, personal: Bool = true, provider: String = "avspeech") -> CachedAudio {
        CachedAudio(data: Data([byte]), seconds: 1, providerID: provider, voiceID: "v",
                    sourceItemIDs: personal ? [UUID()] : [])
    }

    private func filesOnDisk() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// n1: store A creates the folder and its mark fails; a store B that starts inside that window
    /// must not write into the unmarked folder. B is given 1s to finish inside the window: before
    /// the fix it wrote `b.json` there and A's emptiness check then kept the unmarked folder.
    func testAConcurrentStoreDuringAFailedMarkNeverWritesToTheUnmarkedFolder() async throws {
        let marker = RacingExclusion()
        let cache = FileAudioCache(directory: dir, backupExclusion: marker, backupExclusionLog: { _ in })
        let bClip = clip(2)
        let bDone = DispatchSemaphore(value: 0)
        let bTask = LockedBox<Task<Void, Never>?>(nil)
        marker.duringMark = {
            bTask.value = Task.detached { await cache.store(bClip, for: "b"); bDone.signal() }
            _ = bDone.wait(timeout: .now() + 1)
        }
        await cache.store(clip(1), for: "a")
        await bTask.value?.value

        XCTAssertEqual(filesOnDisk(), [], "no clip may land in a folder whose mark failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "no unmarked folder is left behind")
        let a = await cache.audio(for: "a"), b = await cache.audio(for: "b")
        XCTAssertEqual(a?.data, Data([1]), "A is served from memory")
        XCTAssertEqual(b?.data, Data([2]), "B is served from memory")
    }

    /// n2: a read-back that throws counts as not excluded: nothing is written, the folder goes.
    func testAThrowingReadBackCountsAsNotExcluded() async {
        let lines = LockedBox<[String]>([])
        let cache = FileAudioCache(directory: dir, backupExclusion: ThrowingReadBack(),
                                   backupExclusionLog: { line in lines.value.append(line) })
        await cache.store(clip(5), for: "k")
        XCTAssertEqual(filesOnDisk(), [])
        XCTAssertTrue(cache.diskGate.isClosed)
        XCTAssertEqual(lines.value, [CacheBackupExclusionLog.message(.create)])
        XCTAssertFalse(cache.applyBackupExclusion(.open))
    }

    /// n2, on open: an existing folder whose read-back throws loses its personal clips.
    func testAThrowingReadBackOnOpenPurgesPersonalClips() async {
        let ok = FileAudioCache(directory: dir, backupExclusion: OkExclusion(), backupExclusionLog: { _ in })
        await ok.store(clip(1), for: "personal")
        await ok.store(clip(2, personal: false), for: "generic")
        let reopened = FileAudioCache(directory: dir, backupExclusion: ThrowingReadBack(), backupExclusionLog: { _ in })
        XCTAssertEqual(filesOnDisk(), ["generic.json"], "generic clips stay on disk by design (n3)")
        XCTAssertTrue(reopened.diskGate.isClosed)
    }

    /// n4: a direct call on the concrete actor runs the real purge, not the protocol's no-op.
    func testADirectPurgeClipsCallOnTheMemoryCacheRemovesCloudClips() async {
        let memory = InMemoryAudioCache()
        await memory.store(clip(1, provider: "cloud"), for: "cloud")
        await memory.store(clip(2, provider: "device"), for: "device")
        await memory.purgeClips(keepingProviders: ["device"])
        let cloud = await memory.audio(for: "cloud"), device = await memory.audio(for: "device")
        XCTAssertNil(cloud)
        XCTAssertNotNil(device)
    }

    /// n4, through FileAudioCache: the memory fallback obeys the cloud purge.
    func testTheFileCachePurgeClipsReachesItsMemoryFallback() async {
        let cache = FileAudioCache(directory: dir, backupExclusion: ThrowingReadBack(), backupExclusionLog: { _ in })
        await cache.store(clip(1, provider: "cloud"), for: "cloud")
        await cache.purgeClips(keepingProviders: ["device"])
        let cloud = await cache.audio(for: "cloud")
        XCTAssertNil(cloud)
    }

    /// n5 (Fry, Echo): clips held in memory count in fileCount and so in the launch log.
    func testMemoryHeldClipsAreCountedAndLogged() async {
        let cache = FileAudioCache(directory: dir, backupExclusion: ThrowingReadBack(), backupExclusionLog: { _ in })
        await cache.store(clip(1), for: "p")
        await cache.store(clip(2, personal: false), for: "g")
        let count = await cache.fileCount()
        XCTAssertEqual(count, AudioCacheCount(files: 2, personal: 1))
        let line = await AudioCacheSweeper(cache: cache).prepareForLaunch(purgingPersonalFirst: false)
        XCTAssertEqual(line, AudioCacheFileLog.message(count, after: .launch))
    }
}

private struct OkExclusion: BackupExclusionMarking {
    func markExcluded(_ directory: URL) throws {}
    func isExcluded(_ directory: URL) -> Bool? { true }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
