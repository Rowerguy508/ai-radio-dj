import XCTest
@testable import AeroDJCore

/// A one-shot barrier: `wait()` returns once `open()` has been called (before or after).
private final class HardCheckBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(c); return false
            }
            if now { c.resume() }
        }
    }
    func open() {
        lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true; defer { waiters = [] }; return waiters
        }.forEach { $0.resume() }
    }
}

/// Storage that outlives a "launch", like a disk.
private final class UngatedDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var clips: [String: CachedAudio] = [:]
    var dropWrites = false
    subscript(key: String) -> CachedAudio? {
        get { lock.withLock { clips[key] } }
        set { lock.withLock { clips[key] = newValue } }
    }
    func removeAll(where drop: (CachedAudio) -> Bool) { lock.withLock { clips = clips.filter { !drop($0.value) } } }
    var keys: [String] { lock.withLock { clips.keys.sorted() } }
}

/// A persistent cache that is NOT `LaunchPurgeGated` (a future cache, or a wrapper that does not
/// forward the gate). Its launch purge is held at a barrier, the window #82 F3 is about. A write
/// can be dropped silently, leaving whatever was at the key.
private struct UngatedPersistentCache: AudioCache {
    let disk: UngatedDisk
    let barrier: HardCheckBarrier
    let started: AsyncStream<Void>.Continuation
    func audio(for key: String) async -> CachedAudio? { disk[key] }
    func store(_ audio: CachedAudio, for key: String) async { if !disk.dropWrites { disk[key] = audio } }
    func purge(sourceItemIDs: Set<UUID>) async { disk.removeAll { !Set($0.sourceItemIDs).isDisjoint(with: sourceItemIDs) } }
    func purgeExpired() async {}
    func purgeAllPersonal() async { disk.removeAll { !$0.sourceItemIDs.isEmpty } }
    func purgePersonalItems() async {
        started.yield()
        await barrier.wait()
        disk.removeAll(where: \.hasPersonalItem)
    }
}

/// #637 follow-up (-Sentinel, Nova's nit): the launch purge used to accept any cache and only a
/// Debug `assert` caught a non-gated one, so a Release build would serve an earlier launch's
/// personal clip during the purge window. Now only a `LaunchPurgeGated` cache compiles into
/// `startPurgingPersonalFirst`; an ungated cache is gated by `LaunchPurgeGatedCache`, and
/// `CloudVoiceConsentCache` is gated through its base. None of these tests rely on `assert`, so
/// they hold in a Release (`-c release -enable-testing`) build too.
final class LaunchPurgeGateHardCheckTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-hard-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func clip(_ byte: UInt8, sources: [UUID]) -> CachedAudio {
        CachedAudio(data: Data([byte]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: sources)
    }

    /// An earlier launch left a personal, an all-lines-only and a generic clip on the ungated disk.
    private func seededDisk() -> UngatedDisk {
        let disk = UngatedDisk()
        disk["personal"] = clip(1, sources: [UUID()])
        disk["library"] = clip(2, sources: [VoiceRenderer.allLinesClipTag])
        disk["generic"] = clip(3, sources: [])
        return disk
    }

    private struct Launch {
        let barrier: HardCheckBarrier
        let started: AsyncStream<Void>
        let launched: AsyncStream<String?>
        let task: Task<Void, Never>
        let finish: () -> Void
        func waitForPurgeToStart() async { var it = started.makeAsyncIterator(); _ = await it.next() }
        func releasePurgeAndWait() async {
            barrier.open()
            var it = launched.makeAsyncIterator(); _ = await it.next()
        }
    }

    /// Wraps the ungated cache with `wrap`, starts the production launch purge on the wrapper and
    /// returns the wrapper (what the renderer reads) with the held launch.
    private func relaunch<C: LaunchPurgeGated>(on disk: UngatedDisk,
                                              _ wrap: (any AudioCache) -> C) -> (cache: C, launch: Launch) {
        let barrier = HardCheckBarrier()
        let (started, startedC) = AsyncStream<Void>.makeStream()
        let (launched, launchedC) = AsyncStream<String?>.makeStream()
        let cache = wrap(UngatedPersistentCache(disk: disk, barrier: barrier, started: startedC))
        let task = AudioCacheSweeper.startPurgingPersonalFirst(cache, every: .seconds(3600),
                                                               onLaunchSweep: { launchedC.yield($0) })
        return (cache, Launch(barrier: barrier, started: started, launched: launched, task: task,
                              finish: { startedC.finish(); launchedC.finish() }))
    }

    func testAnUngatedCacheBehindTheGateNeverServesAnEarlierPersonalClipBeforeThePurge() async {
        let disk = seededDisk()
        let (cache, launch) = relaunch(on: disk) { LaunchPurgeGatedCache(base: $0) }
        defer { launch.task.cancel(); launch.finish() }

        let immediate = await cache.audio(for: "personal")
        XCTAssertNil(immediate, "withheld from the moment start returns, before the purge task runs")
        await launch.waitForPurgeToStart()
        let during = await cache.audio(for: "personal")
        XCTAssertNil(during, "withheld while the purge is held")
        XCTAssertNotNil(disk["personal"], "the purge has really not run yet")
        let library = await cache.audio(for: "library")
        let generic = await cache.audio(for: "generic")
        XCTAssertEqual(library?.data, Data([2]), "all-lines-only clips are never withheld")
        XCTAssertEqual(generic?.data, Data([3]), "non-personal clips are served as usual")

        await launch.releasePurgeAndWait()
        XCTAssertFalse(cache.isWithholding, "the window closes once the purge returns")
        let after = await cache.audio(for: "personal")
        XCTAssertNil(after, "gone after the purge")
        XCTAssertEqual(disk.keys, ["generic", "library"])
    }

