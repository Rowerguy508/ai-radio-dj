import XCTest
@testable import AeroDJCore

// Stacked privacy PR (fix/consent-purge-demotion-race): on-air stop, cache-hit gap, periodic
// 7-day sweep, live purge-all, bounded tombstones and the purge feed. No sleeps: barriers,
// manual ticks and state streams only. -Fry

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var arrived = false
    func wait() async {
        arrived = true
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func reached() async {
        if arrived { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
}

/// Cache whose read has already found the clip, then blocks before returning it.
private actor BlockingReadCache: AudioCache {
    let inner = InMemoryAudioCache()
    let gate: Gate
    init(gate: Gate) { self.gate = gate }
    func audio(for key: String) async -> CachedAudio? {
        let clip = await inner.audio(for: key)
        await gate.wait()
        return clip
    }
    func store(_ audio: CachedAudio, for key: String) async { await inner.store(audio, for: key) }
    func purge(sourceItemIDs: Set<UUID>) async { await inner.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await inner.purgeExpired() }
    func purgeAllPersonal() async { await inner.purgeAllPersonal() }
    func count() async -> Int { await inner.count }
}

private struct HardeningVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 2, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { stored = value } }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

@MainActor
private final class FakeInterlude {
    private(set) var stops: [InterludeStopReason] = []
    /// The `afterTrack` tag of each stop. Purge sends untagged stops (nil) until
    /// atlas/interlude-stop-hardening lands.
    private(set) var tags: [Int?] = []
    func stopCurrentInterlude(reason: InterludeStopReason, afterTrack: Int?) { stops.append(reason); tags.append(afterTrack) }
    /// Installs this fake as the session's stop hook (as AppDependencies does with the adapter).
    func attach(to session: DJBreakSession) {
        session.onBreakMustStop = { [self] reason, afterTrack in stopCurrentInterlude(reason: reason, afterTrack: afterTrack) }
    }
}

private func personalCue(_ id: UUID, text: String = "From your notes: water the plants.") -> NarrationCue {
    NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: text,
                 estimatedSeconds: 3, maxSeconds: 20, sourceItemID: id, source: .obsidian, provenance: "test:n1")
}

private let deviceRoute = VoiceRoute(providerID: "device", provider: HardeningVoice(), voice: djVoice)

private func key(for cue: NarrationCue) -> String {
    let text = deviceRoute.acceptsSSML ? SpeechDelivery.ssml(cue.text) : SpeechDelivery.speakable(cue.text)
    return VoiceRenderer.cacheKey(text: text, route: deviceRoute)
}

final class CacheHitRevocationTests: XCTestCase {
    /// Sentinel #63 residual 1: revoke lands while a cache hit is being read.
    func testRevokeDuringACacheHitFailsAndEmptiesTheCache() async {
        let item = UUID()
        let cue = personalCue(item)
        let gate = Gate()
        let cache = BlockingReadCache(gate: gate)
        await cache.store(CachedAudio(data: Data([1]), seconds: 2, providerID: "device", voiceID: "host",
                                      sourceItemIDs: [item]), for: key(for: cue))
        let revocations = NarrationRevocations()
        let renderer = VoiceRenderer(routes: [deviceRoute], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: cache, revocations: revocations)
        let render = Task { await renderer.render(cue, userID: "u", stationID: "s") }
        await gate.reached()                 // the clip was found; the hit has not returned yet
        revocations.revoke([item])
        await gate.open()
        guard case .failure = await render.value else { return XCTFail("a revoked clip must not be returned from cache") }
        let left = await cache.count()
        XCTAssertEqual(left, 0, "the hit for a revoked item is removed")
    }

    /// The clip shares its key (same text and voice) with another item that was revoked.
    func testCacheHitCarryingAnotherRevokedItemIsRejected() async {
        let revokedItem = UUID(), liveItem = UUID()
        let cue = personalCue(liveItem)
        let cache = InMemoryAudioCache()
        await cache.store(CachedAudio(data: Data([1]), seconds: 2, providerID: "device", voiceID: "host",
                                      sourceItemIDs: [revokedItem]), for: key(for: cue))
        let revocations = NarrationRevocations()
        revocations.revoke([revokedItem])    // purge still running
        let renderer = VoiceRenderer(routes: [deviceRoute], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: cache, revocations: revocations)
        let result = await renderer.render(cue, userID: "u", stationID: "s")
        guard case .failure = result else { return XCTFail("a clip derived from a revoked item must not be reused") }
        let left = await cache.count
        XCTAssertEqual(left, 0)
    }

    func testRenderIsRefusedWhileThatItemsPurgeIsStillRunning() async {
        let item = UUID()
        let cache = InMemoryAudioCache()
        let revocations = NarrationRevocations()
        revocations.revoke([item])
        let renderer = VoiceRenderer(routes: [deviceRoute], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: cache, revocations: revocations)
        guard case .failure = await renderer.render(personalCue(item), userID: "u", stationID: "s") else {
            return XCTFail("nothing may render for an item whose purge has not finished")
        }
        let stored = await cache.count
        XCTAssertEqual(stored, 0)
        revocations.purgeCompleted([item])
        guard case .success = await renderer.render(personalCue(item), userID: "u", stationID: "s") else {
            return XCTFail("after the purge finishes, a re-approved item renders again")
        }
    }
}

