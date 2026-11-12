import XCTest
@testable import AeroDJCore

/// Appended station songs get DJ breaks, and a new queue cancels an intro render in flight.
@MainActor
final class StationAppendBreakTests: XCTestCase {
    func testAppendedSongsGetBreaksAndAStaleAppendDoesNot() async throws {
        let (session, _) = await session(commentary: .chatty)
        let first = session.reserveQueueSetup()
        session.acceptStationAppends(generation: first.generation, queueEpoch: 1)
        await session.beginQueueInBackground(first, [DJTrack(id: "a", title: "First", artist: "A")]).value
        XCTAssertTrue(session.plannedBoundaries.isEmpty, "one song has no break yet")
        let filled = (1...4).map { DJTrack(id: "b\($0)", title: "Next \($0)", artist: "B") }
        session.appendStationSongs(filled, generation: first.generation, queueEpoch: 1)
        let afterFill = session.plannedBoundaries
        XCTAssertFalse(afterFill.isEmpty, "the appended songs are in the plan")
        XCTAssertTrue(afterFill.contains { $0 >= 1 }, "a break sits on an appended song")
        let kept = session.testPlannedBreaks[afterFill[0]]
        session.appendStationSongs([DJTrack(id: "c", title: "Later", artist: "C")],
                                   generation: first.generation, queueEpoch: 1)
        XCTAssertEqual(session.testPlannedBreaks[afterFill[0]], kept, "the first plan is not replaced")
        XCTAssertEqual(Set(session.plannedBoundaries).count, session.plannedBoundaries.count)
        XCTAssertFalse(session.plannedBoundaries.contains(where: { boundary in
            session.plannedBoundaries.filter { $0 == boundary }.count > 1
        }))
        let switched = session.reserveQueueSetup()
        session.acceptStationAppends(generation: switched.generation, queueEpoch: 2)
        await session.beginQueueInBackground(switched, tracks(2)).value
        let switchedPlan = session.plannedBoundaries
        session.appendStationSongs(filled, generation: first.generation, queueEpoch: 1)
        XCTAssertEqual(session.plannedBoundaries, switchedPlan, "a stale append after a switch is ignored")
        XCTAssertEqual(session.testQueueTrackIDs, ["t0", "t1"])
        let player = try String(contentsOf: source("AeroDJ/StationQueuePlayer.swift"), encoding: .utf8)
        XCTAssertTrue(player.contains("onStationSongsAppended = { [weak self] tracks in"))
        XCTAssertTrue(player.contains("djSession.appendStationSongs(tracks, generation: self.armedAppendGeneration,"))
    }

    func testSongTapOrNewStationCancelsAnInFlightIntro() async throws {
        let voice = HangingIntroVoice()
        let budget = VoiceBudget(dailyCapMicrodollars: 1_000_000)
        let (session, _) = await session(commentary: .frequent, voice: voice, paid: true, budget: budget)
        session.beginStationIntro(StationIntroFacts(
            id: "morning", name: DJScriptWriter.builtInStationName,
            seeds: [StationSeed(kind: .song, catalogID: "1", name: "Seed Song", source: .catalog)]))
        try await waitUntil { voice.started >= 1 }
        _ = session.reserveQueueSetup()
        try await waitUntil { voice.active == 0 }
        let spent = await budget.committed(userID: "u")
        XCTAssertEqual(spent, 0, "the cancelled intro is not committed")
        let taken = await session.takeStationIntroAtSongStart(id: "morning")
        XCTAssertNil(taken, "the new queue does not air the cancelled intro")
    }

    private func source(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    private func tracks(_ n: Int) -> [DJTrack] {
        (0..<n).map { DJTrack(id: "t\($0)", title: "Song \($0)", artist: "Artist \($0)") }
    }

    private func session(commentary: CommentaryFrequency, voice: (any VoiceProvider)? = nil,
                         paid: Bool = false, budget: VoiceBudget? = nil) async -> (DJBreakSession, DJPresentationStore) {
        let config = StationConfiguration(commentary: commentary)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let provider = voice ?? InstantIntroVoice()
        let route = VoiceRoute(providerID: paid ? "paid" : "device", provider: provider, voice: djVoice,
                               microdollarsPerThousandCharacters: paid ? 1_000 : 0, leavesDevice: paid)
        let renderer = VoiceRenderer(routes: [route], budget: budget ?? VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 9 })
        await session.start()
        return (session, dj)
    }

    private func waitUntil(_ ready: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out")
    }
}

private final class InstantIntroVoice: VoiceProvider, @unchecked Sendable {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 0.4, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

private final class HangingIntroVoice: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var entries = 0
    private var inFlight = 0
    var started: Int { lock.lock(); defer { lock.unlock() }; return entries }
    var active: Int { lock.lock(); defer { lock.unlock() }; return inFlight }

    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        enter()
        defer { leave() }
        try await Task.sleep(for: .seconds(30))
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: 0.4, billableUnits: text.count, provider: "paid", cacheKey: nil)
    }

    private func enter() { lock.lock(); entries += 1; inFlight += 1; lock.unlock() }
    private func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
}
