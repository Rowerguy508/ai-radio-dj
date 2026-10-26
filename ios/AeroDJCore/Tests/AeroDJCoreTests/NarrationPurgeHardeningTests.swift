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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

@MainActor
private final class FakeInterlude: InterludeStopping {
    private(set) var stops: [InterludeStopReason] = []
    func stopCurrentInterlude(reason: InterludeStopReason) { stops.append(reason) }
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
        session.interlude = interlude
        let item = UUID(), other = UUID()

        var states = dj.updates().makeAsyncIterator()
        await session.queueStarted(djTracks(8), briefing: briefing(item))
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
        session.interlude = interlude
        let item = UUID()
        var states = dj.updates().makeAsyncIterator()
        await session.queueStarted(djTracks(8), briefing: briefing(item))
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
        XCTAssertEqual(launch, "AeroDJ.cache files=3 personal=2 generic=1 after=launch")

        await NarrationPurger(cache: cache, preparer: nil, revocations: NarrationRevocations(), feed: NarrationPurgeFeed())
            .purge(sourceItemIDs: [a])
        let afterPurge = await AudioCacheFileLog.record(cache, after: .purge)
        XCTAssertEqual(afterPurge, "AeroDJ.cache files=2 personal=1 generic=1 after=purge")
        for line in [launch, afterPurge].compactMap({ $0 }) {
            XCTAssertFalse(line.contains(a.uuidString) || line.contains(b.uuidString) || line.contains("k1"), "no ids or keys")
        }
        let count = await cache.fileCount()
        XCTAssertEqual(count, AudioCacheCount(files: 2, personal: 1))
    }
}