final class CacheRetentionSweepTests: XCTestCase {
    func testSweeperDeletesClipsPastSevenDaysOnEachTickWithoutAnyRead() async {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(t0)
        let cache = InMemoryAudioCache(maxAge: 30 * 24 * 3600, now: { clock.now })   // asks for 30 days
        XCTAssertEqual(cache.maxAge, AudioCacheRetention.maximum, "clamped to 7 days")
        await cache.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "device", voiceID: "v"), for: "old")
        clock.set(t0.addingTimeInterval(3 * 24 * 3600))
        await cache.store(CachedAudio(data: Data([2]), seconds: 1, providerID: "device", voiceID: "v"), for: "new")

        let (ticks, tick) = AsyncStream.makeStream(of: Void.self)
        let (sweeps, swept) = AsyncStream.makeStream(of: Void.self)
        var done = sweeps.makeAsyncIterator()
        let run = Task { await AudioCacheSweeper(cache: cache).run(ticks: ticks, onSweep: { swept.yield() }) }
        _ = await done.next()                                    // sweep at start
        var count = await cache.count
        XCTAssertEqual(count, 2)

        clock.set(t0.addingTimeInterval(7 * 24 * 3600 + 1))     // "old" is past 7 days, "new" is 4 days old
        tick.yield()
        _ = await done.next()
        count = await cache.count
        XCTAssertEqual(count, 1, "expired clip deleted by the sweep, never read")

        clock.set(t0.addingTimeInterval(10 * 24 * 3600 + 1))
        tick.yield()
        _ = await done.next()
        count = await cache.count
        XCTAssertEqual(count, 0)
        tick.finish()
        await run.value
    }

    /// Sentinel item 3 (clock skew): a clip stored while the clock was 30 days ahead is clamped
    /// to `now` by the first sweep that sees it, so it cannot outlive 7 days once the clock is
    /// corrected. File cache (relaunch-safe) and in-memory cache alike.
    func testClipStampedInTheFutureCannotOutliveSevenDays() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(t0.addingTimeInterval(30 * 24 * 3600))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skew-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let caches: [any AudioCache] = [FileAudioCache(directory: dir, now: { clock.now }),
                                        InMemoryAudioCache(now: { clock.now })]
        for cache in caches {
            clock.set(t0.addingTimeInterval(30 * 24 * 3600))          // clock running 30 days ahead
            await cache.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "device", voiceID: "v",
                                          sourceItemIDs: [UUID()]), for: "skewed")
            clock.set(t0)                                              // corrected
            let (ticks, tick) = AsyncStream.makeStream(of: Void.self)
            let (sweeps, swept) = AsyncStream.makeStream(of: Void.self)
            var done = sweeps.makeAsyncIterator()
            let run = Task { await AudioCacheSweeper(cache: cache).run(ticks: ticks, onSweep: { swept.yield() }) }
            _ = await done.next()
            let clamped = await cache.audio(for: "skewed")
            XCTAssertEqual(clamped?.createdAt, t0, "\(type(of: cache)): stamp clamped to no later than now")

            clock.set(t0.addingTimeInterval(7 * 24 * 3600 + 1))
            tick.yield()
            _ = await done.next()
            let left = await cache.audio(for: "skewed")
            XCTAssertNil(left, "\(type(of: cache)): gone 7 days after the corrected clock first saw it")
            tick.finish()
            await run.value
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(files, [], "no file left on disk")
    }

    /// Sentinel item 4 (relaunch with stale files), through the production entry point
    /// `start(purgingPersonalFirst:)` that `OnDeviceSpeechProvider` calls at launch: personal clips
    /// (metadata and audio), orphaned audio and expired generic clips left by an earlier run are
    /// deleted before the first tick, and the launch log line counts what is left.
    func testLaunchSweepRemovesStalePersonalAndOrphanFilesBeforeTheFirstTick() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(t0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let earlier = FileAudioCache(directory: dir, now: { clock.now })     // the previous launch
        await earlier.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "device", voiceID: "v",
                                        sourceItemIDs: [UUID()]), for: "k1")
        try Data([1]).write(to: dir.appendingPathComponent("k1.caf"))
        try Data([2]).write(to: dir.appendingPathComponent("orphan.caf"))
        await earlier.store(CachedAudio(data: Data([3]), seconds: 1, providerID: "device", voiceID: "v"), for: "stale")
        clock.set(t0.addingTimeInterval(8 * 24 * 3600))
        await earlier.store(CachedAudio(data: Data([4]), seconds: 1, providerID: "device", voiceID: "v"), for: "k2")

        let relaunched = FileAudioCache(directory: dir, now: { clock.now })
        let launched = expectation(description: "launch sweep")
        let line = LockedBox<String?>(nil)
        let task = AudioCacheSweeper(cache: relaunched).start(every: .seconds(3600), purgingPersonalFirst: true,
                                                              onLaunchSweep: { line.set($0); launched.fulfill() })
        await fulfillment(of: [launched], timeout: 10)
        task.cancel()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(files, ["k2.json"], "only the fresh generic clip survives the relaunch")
        XCTAssertEqual(line.value, "AeroDJ.cache narration cache count=1 personal=0 after=launch",
                       "the launch line counts what is left after the sweep")
    }

    func testLivePurgeAllRemovesEveryPersonalClipAndBlocksInFlightRenders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("purge-all-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FileAudioCache(directory: dir)
        let a = UUID(), b = UUID()
        await cache.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: [a]), for: "a")
        await cache.store(CachedAudio(data: Data([2]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: [b]), for: "b")
        await cache.store(CachedAudio(data: Data([3]), seconds: 1, providerID: "device", voiceID: "v"), for: "generic")
        let revocations = NarrationRevocations()
        let feed = NarrationPurgeFeed()
        var events = feed.updates().makeAsyncIterator()
        let tokenBefore = revocations.token()                    // a render that started earlier

        // Live mode: no persisted consent and no item list, so ids are unknown.
        await NarrationPurger(cache: cache, preparer: nil, revocations: revocations, feed: feed).purgeAllPersonalNarration()

        let aLeft = await cache.audio(for: "a"), bLeft = await cache.audio(for: "b"), generic = await cache.audio(for: "generic")
        XCTAssertNil(aLeft); XCTAssertNil(bLeft)
        XCTAssertNotNil(generic, "non-personal clips stay")
        XCTAssertTrue(revocations.revoked([UUID()], since: tokenBefore), "any personal render in flight is refused")
        XCTAssertFalse(revocations.revoked([UUID()], since: revocations.token()), "new renders after the purge are allowed")
        let event = await events.next()
        XCTAssertEqual(event, .all)
    }
}

