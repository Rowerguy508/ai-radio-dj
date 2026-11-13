import XCTest
@testable import AeroDJCore

/// A tail-only queue append after the time of day has moved. The breaks already planned
/// must not stay in the old day part: a pause at 8 AM and songs filled in at 2 PM must
/// not leave the next break greeting the morning.
@MainActor
final class DaypartTailAppendTests: XCTestCase {
    func testATailAppendAfterTheDayPartMovesReplansTheBreaksAlreadyQueued() async {
        var hourNow = 8
        let (session, tone) = await session(hour: { hourNow })
        let reservation = session.reserveQueueSetup()
        session.acceptStationAppends(generation: reservation.generation, queueEpoch: 1)
        let queued = (0..<20).map { DJTrack(id: "s\($0)", title: "Song \($0)", artist: "Artist") }
        await session.beginQueueInBackground(reservation, queued).value
        await session.songStarted(index: 0, remaining: .seconds(1))
        let morning = session.plannedBoundaries.filter { $0 > 0 }
        XCTAssertFalse(morning.isEmpty, "the morning queue planned a later break")
        XCTAssertTrue(morning.allSatisfy { session.testPlannedDayPart(afterTrack: $0) == .morning })

        hourNow = 14
        let tail = (0..<4).map { DJTrack(id: "n\($0)", title: "Later \($0)", artist: "Artist") }
        session.appendStationSongs(tail, generation: reservation.generation, queueEpoch: 1)

        let next = session.plannedBoundaries.filter { $0 > 0 }
        XCTAssertFalse(next.isEmpty, "a break is still planned after the song playing now")
        for k in next {
            XCTAssertEqual(session.testPlannedDayPart(afterTrack: k), .afternoon,
                           "boundary \(k) stayed in the morning after a 2 PM append")
        }
        let spoken = next.flatMap { session.testPlannedBreaks[$0]?.cues.map(\.text) ?? [] }
        XCTAssertFalse(speaks(spoken, anyOf: lines(.morning, tone)), "a morning line is still planned")
        XCTAssertTrue(speaks(spoken, anyOf: lines(.afternoon, tone)), "the afternoon is not in the plan")
        await session.stop()
    }

    private func lines(_ part: DayPart, _ tone: EditorialTone) -> [String] {
        tone.greetings[part, default: []] + tone.atmosphere[part, default: []] + tone.opener.setup[part, default: []]
    }

    private func speaks(_ texts: [String], anyOf pool: [String]) -> Bool {
        texts.contains { text in pool.contains { text.contains($0) } }
    }

    private func session(hour: @escaping () -> Int) async -> (DJBreakSession, EditorialTone) {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let route = VoiceRoute(providerID: "device", provider: TailAppendVoice(), voice: djVoice)
        let renderer = VoiceRenderer(routes: [route], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 1,
                                     hour: hour)
        await session.start()
        return (session, .forPersonality(station.active.personality))
    }
}

private struct TailAppendVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 0.4, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}
