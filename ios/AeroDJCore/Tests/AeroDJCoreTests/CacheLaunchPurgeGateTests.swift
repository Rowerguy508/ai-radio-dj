import XCTest
@testable import AeroDJCore

/// A one-shot barrier: `wait()` returns once `open()` has been called (before or after).
private final class PurgeBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(c); return false
            }
            if resumeNow { c.resume() }
        }
    }
    func open() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true; defer { waiters = [] }; return waiters
        }
        toResume.forEach { $0.resume() }
    }
}

/// The app's `FileAudioCache` as the sweeper sees it, except that the launch purge is held at a
/// barrier until the test opens it (the window #82 F3 is about). Reads go to the file cache
/// directly, as the renderer's do.
private struct HeldLaunchPurgeCache: AudioCache, LaunchPurgeGated {
    let base: FileAudioCache
    let barrier: PurgeBarrier
    let started: AsyncStream<Void>.Continuation
    func beginLaunchPurge() { base.beginLaunchPurge() }
    func audio(for key: String) async -> CachedAudio? { await base.audio(for: key) }
    func store(_ audio: CachedAudio, for key: String) async { await base.store(audio, for: key) }
    func purge(sourceItemIDs: Set<UUID>) async { await base.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await base.purgeExpired() }
    func purgeAllPersonal() async { await base.purgeAllPersonal() }
    func purgePersonalItems() async {
        started.yield()
        await barrier.wait()
        await base.purgePersonalItems()
    }
}

extension HeldLaunchPurgeCache: AudioCacheCounting {
    func fileCount() async -> AudioCacheCount { await base.fileCount() }
}

/// #82 F3 (-Sentinel): the launch purge runs detached while the renderer reads the cache at once.
/// A personal clip left by an earlier launch must never be served before that purge completes.
final class CacheLaunchPurgeGateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-gate-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func clip(_ byte: UInt8, sources: [UUID]) -> CachedAudio {
        CachedAudio(data: Data([byte]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: sources)
    }

    private func filesOnDisk() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// The previous launch leaves a personal clip, an all-lines-only clip and a generic clip.
    private func seedPreviousLaunch() async {
        let earlier = FileAudioCache(directory: dir)
        await earlier.store(clip(1, sources: [UUID()]), for: "personal")
        await earlier.store(clip(2, sources: [VoiceRenderer.allLinesClipTag]), for: "library")
        await earlier.store(clip(3, sources: []), for: "generic")
    }

    /// Starts the production launch sweep on a fresh cache over `dir`, with its purge held.
    private func relaunchWithHeldPurge() -> (cache: FileAudioCache, barrier: PurgeBarrier,
                                            started: AsyncStream<Void>, launched: AsyncStream<String?>,
                                            task: Task<Void, Never>, finish: () -> Void) {
        let cache = FileAudioCache(directory: dir)
        let barrier = PurgeBarrier()
        let (started, startedC) = AsyncStream<Void>.makeStream()
        let (launched, launchedC) = AsyncStream<String?>.makeStream()
        let held = HeldLaunchPurgeCache(base: cache, barrier: barrier, started: startedC)
        let task = AudioCacheSweeper.startPurgingPersonalFirst(held, every: .seconds(3600),
                                                        onLaunchSweep: { launchedC.yield($0) })
        return (cache, barrier, started, launched, task, { startedC.finish(); launchedC.finish() })
    }

    func testPreviousLaunchPersonalClipIsNeverServedBeforeTheLaunchPurgeCompletes() async throws {
        await seedPreviousLaunch()
        let launch = relaunchWithHeldPurge()
        defer { launch.task.cancel(); launch.finish() }

        // Right after start returns, before the purge task has even run.
        let immediate = await launch.cache.audio(for: "personal")
        XCTAssertTrue(immediate == nil, "no read may beat the launch purge to an earlier launch's personal clip")

        var started = launch.started.makeAsyncIterator()
        _ = await started.next()                                   // the purge is running, held
        let during = await launch.cache.audio(for: "personal")
        XCTAssertTrue(during == nil, "withheld while the purge is held")
        XCTAssertTrue(filesOnDisk().contains("personal.json"), "the purge has really not run yet")
        let generic = await launch.cache.audio(for: "generic")
        XCTAssertTrue(generic != nil, "non-personal clips are served as usual")

        launch.barrier.open()
        var launched = launch.launched.makeAsyncIterator()
        _ = await launched.next()
        let after = await launch.cache.audio(for: "personal")
        XCTAssertTrue(after == nil, "gone after the purge")
        XCTAssertFalse(filesOnDisk().contains("personal.json"))
    }