final class NarrationRevocationsLimitTests: XCTestCase {
    func testTombstonesStayBoundedAndEvictionFailsClosed() {
        let revocations = NarrationRevocations(limit: 8)
        let oldToken = revocations.token()
        let ids = (0..<1000).map { _ in UUID() }
        for id in ids { revocations.revoke([id]); revocations.purgeCompleted([id]) }
        XCTAssertLessThanOrEqual(revocations.count, 8, "never more than the limit")
        XCTAssertTrue(revocations.revoked([ids[0]], since: oldToken),
                      "an evicted tombstone still blocks a render that started before it")
        XCTAssertTrue(revocations.revoked([ids[999]], since: oldToken))
        let fresh = revocations.token()
        XCTAssertFalse(revocations.revoked([ids[0]], since: fresh), "renders started later are not blocked")
        XCTAssertFalse(revocations.purgePending(ids), "completed purges leave nothing pending")
    }
}

@MainActor
final class OnAirRevocationTests: XCTestCase {
    private func briefing(_ itemID: UUID) -> NarrationHandoff {
        let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent,
                               text: "Coming up: Standup at ten. From your calendar.",
                               estimatedSeconds: 4, maxSeconds: 30, sourceItemID: itemID, source: .calendar, provenance: "fixture:1")
        return NarrationHandoff(cues: [cue], maxSpokenSeconds: 60, experienceSeconds: 600)
    }

    func testRevokingASourceStopsTheBreakOnAirInTheSameCallAndPublishesThePurge() async throws {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .init(commentary: .frequent)))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let cache = InMemoryAudioCache()
        let revocations = NarrationRevocations()
        let renderer = VoiceRenderer(routes: [deviceRoute], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: cache, revocations: revocations)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: station.active.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 9 })
        await session.start()
        let interlude = FakeInterlude()
        interlude.attach(to: session)
        let item = UUID(), other = UUID()

        var states = dj.updates().makeAsyncIterator()
        await session.queueStarted(djTracks(8), briefing: briefing(item), sources: approvedSources(briefing(item)))
        await session.songStarted(index: 0, remaining: .seconds(180))
        while let s = await states.next() { if case .ready = s { break } }
        let handed = await session.naturalBoundary(afterTrack: 0)
        let onAir = try XCTUnwrap(handed)
        XCTAssertTrue(onAir.cues.contains { $0.sourceItemID == item })
        session.playbackStarted(afterTrack: 0)

        let feed = NarrationPurgeFeed()
        var purges = feed.updates().makeAsyncIterator()
        let purger = NarrationPurger(cache: cache, preparer: preparer, session: session, revocations: revocations, feed: feed)

        await purger.purge(sourceItemIDs: [other])
        XCTAssertEqual(interlude.stops, [], "revoking an unrelated item leaves the break playing")
        await purger.purge(sourceItemIDs: [item])
        XCTAssertEqual(interlude.stops, [.sourceRevoked], "the break about the revoked item is stopped")
        XCTAssertEqual(interlude.tags, [nil], "untagged: fails closed for whatever is pending or playing")
        let personalKey = try XCTUnwrap(onAir.cues.first { $0.sourceItemID == item }?.audioCacheKey)
        let personalClip = await cache.audio(for: personalKey)
        XCTAssertNil(personalClip, "and its audio is gone (generic intro clips may stay)")

        await purger.purge(sourceItemIDs: [item])
        XCTAssertEqual(interlude.stops.count, 1, "stopped once, not again")
        let first = await purges.next(), second = await purges.next()
        XCTAssertEqual(first, .items([other]))
        XCTAssertEqual(second, .items([item]))
    }

    func testABreakThatAlreadyEndedIsNotStopped() async throws {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .init(commentary: .frequent)))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let revocations = NarrationRevocations()
        let renderer = VoiceRenderer(routes: [deviceRoute], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache(), revocations: revocations)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: station.active.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 9 })
        await session.start()
        let interlude = FakeInterlude()
        interlude.attach(to: session)
        let item = UUID()
        var states = dj.updates().makeAsyncIterator()
        await session.queueStarted(djTracks(8), briefing: briefing(item), sources: approvedSources(briefing(item)))
        await session.songStarted(index: 0, remaining: .seconds(180))
        while let s = await states.next() { if case .ready = s { break } }
        let handed = await session.naturalBoundary(afterTrack: 0)
        _ = try XCTUnwrap(handed)
        session.playbackStarted(afterTrack: 0)
        session.playbackFinished(afterTrack: 0)
        session.purge(sourceItemIDs: [item])
        XCTAssertEqual(interlude.stops, [], "nothing is on air to stop")
    }
}

