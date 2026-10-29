import XCTest
@testable import AeroDJCore

/// P0 (build 22): an invalidating station change during song 1 cancelled the plain first break
/// and re-planned from song 2. A plain music break now survives a withdrawal or briefing-off;
/// anything personal, briefing-bearing, or with unknown attribution is still dropped, and a
/// withdrawn integration's clips are purged from the cache (Sentinel).
@MainActor
final class StationChangeNarrowingTests: XCTestCase {
    private struct Rig {
        let session: DJBreakSession
        let station: StationConfigurationModel
        let cache: InMemoryAudioCache
        let dj: DJPresentationStore
    }

    private func rig(briefing: NarrationHandoff? = nil, sources: [ConnectionItem] = []) async -> Rig {
        let config = StationConfiguration(commentary: .frequent, requestedIntegrations: [.calendar])
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let cache = InMemoryAudioCache()
        let revocations = NarrationRevocations()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache, revocations: revocations)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        session.purger = NarrationPurger(cache: cache, preparer: preparer, session: session,
                                         revocations: revocations, feed: NarrationPurgeFeed())
        await session.start()
        var states = dj.updates().makeAsyncIterator()
        await session.queueStarted(djTracks(8), briefing: briefing, sources: sources)
        await session.songStarted(index: 0, remaining: .seconds(180))
        while let s = await states.next() { if case .ready = s { break } }
        return Rig(session: session, station: station, cache: cache, dj: dj)
    }

    private func withdrawCalendar(_ r: Rig) async {
        await r.station.setIntegration(.calendar, requested: false)
        for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(10)) }   // change stream hop
    }

    func testPlainFirstBreakSurvivesAWithdrawalDuringSongOne() async throws {
        let r = await rig()
        XCTAssertEqual(r.session.plannedBoundaries.first, 0, "precondition: Frequent plans afterTrack 0")
        await withdrawCalendar(r)
        XCTAssertEqual(r.session.plannedBoundaries.first, 0, "the plain break is kept")
        XCTAssertFalse(r.session.plannedBoundaries.contains(1), "spacing continues from the kept break")
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNotNil(handed, "the first break still plays")
        XCTAssertNil(r.session.lastNoBreak)
        await r.session.stop()
    }

    func testCalendarBreakWithdrawnDuringSongOneIsNeitherPlayableNorCached() async throws {
        let itemID = UUID()
        let cue = NarrationCue(id: UUID(), order: 0, group: 0, kind: .upcomingEvent, text: "Standup at 10",
                               estimatedSeconds: 2, maxSeconds: 4, sourceItemID: itemID, source: .calendar,
                               provenance: "cal")
        let item = ConnectionItem(id: itemID, integration: .calendar, title: "Standup",
                                  state: .approved, sensitivity: .medium)
        let r = await rig(briefing: NarrationHandoff(cues: [cue], maxSpokenSeconds: 60, experienceSeconds: 600),
                          sources: [item])
        XCTAssertTrue(r.session.testPlannedSourceItemIDs.contains(itemID), "precondition: break 0 carries it")
        let personalBefore = await r.cache.fileCount().personal
        XCTAssertGreaterThan(personalBefore, 0, "precondition: its clip was cached")

        await withdrawCalendar(r)
        XCTAssertFalse(r.session.testPlannedSourceItemIDs.contains(itemID))
        let personalAfter = await r.cache.fileCount().personal
        XCTAssertEqual(personalAfter, 0, "no calendar-bearing clip stays cached")
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertFalse(handed?.cues.contains { $0.sourceItemID == itemID } ?? false, "nothing calendar plays")
        XCTAssertFalse(handed?.clips.contains { $0.audio.sourceItemIDs.contains(itemID) } ?? false)
        await r.session.stop()
    }

    // MARK: survivingBreak fails closed

    private func change(commentary: CommentaryFrequency = .frequent) -> StationConfigurationChange {
        StationConfigurationChange(previous: .init(commentary: .frequent, requestedIntegrations: [.calendar]),
                                   active: .init(commentary: commentary), applied: [], boundary: nil)
    }

    private func plainBreak() throws -> DJBreak {
        var w = DJScriptWriter(cadence: .init(talkFraction: 1), seed: 1)
        return try XCTUnwrap(w.plan(tracks: djTracks(3), briefing: nil, hour: 9).breaks.first)
    }

    func testOnlyAPlainBreakWithKnownAttributionSurvives() throws {
        let plain = try plainBreak()
        XCTAssertEqual(DJBreakSession.survivingBreak(plain, after: change()), plain.afterTrack)
        XCTAssertNil(DJBreakSession.survivingBreak(nil, after: change()))
        XCTAssertNil(DJBreakSession.survivingBreak(plain, after: change(commentary: .off)), "commentary off drops all")

        let unattributed = DJBreak(afterTrack: plain.afterTrack, cues: plain.cues, attributions: [:])
        XCTAssertNil(DJBreakSession.survivingBreak(unattributed, after: change()), "missing attribution is tainted")

        var personal = plain.attributions
        personal[plain.cues[0].id] = .personalContext(itemID: UUID(), source: .calendar, provenance: "cal")
        let tainted = DJBreak(afterTrack: plain.afterTrack, cues: plain.cues, attributions: personal)
        XCTAssertNil(DJBreakSession.survivingBreak(tainted, after: change()), "personal attribution is tainted")
    }
}