    func testAllLinesOnlyClipIsServedDuringAndAfterTheLaunchPurge() async throws {
        await seedPreviousLaunch()
        let launch = relaunchWithHeldPurge()
        defer { launch.task.cancel(); launch.finish() }
        var started = launch.started.makeAsyncIterator()
        _ = await started.next()
        let during = await launch.cache.audio(for: "library")
        XCTAssertEqual(during?.data, Data([2]), "all-lines-only clips are kept between launches, so never withheld")

        launch.barrier.open()
        var launched = launch.launched.makeAsyncIterator()
        _ = await launched.next()
        let after = await launch.cache.audio(for: "library")
        XCTAssertEqual(after?.data, Data([2]), "still served once the gate opens")
        XCTAssertEqual(filesOnDisk(), ["generic.json", "library.json"])
    }

    /// A personal clip rendered in this launch during the window is served, and the purge (which
    /// only targets earlier launches) does not wipe it, even when it overwrites an earlier key.
    func testAClipStoredDuringTheWindowIsServedAndSurvivesThePurge() async throws {
        await seedPreviousLaunch()
        let launch = relaunchWithHeldPurge()
        defer { launch.task.cancel(); launch.finish() }
        var started = launch.started.makeAsyncIterator()
        _ = await started.next()
        await launch.cache.store(clip(9, sources: [UUID()]), for: "fresh")
        await launch.cache.store(clip(8, sources: [UUID()]), for: "personal")   // same key, this launch
        let fresh = await launch.cache.audio(for: "fresh")
        XCTAssertEqual(fresh?.data, Data([9]))
        let overwritten = await launch.cache.audio(for: "personal")
        XCTAssertEqual(overwritten?.data, Data([8]), "this launch's clip, not the earlier one")

        launch.barrier.open()
        var launched = launch.launched.makeAsyncIterator()
        let line = await launched.next()
        let freshAfter = await launch.cache.audio(for: "fresh")
        let personalAfter = await launch.cache.audio(for: "personal")
        XCTAssertEqual(freshAfter?.data, Data([9]), "the purge keeps clips stored in this launch")
        XCTAssertEqual(personalAfter?.data, Data([8]))
        XCTAssertEqual(filesOnDisk(), ["fresh.json", "generic.json", "library.json", "personal.json"])
        XCTAssertEqual(line ?? nil, "AeroDJ.cache narration cache count=4 personal=3 after=launch",
                       "the launch count matches the files on disk")
    }

    /// Reads never wait on the gate: a cache with no launch purge started (tests, direct
    /// `prepareForLaunch`, `purgingPersonalFirst: false`) serves as before, and a gate that opened
    /// leaves nothing withheld.
    func testNoDeadlockAndNoGateWithoutAPendingLaunchPurge() async throws {
        await seedPreviousLaunch()
        let unstarted = FileAudioCache(directory: dir)
        let served = await unstarted.audio(for: "personal")
        XCTAssertEqual(served?.data, Data([1]), "never started: unchanged behaviour, no wait")

        let noPurge = FileAudioCache(directory: dir)
        let (launched, launchedC) = AsyncStream<String?>.makeStream()
        let task = AudioCacheSweeper(cache: noPurge).start(every: .seconds(3600),
                                                           onLaunchSweep: { launchedC.yield($0) })
        let immediate = await noPurge.audio(for: "personal")
        XCTAssertEqual(immediate?.data, Data([1]), "no personal purge asked for: no gate")
        var it = launched.makeAsyncIterator()
        _ = await it.next()
        task.cancel(); launchedC.finish()

        let direct = FileAudioCache(directory: dir)
        await AudioCacheSweeper(cache: direct).prepareForLaunch(purgingPersonalFirst: true)
        await direct.store(clip(5, sources: [UUID()]), for: "later")
        let later = await direct.audio(for: "later")
        XCTAssertEqual(later?.data, Data([5]), "after the purge, new personal clips read back normally")
        let gone = await direct.audio(for: "personal")
        XCTAssertTrue(gone == nil)
    }
}