final class AudioCacheFileLogTests: XCTestCase {
    /// #76 step 9: the device run proves files are deleted. Stable line, counts only.
    func testPurgeLogsRemainingFileCountsWithoutAnyPersonalContent() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cache-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FileAudioCache(directory: dir)
        let a = UUID(), b = UUID()
        await cache.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: [a]), for: "k1")
        await cache.store(CachedAudio(data: Data([2]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: [b]), for: "k2")
        await cache.store(CachedAudio(data: Data([3]), seconds: 1, providerID: "device", voiceID: "v"), for: "k3")
        let launch = await AudioCacheFileLog.record(cache, after: .launch)
        XCTAssertEqual(launch, "AeroDJ.cache narration cache count=3 personal=2 after=launch")

        await NarrationPurger(cache: cache, preparer: nil, revocations: NarrationRevocations(), feed: NarrationPurgeFeed())
            .purge(sourceItemIDs: [a])
        let afterPurge = await AudioCacheFileLog.record(cache, after: .purge)
        XCTAssertEqual(afterPurge, "AeroDJ.cache narration cache count=2 personal=1 after=purge")
        for line in [launch, afterPurge].compactMap({ $0 }) {
            XCTAssertFalse(line.contains(a.uuidString) || line.contains(b.uuidString) || line.contains("k1"), "no ids or keys")
        }
        let count = await cache.fileCount()
        XCTAssertEqual(count, AudioCacheCount(files: 2, personal: 1))
    }

    /// Sentinel: the count covers every file (audio and metadata), and a purge deletes a
    /// clip's audio together with its metadata, so orphaned audio cannot pass.
    func testCountIncludesAudioFilesAndPurgeDeletesAudioWithItsMetadataAndOrphans() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cache-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FileAudioCache(directory: dir)
        let a = UUID()
        await cache.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: [a]), for: "k1")
        await cache.store(CachedAudio(data: Data([2]), seconds: 1, providerID: "device", voiceID: "v"), for: "k2")
        try Data([9]).write(to: dir.appendingPathComponent("k1.caf"))       // audio beside k1's metadata
        try Data([9]).write(to: dir.appendingPathComponent("k2.m4a"))       // audio beside generic k2
        try Data([9]).write(to: dir.appendingPathComponent("orphan.caf"))   // audio with no metadata
        var count = await cache.fileCount()
        XCTAssertEqual(count, AudioCacheCount(files: 5, personal: 3), "every file counts; orphans count as personal")

        await NarrationPurger(cache: cache, preparer: nil, revocations: NarrationRevocations(), feed: NarrationPurgeFeed())
            .purge(sourceItemIDs: [a])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, ["k2.json", "k2.m4a"], "k1's audio went with its metadata; the orphan is gone")
        count = await cache.fileCount()
        XCTAssertEqual(AudioCacheFileLog.message(count, after: .purge), "AeroDJ.cache narration cache count=2 personal=0 after=purge")

        try Data([9]).write(to: dir.appendingPathComponent("orphan2.caf"))
        await cache.purgeAllPersonal()
        let afterAll = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(afterAll, ["k2.json", "k2.m4a"], "purge-all removes orphaned audio too")
    }
}

/// Sentinel (#75): a prepared break whose source expires mid-show must not air. The check runs
/// at `naturalBoundary` with the session's injected clock, without `ConnectionsModel.refresh()`.
@MainActor
final class BoundaryExpiryTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct Rig {
        let session: DJBreakSession
        let cache: FileAudioCache
        let dir: URL
        let dj: DJPresentationStore
        let revocations: NarrationRevocations
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func cue(_ item: UUID, _ order: Int, _ text: String) -> NarrationCue {
        NarrationCue(id: UUID(), order: order, group: 0, kind: .upcomingEvent, text: text,
                     estimatedSeconds: 4, maxSeconds: 30, sourceItemID: item, source: .calendar, provenance: "fixture:\(order)")
    }

    private func approved(_ id: UUID, expiresAt: Date?, sensitivity: Sensitivity? = .medium) -> ConnectionItem {
        ConnectionItem(id: id, integration: .calendar, title: "[TEST] item", state: .approved, expiresAt: expiresAt,
                       sensitivity: sensitivity)
    }

    /// Revokes `ids` from inside the boundary purge: the barrier is the purge itself, so a revoke
    /// lands exactly while `naturalBoundary` is suspended at its `await`. No sleeps.
    final class RevokeDuringPurge: NarrationPurging, @unchecked Sendable {
        weak var session: DJBreakSession?
        let revokes: Set<UUID>
        private(set) var calls: [Set<UUID>] = []
        init(revokes: Set<UUID>) { self.revokes = revokes }
        func purge(sourceItemIDs ids: Set<UUID>) async {
            calls.append(ids)
            let revokes = revokes
            await MainActor.run { [session] in session?.purge(sourceItemIDs: revokes) }
        }
    }

