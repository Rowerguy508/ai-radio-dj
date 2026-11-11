import XCTest
@testable import AeroDJCore

/// A prepared station intro airs at the first song boundary through the existing break path.
@MainActor
final class StationIntroAirTests: XCTestCase {
    func testAiringTheIntroSkipsThatSongsPlannedBreak() async throws {
        let (session, _) = await session(commentary: .chatty)
        let reservation = session.reserveQueueSetup()
        await session.beginQueueInBackground(reservation, tracks(8)).value
        XCTAssertTrue(session.plannedBoundaries.contains(0), "the first song has its own break")
        let cue = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "Morning Calm",
                               estimatedSeconds: 1, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        session.stageStationIntro(PreparedDJBreak(afterTrack: StationIntro.afterTrack, cues: [cue], clips: [],
                                                  attributions: [cue.id: .stationName]))
        let boundary = await session.naturalBoundary(afterTrack: 0, airStationIntro: true)
        let aired = try XCTUnwrap(boundary)
        XCTAssertEqual(aired.cues.map(\.id), [cue.id])
        XCTAssertEqual(aired.afterTrack, 0)
        XCTAssertNil(aired.talkOverCueID)
        XCTAssertNil(aired.talkOverStartSeconds)
        XCTAssertTrue(session.testReportedSkips.contains { $0 == (0, .stationIntro) },
                      "the planned break is skipped through breakSkipped")
        let again = await session.naturalBoundary(afterTrack: 0, airStationIntro: true)
        XCTAssertNil(again, "the intro does not air twice, and the planned break stays skipped")
    }

    func testAiringSeamTakesTheIntroAtEveryBoundary() async throws {
        XCTAssertFalse(StationIntroAirGate.mustTakeIntro(airStationIntroIsSet: false))
        XCTAssertTrue(StationIntroAirGate.mustTakeIntro(airStationIntroIsSet: true))
        XCTAssertFalse(StationIntroAirGate.airsIntro(airStationIntroIsSet: true, boundaryAlreadySpoken: true))
        XCTAssertTrue(StationIntroAirGate.airsIntro(airStationIntroIsSet: true, boundaryAlreadySpoken: false))
        let player = try String(contentsOf: source("AeroDJ/StationQueuePlayer.swift"), encoding: .utf8)
        let view = try String(contentsOf: source("AeroDJ/PlayerView.swift"), encoding: .utf8)
        XCTAssertTrue(player.contains("return await createdStart.songBoundary(queueEpoch: queueEpoch)"))
        XCTAssertTrue(player.contains("djSession?.stageStationIntro(prepared)"))
        XCTAssertTrue(view.contains("stationIntroAtBoundary()"))
        XCTAssertEqual(view.components(separatedBy: "stationIntroAtBoundary()").count - 1, 2,
                       "the talk-over boundary and the gap boundary both take the intro")
        XCTAssertTrue(view.contains("StationIntroAirGate.mustTakeIntro"))
    }

    func testIntroNotReadyOrQueueChangeIsSkippedWithoutDelayingTheSong() async {
        let (session, _) = await session(commentary: .frequent)
        let cue = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "Late Night",
                               estimatedSeconds: 1, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        var over = PreparedDJBreak(afterTrack: StationIntro.afterTrack, cues: [cue], clips: [],
                                   attributions: [cue.id: .presenter])
        over.talkOverCueID = cue.id
        session.stageStationIntro(over)
        let started = ContinuousClock.now
        let refused = await session.naturalBoundary(afterTrack: 0, airStationIntro: true)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertNil(refused?.cues.first { $0.id == cue.id }, "a talk-over intro is not played over the song")
        XCTAssertTrue(session.testReportedSkips.contains { $0.1 == .cancelled })

        session.stageStationIntro(PreparedDJBreak(afterTrack: StationIntro.afterTrack, cues: [cue], clips: [],
                                                  attributions: [cue.id: .presenter]))
        await session.songCut(afterTrack: 0)
        let dropped = await session.naturalBoundary(afterTrack: 0, airStationIntro: true)
        XCTAssertNotEqual(dropped?.cues.first?.id, cue.id, "a queue change drops the intro")
        XCTAssertTrue(session.testReportedSkips.contains { $0 == (StationIntro.afterTrack, .cancelled) })
    }

    func testStationIntroAiringKeepsTheSingleLibraryGatedPrepareCall() async throws {
        let text = try String(contentsOf: source("AeroDJCore/Sources/AeroDJCore/DJ/DJBreakSession.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("preparer.prepare(djBreak, deadline: deadline, onDeviceOnly: onDeviceOnly || Self.speaksOnDeviceOnly(station.active))"))
        XCTAssertEqual(text.components(separatedBy: "preparer.prepare(").count - 1, 1, "one prepare call site")
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

    private func session(commentary: CommentaryFrequency) async -> (DJBreakSession, DJPresentationStore) {
        let config = StationConfiguration(commentary: commentary)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(
            routes: [VoiceRoute(providerID: "device", provider: InstantIntroVoice(), voice: djVoice)],
            budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 9 })
        await session.start()
        return (session, dj)
    }
}

private final class InstantIntroVoice: VoiceProvider, @unchecked Sendable {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 0.4, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}
