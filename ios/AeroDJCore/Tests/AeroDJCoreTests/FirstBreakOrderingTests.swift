import XCTest
@testable import AeroDJCore

/// #116 (-Atlas): a song start MusicKit reports *during* `play` must belong to the new queue.
/// Before the fix, `queueSetupPending` was set only after `play` returned, so an early
/// `songStarted` read the old queue's breaks and was never replayed for the new one.
@MainActor
final class FirstBreakOrderingTests: XCTestCase {

    private struct PacedVoice: VoiceProvider {
        func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
            let words = max(1, SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count)
            return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.01,
                                 billableUnits: 0, provider: "device", cacheKey: nil)
        }
    }

    private struct PlayFailed: Error {}

    private func tracks(_ prefix: String, _ n: Int) -> [DJTrack] {
        (0..<n).map { DJTrack(id: "\(prefix)\($0)", title: "T\($0)", artist: "A\($0)") }
    }

    private func session(requestedIntegrations: Set<StationIntegration> = []) async
    -> (DJBreakSession, StationConfigurationModel) {
        let config = StationConfiguration(commentary: .frequent, requestedIntegrations: requestedIntegrations)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: PacedVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(),
                                     seed: 1, hour: { 14 })
        await session.start()
        return (session, station)
    }

    /// The live tap order, as `MusicSearch.live` runs it.
    private func tap(_ session: DJBreakSession, _ queue: [DJTrack],
                     briefing: NarrationHandoff? = nil, sources: [ConnectionItem] = [],
                     play: @MainActor () async throws -> Void) async throws -> Task<Void, Never> {
        try await TapPlaySequence.run(
            reserve: { session.reserveQueueSetup() },
            play: play,
            scheduleBreakPrep: { session.beginQueueInBackground($0, queue, briefing: briefing, sources: sources) },
            release: { session.releaseQueueSetup($0) })
    }

    func testSongStartDuringPlayIsHeldForTheNewQueueNotTheOldOne() async throws {
        let (session, _) = await session()
        await session.queueStarted(tracks("old", 4))   // an old queue is active with its breaks
        XCTAssertFalse(session.plannedBoundaries.isEmpty)
        let newQueue = tracks("new", 6)
        let setup = try await tap(session, newQueue) {
            // MusicKit reports the first song before play() returns.
            await session.songStarted(index: 0, remaining: .seconds(180))
            XCTAssertTrue(session.testQueueSetupPending, "the new queue is pending before play")
            XCTAssertEqual(session.testHeldSongStartIndex, 0, "held, not run against the old queue")
        }
        await setup.value
        XCTAssertEqual(session.testQueueTrackIDs, newQueue.map(\.id))
        XCTAssertFalse(session.testQueueSetupPending)
        XCTAssertNil(session.testHeldSongStartIndex, "the held start was replayed for the new queue")
        await session.stop()
    }

    func testReservationIsTakenSynchronouslyBeforePlayIsCalled() async throws {
        let (session, _) = await session()
        var order: [String] = []
        _ = try await TapPlaySequence.run(
            reserve: { order.append("reserve"); return session.reserveQueueSetup() },
            play: { order.append(session.testQueueSetupPending ? "play(pending)" : "play(not pending)") },
            scheduleBreakPrep: { order.append("schedule"); return session.beginQueueInBackground($0, self.tracks("q", 3)) },
            release: { _ in order.append("release") })
        XCTAssertEqual(order, ["reserve", "play(pending)", "schedule"])
        await session.stop()
    }

    func testRapidSecondTapDuringFirstPlayWinsAndFirstSchedulesNothing() async throws {
        let (session, _) = await session()
        let first = tracks("first", 4), second = tracks("second", 6)
        var secondSetup: Task<Void, Never>?
        let firstSetup = try await tap(session, first) {
            // A second tap completes its whole play while the first play is still in flight.
            secondSetup = try await self.tap(session, second) {
                await session.songStarted(index: 0, remaining: .seconds(200))
            }
        }
        await firstSetup.value
        await secondSetup?.value
        XCTAssertEqual(session.testQueueTrackIDs, second.map(\.id), "the newer tap's queue wins")
        XCTAssertFalse(session.testQueueSetupPending)
        XCTAssertNil(session.testHeldSongStartIndex)
        await session.stop()
    }

    func testPlayFailureReleasesTheHoldSoTheOldQueueKeepsWorking() async throws {
        let (session, _) = await session()
        let old = tracks("old", 4)
        await session.queueStarted(old)
        do {
            _ = try await tap(session, tracks("new", 6)) { throw PlayFailed() }
            XCTFail("play error must propagate")
        } catch is PlayFailed {}
        XCTAssertFalse(session.testQueueSetupPending, "no queue stays pending after a failed play")
        XCTAssertNil(session.testHeldSongStartIndex)
        XCTAssertEqual(session.testQueueTrackIDs, old.map(\.id))
        await session.songStarted(index: 1, remaining: .seconds(180))
        XCTAssertNil(session.testHeldSongStartIndex, "old queue song starts are handled, not held")
        await session.stop()
    }

    func testStaleReleaseDoesNotDropANewerTapsHold() async throws {
        let (session, _) = await session()
        let stale = session.reserveQueueSetup()
        let current = session.reserveQueueSetup()
        session.releaseQueueSetup(stale)
        XCTAssertTrue(session.testQueueSetupPending, "only the newest reservation can release")
        await session.songStarted(index: 0, remaining: .seconds(180))
        XCTAssertEqual(session.testHeldSongStartIndex, 0)
        let q = tracks("q", 5)
        await session.beginQueueInBackground(current, q).value
        XCTAssertEqual(session.testQueueTrackIDs, q.map(\.id))
        XCTAssertNil(session.testHeldSongStartIndex)
        await session.stop()
    }

    func testCancellationDuringPlaySchedulesNoSetup() async throws {
        let (session, _) = await session()
        let old = tracks("old", 4)
        await session.queueStarted(old)
        let setup = try await tap(session, tracks("new", 6)) {
            await session.songStarted(index: 0, remaining: .seconds(180))
            session.cancelBackgroundQueueSetup()   // skip / stop while play is in flight
        }
        await setup.value
        XCTAssertEqual(session.testQueueTrackIDs, old.map(\.id), "a cancelled tap plans nothing")
        XCTAssertFalse(session.testQueueSetupPending)
        XCTAssertNil(session.testHeldSongStartIndex)
        await session.stop()
    }

    func testConsentWithdrawnDuringPlayIsAppliedToTheNewQueue() async throws {
        let itemID = UUID()
        let cue = NarrationCue(
            id: UUID(), order: 0, group: 0, kind: .upcomingEvent, text: "Standup at 10",
            estimatedSeconds: 2, maxSeconds: 4, sourceItemID: itemID, source: .calendar, provenance: "cal")
        let handoff = NarrationHandoff(cues: [cue], maxSpokenSeconds: 150, experienceSeconds: 300)
        let item = ConnectionItem(id: itemID, integration: .calendar, title: "Standup",
                                  state: .approved, sensitivity: .medium)
        let (session, station) = await session(requestedIntegrations: [.calendar])
        let setup = try await tap(session, tracks("new", 8), briefing: handoff, sources: [item]) {
            await station.setIntegration(.calendar, requested: false)
            for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(10)) }   // change stream hop
            await session.songStarted(index: 0, remaining: .seconds(180))
        }
        await setup.value
        XCTAssertTrue(session.testBriefingIsNil, "a withdrawal during play must not be undone by setup")
        XCTAssertFalse(session.testPlannedSourceItemIDs.contains(itemID))
        XCTAssertNil(session.testHeldSongStartIndex)
        await session.stop()
    }
}