    /// Sentinel B4: a kept source revoked during the boundary's purge await (before the on-air
    /// marker exists) must not be handed out: the cues are re-checked against current consent.
    func testRevokeDuringTheBoundaryPurgeIsNotHandedOut() async throws {
        let clock = Clock(t0)
        let expiring = UUID(), kept = UUID(), other = UUID()
        let r = await rig(clock, cues: [cue(expiring, 1, "Coming up: Standup at ten."), cue(kept, 2, "And lunch with Sam."),
                                        cue(other, 3, "Then the dentist at four.")],
                          sources: [approved(expiring, expiresAt: t0.addingTimeInterval(60)),
                                    approved(kept, expiresAt: nil), approved(other, expiresAt: nil)])
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let spy = RevokeDuringPurge(revokes: [kept])
        spy.session = r.session
        r.session.purger = spy
        let stops = OnBreakMustStopHookTests.StopLog()
        r.session.onBreakMustStop = { reason, tag in stops.reasons.append(reason); stops.tags.append(tag) }
        clock.now = t0.addingTimeInterval(61)

        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertEqual(spy.calls, [[expiring]], "the boundary purged the expired item, and the revoke landed in that await")
        let ids = Set(try XCTUnwrap(handed, "the other approved item still airs").cues.compactMap(\.sourceItemID))
        XCTAssertFalse(ids.contains(kept), "the source revoked during the await is not handed out")
        XCTAssertFalse(ids.contains(expiring))
        XCTAssertTrue(ids.contains(other))
        XCTAssertEqual(stops.reasons, [], "nothing was on air yet, so nothing to stop")
    }

    /// Sentinel item 2: the boundary re-check treats a missing sensitivity as blocked (as #75's
    /// adapter does): an approved row without a value is never narrated.
    func testApprovedItemWithMissingSensitivityIsNotNarratedAtTheBoundary() async throws {
        let unknown = approved(UUID(), expiresAt: nil, sensitivity: nil)
        XCTAssertFalse(unknown.mayBeNarrated(at: t0), "missing sensitivity counts as blocked")
        XCTAssertFalse(approved(UUID(), expiresAt: nil, sensitivity: .blocked).mayBeNarrated(at: t0))
        XCTAssertTrue(approved(UUID(), expiresAt: nil, sensitivity: .medium).mayBeNarrated(at: t0))

        let clock = Clock(t0)
        let known = UUID()
        let r = await rig(clock, cues: [cue(unknown.id, 1, "Coming up: Standup at ten."), cue(known, 2, "And lunch with Sam.")],
                          sources: [unknown, approved(known, expiresAt: nil)])
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        let ids = Set(try XCTUnwrap(handed).cues.compactMap(\.sourceItemID))
        XCTAssertFalse(ids.contains(unknown.id), "no cue from the row without a sensitivity")
        XCTAssertTrue(ids.contains(known), "the row with a real value still airs")
    }