    func testAClipStoredThroughTheGateDuringTheWindowIsServed() async {
        let disk = seededDisk()
        let (cache, launch) = relaunch(on: disk) { LaunchPurgeGatedCache(base: $0) }
        defer { launch.task.cancel(); launch.finish() }
        await launch.waitForPurgeToStart()
        await cache.store(clip(9, sources: [UUID()]), for: "fresh")
        await cache.store(clip(8, sources: [UUID()]), for: "personal")      // same key, this launch
        let fresh = await cache.audio(for: "fresh")
        let overwritten = await cache.audio(for: "personal")
        XCTAssertEqual(fresh?.data, Data([9]))
        XCTAssertEqual(overwritten?.data, Data([8]), "this launch's clip, not the earlier one")
        await launch.releasePurgeAndWait()
    }

    /// A write that silently did not land leaves the earlier launch's clip at the key; it must
    /// not be served as this launch's (the gate checks what it stored, not only the key).
    func testAnEarlierClipLeftByADroppedWriteIsStillWithheld() async {
        let disk = seededDisk()
        let (cache, launch) = relaunch(on: disk) { LaunchPurgeGatedCache(base: $0) }
        defer { launch.task.cancel(); launch.finish() }
        await launch.waitForPurgeToStart()
        disk.dropWrites = true
        await cache.store(clip(8, sources: [UUID()]), for: "personal")
        let read = await cache.audio(for: "personal")
        XCTAssertNil(read, "the earlier personal clip is not served under this launch's write")
        await launch.releasePurgeAndWait()
    }

    /// `CloudVoiceConsentCache` is `LaunchPurgeGated`: started on the wrapper over an ungated base,
    /// it withholds the earlier personal clip until the purge completes.
    func testTheConsentWrapperOverAnUngatedBaseIsGated() async {
        let disk = seededDisk()
        let (cache, launch) = relaunch(on: disk) {
            CloudVoiceConsentCache(base: $0, localProviders: ["device"], isGranted: { true })
        }
        defer { launch.task.cancel(); launch.finish() }
        let immediate = await cache.audio(for: "personal")
        XCTAssertNil(immediate)
        await launch.waitForPurgeToStart()
        let during = await cache.audio(for: "personal")
        let generic = await cache.audio(for: "generic")
        XCTAssertNil(during, "withheld through the wrapper while the purge is held")
        XCTAssertEqual(generic?.data, Data([3]))
        await launch.releasePurgeAndWait()
        let after = await cache.audio(for: "personal")
        XCTAssertNil(after)
        XCTAssertEqual(disk.keys, ["generic", "library"])
    }

    /// Over a gated base (`FileAudioCache`, today's app), the wrappers forward the gate to it and
    /// add no gate of their own, so behavior is exactly the base's, failed-removal handling included.
    func testWrappersForwardTheGateToAGatedBase() async {
        let earlier = FileAudioCache(directory: dir)
        await earlier.store(clip(1, sources: [UUID()]), for: "personal")
        let file = FileAudioCache(directory: dir)
        let consent = CloudVoiceConsentCache(base: file, localProviders: ["device"], isGranted: { true })
        let outer = LaunchPurgeGatedCache(base: consent)
        outer.beginLaunchPurge()
        XCTAssertTrue(file.launchGate.isPending, "forwarded through both wrappers to the file cache")
        XCTAssertFalse(outer.isWithholding, "a gated base gates itself; the wrapper adds nothing")
        let direct = await file.audio(for: "personal")
        let wrapped = await outer.audio(for: "personal")
        XCTAssertNil(direct)
        XCTAssertNil(wrapped)
        await outer.purgePersonalItems()
        XCTAssertFalse(file.launchGate.isPending, "the file cache's purge, run through the wrappers, opens it")
    }

    /// With no launch purge started, the gate changes nothing (tests, the in-memory test station).
    func testTheGateIsTransparentWithoutALaunchPurge() async {
        let disk = seededDisk()
        let (_, startedC) = AsyncStream<Void>.makeStream()
        let cache = LaunchPurgeGatedCache(base: UngatedPersistentCache(disk: disk, barrier: HardCheckBarrier(),
                                                                       started: startedC))
        let personal = await cache.audio(for: "personal")
        XCTAssertEqual(personal?.data, Data([1]))
        let count = await AudioCacheFileLog.fileCount(of: cache)
        XCTAssertNil(count, "a wrapper never makes up a count for a base that cannot count")
        XCTAssertTrue(Mirror(reflecting: cache).children.isEmpty, "the base is never reflected out")
        startedC.finish()
    }

    /// Compile-time half (source check): the Bool entry point that took any cache is gone, the
    /// launch purge takes `some LaunchPurgeGated`, and nothing relies on a Debug-only assert.
    func testTheLaunchPurgeEntryPointOnlyTakesAGatedCache() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AeroDJCore/Voice/VoiceRendering.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("public static func startPurgingPersonalFirst(_ cache: some LaunchPurgeGated,"))
        XCTAssertFalse(source.contains("public func start(every interval: Duration = Self.defaultInterval, purgingPersonalFirst"),
                       "no public start that takes any cache with a purge flag")
        XCTAssertFalse(source.contains("assert(cache is any LaunchPurgeGated"), "no Debug-only gate check")
    }
}