    /// Queues `cues` from `sources`, renders the first break (cached to disk) at `t0`, then waits
    /// until it is ready. The caller moves the clock and calls `naturalBoundary(afterTrack: 0)`.
    private func rig(_ clock: Clock, cues: [NarrationCue], sources: [ConnectionItem]) async -> Rig {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .init(commentary: .frequent)))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-expiry-\(UUID().uuidString)")
        let cache = FileAudioCache(directory: dir, now: { clock.now })
        let revocations = NarrationRevocations()
        let renderer = VoiceRenderer(routes: [deviceRoute], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: cache, revocations: revocations)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: station.active.cadence())
        let dj = DJPresentationStore()
        // #332 caps a break at one personal update by default. These boundary checks need several
        // sources in the same break, so the rig opts in to 3 (the purge rules are per cue either way).
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj,
                                     base: DJCadence(maxPersonalUpdatesPerBreak: 3), seed: 1, hour: { 9 }, now: { clock.now })
        session.purger = NarrationPurger(cache: cache, preparer: preparer, session: session, revocations: revocations,
                                         feed: NarrationPurgeFeed())
        await session.start()
        var states = dj.updates().makeAsyncIterator()
        await session.queueStarted(djTracks(8),
                                   briefing: NarrationHandoff(cues: cues, maxSpokenSeconds: 60, experienceSeconds: 600),
                                   sources: sources)
        await session.songStarted(index: 0, remaining: .seconds(180))
        while let s = await states.next() { if case .ready = s { break } }
        return Rig(session: session, cache: cache, dir: dir, dj: dj, revocations: revocations)
    }

    /// (1) Approved item expiring at t0+60 s; the clock passes it, no refresh(): its cues are not
    /// in the break and its cached audio is purged. The other approved item still airs.
    func testItemExpiringMidShowIsDroppedAtTheBoundaryAndPurgedWithoutRefresh() async throws {
        let clock = Clock(t0)
        let expiring = UUID(), staying = UUID()
        let r = await rig(clock, cues: [cue(expiring, 1, "Coming up: Standup at ten."), cue(staying, 2, "And lunch with Sam.")],
                          sources: [approved(expiring, expiresAt: t0.addingTimeInterval(60)), approved(staying, expiresAt: nil)])
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let token = r.revocations.token()
        let before = await r.cache.fileCount()
        XCTAssertEqual(before.personal, 2, "both items rendered and cached before expiry")

        clock.now = t0.addingTimeInterval(61)
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        let aired = try XCTUnwrap(handed, "the still-approved item keeps its break")
        XCTAssertFalse(aired.cues.contains { $0.sourceItemID == expiring }, "expired item's cues are not handed out")
        XCTAssertTrue(aired.cues.contains { $0.sourceItemID == staying })
        XCTAssertEqual(Set(aired.clips.map(\.cueID)), Set(aired.cues.map(\.id)), "no clip without its cue")
        let after = await r.cache.fileCount()
        XCTAssertEqual(after.personal, 1, "the expired item's cached audio is purged; the other's stays")
        XCTAssertTrue(r.revocations.revoked([expiring], since: token), "purged through NarrationPurger (renders refused)")
        XCTAssertFalse(r.revocations.revoked([staying], since: token))
    }

    /// (2) `expiresAt == now` is expired, as in `ConnectionItemState.resolve` (`expiresAt <= now`).
    func testExpiryExactlyAtTheBoundaryCountsAsExpired() async throws {
        let expiry = t0.addingTimeInterval(60)
        for (at, airs) in [(expiry.addingTimeInterval(-1), true), (expiry, false)] {
            let clock = Clock(t0)
            let item = UUID()
            let r = await rig(clock, cues: [cue(item, 1, "Coming up: Standup at ten.")],
                              sources: [approved(item, expiresAt: expiry)])
            defer { try? FileManager.default.removeItem(at: r.dir) }
            clock.now = at
            let handed = await r.session.naturalBoundary(afterTrack: 0)
            XCTAssertEqual(handed?.cues.contains { $0.sourceItemID == item } ?? false, airs,
                           "at expiresAt\(airs ? " - 1 s" : "") the item \(airs ? "airs" : "does not air")")
            XCTAssertEqual(ConnectionItemState.resolve(consent: .granted, expiresAt: expiry, now: at, flagged: false,
                                                       reconfirmed: false).mayBeNarrated, airs, "same rule as resolve()")
        }
    }

    /// (3) Audio rendered and cached before expiry: at the boundary the break is dropped (music
    /// plays) and the item's audio and metadata files are deleted from disk.
    func testCachedAudioOfAnExpiredItemIsDroppedAndItsFilesDeleted() async throws {
        let clock = Clock(t0)
        let item = UUID()
        let r = await rig(clock, cues: [cue(item, 1, "Coming up: Standup at ten.")],
                          sources: [approved(item, expiresAt: t0.addingTimeInterval(60))])
        defer { try? FileManager.default.removeItem(at: r.dir) }
        // Audio beside each clip's metadata (as a .caf), so deletion of both is visible on disk.
        for json in try FileManager.default.contentsOfDirectory(atPath: r.dir.path) where json.hasSuffix(".json") {
            try Data([9]).write(to: r.dir.appendingPathComponent(json.replacingOccurrences(of: ".json", with: ".caf")))
        }
        let before = await r.cache.fileCount()
        XCTAssertEqual(before.personal, 2, "the item's metadata and audio are on disk before expiry")
        clock.now = t0.addingTimeInterval(120)
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(handed, "nothing personal is left to say: the player plays music at once")
        let after = await r.cache.fileCount()
        XCTAssertEqual(after.personal, 0, "the item's audio and metadata files are deleted")
        XCTAssertEqual(after.files, after.generic, "only generic clips (and their audio) remain")
        XCTAssertEqual(r.dj.state, .idle, "the DJ shows music, not a ready break")
    }
}

/// Only consent changes in Connections purge narration. Turning the briefing preference off is a
/// station edit: future breaks are re-planned and nothing is purged. A briefing break already on
/// air stops now (Atlas, privacy P1: the listener turned it off, so it must stop talking), through
/// the same stop hook a purge uses, but the cache and revocations are untouched. (#75's `ApprovedShowHandoff.revokedOrUnapproved` becomes true here; it is not in this
/// base yet, so this pins the StationConfiguration -> DJBreakSession -> NarrationPurger seam.)
@MainActor
final class BriefingOffIsNotAPurgeTests: XCTestCase {
    final class SpyPurger: NarrationPurging, @unchecked Sendable {
        var calls: [Set<UUID>] = []
        func purge(sourceItemIDs: Set<UUID>) async { calls.append(sourceItemIDs) }
    }

    func testTurningTheBriefingOffStopsTheBriefingBreakOnAirWithoutPurgingTheCache() async throws {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .init(commentary: .frequent)))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        XCTAssertTrue(station.active.briefing.enabled, "precondition: briefing on")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("briefing-off-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FileAudioCache(directory: dir)
        let revocations = NarrationRevocations()
        let renderer = VoiceRenderer(routes: [deviceRoute], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: cache, revocations: revocations)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: station.active.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 9 })
        let spy = SpyPurger()
        session.purger = spy
        let interlude = FakeInterlude()
        interlude.attach(to: session)
        await session.start()
        let item = UUID()
        let briefing = NarrationHandoff(cues: [NarrationCue(
            id: UUID(), order: 1, group: 0, kind: .upcomingEvent, text: "Coming up: Standup at ten.",
            estimatedSeconds: 4, maxSeconds: 30, sourceItemID: item, source: .calendar, provenance: "fixture:1")],
            maxSpokenSeconds: 60, experienceSeconds: 600)
        var states = dj.updates().makeAsyncIterator()
        await session.queueStarted(djTracks(8), briefing: briefing, sources: approvedSources(briefing))
        await session.songStarted(index: 0, remaining: .seconds(180))
        while let s = await states.next() { if case .ready = s { break } }
        let handed = await session.naturalBoundary(afterTrack: 0)
        XCTAssertTrue(try XCTUnwrap(handed).cues.contains { $0.sourceItemID == item })
        session.playbackStarted(afterTrack: 0)
        let cachedBefore = await cache.fileCount()
        XCTAssertGreaterThan(cachedBefore.personal, 0)

        var changes = station.changes().makeAsyncIterator()
        await station.setBriefing { $0.enabled = false }
        await station.saveChanges()
        let next = await changes.next()
        let change = try XCTUnwrap(next)
        XCTAssertTrue(change.invalidatesPreparedBreaks, "briefing off drops future breaks")
        await session.stationChanged(change)   // the same path the session's change stream runs

        // Changed deliberately (was: "the break on air keeps playing"). Briefing off is an
        // `.immediate` privacy reduction: the briefing break on air stops, once, untagged.
        XCTAssertEqual(interlude.stops, [.sourceRevoked], "the briefing break on air stops now")
        XCTAssertEqual(interlude.tags, [nil])
        XCTAssertEqual(spy.calls, [], "NarrationPurger is not called")
        XCTAssertEqual(revocations.count, 0, "nothing is revoked")
        let cachedAfter = await cache.fileCount()
        XCTAssertEqual(cachedAfter, cachedBefore, "cached audio stays on disk")
    }
}

/// `DJBreakSession.onBreakMustStop` (#67's hook; PlayerView routes it to
/// `InterludePlaybackAdapter.stopCurrentInterlude(reason:)` at 82664c8). The purge calls it
/// exactly once, and only when the purge removes a source the break on air depends on.
@MainActor
final class OnBreakMustStopHookTests: XCTestCase {
    final class StopLog { var reasons: [InterludeStopReason] = []; var tags: [Int?] = [] }

    private struct OnAir { let session: DJBreakSession; let station: StationConfigurationModel
                           let stops: StopLog; let items: [UUID]; let purger: NarrationPurger
                           var item: UUID { items[0] } }

    /// A personal break about `item` is on air, with a fake stop hook installed.
    private func onAir(sources n: Int = 1, hook: Bool = true) async throws -> OnAir {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .init(commentary: .frequent)))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let cache = InMemoryAudioCache()
        let revocations = NarrationRevocations()
        let renderer = VoiceRenderer(routes: [deviceRoute], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: cache, revocations: revocations)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: station.active.cadence())
        let dj = DJPresentationStore()
        // #332 caps a break at one personal update by default; `sources: n` needs n in one break.
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj,
                                     base: DJCadence(maxPersonalUpdatesPerBreak: max(1, n)), seed: 1, hour: { 9 })
        let stops = StopLog()
        if hook { session.onBreakMustStop = { reason, tag in stops.reasons.append(reason); stops.tags.append(tag) } }
        await session.start()
        let items = (0..<n).map { _ in UUID() }
        let briefing = NarrationHandoff(cues: items.enumerated().map { i, item in NarrationCue(
            id: UUID(), order: i + 1, group: 0, kind: .upcomingEvent, text: "Coming up: event \(i + 1) at ten.",
            estimatedSeconds: 4, maxSeconds: 30, sourceItemID: item, source: .calendar, provenance: "fixture:\(i + 1)") },
            maxSpokenSeconds: 60, experienceSeconds: 600)
        var states = dj.updates().makeAsyncIterator()
        await session.queueStarted(djTracks(8), briefing: briefing, sources: approvedSources(briefing))
        await session.songStarted(index: 0, remaining: .seconds(180))
        while let s = await states.next() { if case .ready = s { break } }
        let handed = await session.naturalBoundary(afterTrack: 0)
        XCTAssertEqual(Set(try XCTUnwrap(handed).cues.compactMap(\.sourceItemID)), Set(items))
        session.playbackStarted(afterTrack: 0)
        let purger = NarrationPurger(cache: cache, preparer: preparer, session: session, revocations: revocations,
                                     feed: NarrationPurgeFeed())
        return OnAir(session: session, station: station, stops: stops, items: items, purger: purger)
    }

    func testRevokingTheOnAirSourceFiresTheStopHookOnceWithSourceRevoked() async throws {
        let r = try await onAir()
        await r.purger.purge(sourceItemIDs: [r.item])
        XCTAssertEqual(r.stops.reasons, [.sourceRevoked], "fires in the purge, with .sourceRevoked")
        XCTAssertEqual(r.stops.tags, [nil], "untagged until atlas/interlude-stop-hardening")
        await r.purger.purge(sourceItemIDs: [r.item])
        r.session.purge(sourceItemIDs: [r.item])
        XCTAssertEqual(r.stops.reasons, [.sourceRevoked], "exactly once: the break is no longer on air")
    }

    func testAPurgeThatDoesNotTouchTheOnAirBreakDoesNotFire() async throws {
        let r = try await onAir()
        await r.purger.purge(sourceItemIDs: [UUID()])
        r.session.purge(sourceItemIDs: [UUID(), UUID()])
        r.session.purge(sourceItemIDs: [])
        XCTAssertEqual(r.stops.reasons, [], "unrelated purges leave the break playing")
    }

    /// Sentinel question 2: any one of the on-air break's sources stops it, once.
    func testRevokingOneOfTwoOnAirSourcesStopsOnce() async throws {
        let r = try await onAir(sources: 2)
        await r.purger.purge(sourceItemIDs: [r.items[0]])
        await r.purger.purge(sourceItemIDs: [r.items[1]])
        XCTAssertEqual(r.stops.reasons, [.sourceRevoked])
    }

    /// Sentinel question 4: a purge from inside the hook neither fires again nor deadlocks.
    func testPurgeFromInsideTheHookFiresOnceAndCompletes() async throws {
        let r = try await onAir()
        let session = r.session, item = r.item, stops = r.stops
        session.onBreakMustStop = { reason, tag in
            stops.reasons.append(reason)
            stops.tags.append(tag)
            session.purge(sourceItemIDs: [item])
            session.purge(sourceItemIDs: [UUID()])
        }
        await r.purger.purge(sourceItemIDs: [item])
        XCTAssertEqual(r.stops.reasons, [.sourceRevoked])
    }

    /// Sentinel item 6: with no hook installed, the stop is held and delivered once when one is set.
    func testStopIsNotLostWhenTheHookIsInstalledLate() async throws {
        let r = try await onAir(hook: false)
        await r.purger.purge(sourceItemIDs: [r.item])
        XCTAssertEqual(r.stops.reasons, [], "no hook yet")
        let stops = r.stops
        r.session.onBreakMustStop = { reason, tag in stops.reasons.append(reason); stops.tags.append(tag) }
        XCTAssertEqual(r.stops.reasons, [.sourceRevoked], "delivered as soon as the hook is attached")
        r.session.onBreakMustStop = { reason, tag in stops.reasons.append(reason); stops.tags.append(tag) }
        await r.purger.purge(sourceItemIDs: [r.item])
        XCTAssertEqual(r.stops.reasons, [.sourceRevoked], "delivered once, not again")
    }

    /// A held stop is dropped when that break has already ended: a later hook gets nothing.
    func testHeldStopIsDroppedOnceThatBreakHasEnded() async throws {
        let r = try await onAir(hook: false)
        await r.purger.purge(sourceItemIDs: [r.item])
        r.session.playbackFinished(afterTrack: 0)
        let stops = r.stops
        r.session.onBreakMustStop = { reason, tag in stops.reasons.append(reason); stops.tags.append(tag) }
        XCTAssertEqual(r.stops.reasons, [], "nothing is playing any more, so nothing to stop")
    }

    /// Changed deliberately (was `testTurningTheBriefingOffDoesNotFire`): briefing off is still
    /// not a purge, but the briefing break on air must stop talking (Atlas, privacy P1).
    func testTurningTheBriefingOffStopsTheBriefingBreakOnAir() async throws {
        let r = try await onAir()
        var changes = r.station.changes().makeAsyncIterator()
        await r.station.setBriefing { $0.enabled = false }
        await r.station.saveChanges()
        let next = await changes.next()
        let change = try XCTUnwrap(next)
        await r.session.stationChanged(change)
        XCTAssertEqual(r.stops.reasons, [.sourceRevoked], "the briefing break on air stops once")
        XCTAssertEqual(r.stops.tags, [nil], "untagged, as in purge")
    }
}

// F4 (Sentinel, v2). -Fry
extension BoundaryExpiryTests {
    /// Advances the clock inside the boundary purge: an expiry lands while `naturalBoundary`
    /// is suspended at its `await`. No sleeps.
    final class ExpireDuringPurge: NarrationPurging, @unchecked Sendable {
        let clock: Clock
        let to: Date
        private(set) var calls: [Set<UUID>] = []
        init(clock: Clock, to: Date) { self.clock = clock; self.to = to }
        func purge(sourceItemIDs ids: Set<UUID>) async {
            calls.append(ids)
            clock.now = to
        }
    }

    func testAnExpiryThatLandsDuringTheBoundaryAwaitIsCaught() async throws {
        let clock = Clock(t0)
        let first = UUID(), second = UUID(), stays = UUID()
        let r = await rig(clock, cues: [cue(first, 1, "Coming up: Standup at ten."), cue(second, 2, "And lunch with Sam."),
                                        cue(stays, 3, "Then the dentist at four.")],
                          sources: [approved(first, expiresAt: t0.addingTimeInterval(60)),
                                    approved(second, expiresAt: t0.addingTimeInterval(120)),
                                    approved(stays, expiresAt: nil)])
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let spy = ExpireDuringPurge(clock: clock, to: t0.addingTimeInterval(121))
        r.session.purger = spy
        clock.now = t0.addingTimeInterval(61)               // `first` has expired; `second` not yet

        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertEqual(spy.calls, [[first]], "the boundary purged only what had expired before the await")
        let ids = Set(try XCTUnwrap(handed, "the unexpiring item still airs").cues.compactMap(\.sourceItemID))
        XCTAssertFalse(ids.contains(second), "expired during the await: not handed out")
        XCTAssertFalse(ids.contains(first))
        XCTAssertTrue(ids.contains(stays))
    }
}

extension OnBreakMustStopHookTests {
    /// A stop held (no hook yet) for the old queue's break is dropped by `queueStarted`: it must
    /// not stop a break of the new queue once a hook is installed.
    func testQueueStartedResetsAHeldStop() async throws {
        let r = try await onAir(hook: false)
        await r.purger.purge(sourceItemIDs: [r.item])        // held: no hook
        await r.session.queueStarted(djTracks(8))
        let stops = r.stops
        r.session.onBreakMustStop = { reason, tag in stops.reasons.append(reason); stops.tags.append(tag) }
        XCTAssertEqual(r.stops.reasons, [], "the old queue's held stop is gone")
    }
}
