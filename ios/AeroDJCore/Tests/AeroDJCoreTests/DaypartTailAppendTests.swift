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

    /// The break after the song playing now is already ready with the morning greeting. Appending
    /// songs at 2 PM keeps that break (`keepingThrough: playing`). Its hand-out must drop it, and
    /// the show must greet the afternoon once. "Good morning" must not air ahead of that greeting.
    func testAReadyMorningBreakAfterThePlayingSongDoesNotAirOnATwoPMAppend() async throws {
        let hour = Hour()
        let (session, tone, k, generation) = try await readyMorningBreak(hour: hour)
        hour.value = 14
        let tail = (0..<4).map { DJTrack(id: "n\($0)", title: "Later \($0)", artist: "Artist") }
        session.appendStationSongs(tail, generation: generation, queueEpoch: 1)
        let aired = await air(session, from: k)
        assertOneNewGreeting(aired, tone: tone)
        await session.stop()
    }

    /// The same ready morning break, reached by Play at 2 PM instead of an append.
    func testAReadyMorningBreakAfterThePlayingSongDoesNotAirOnATwoPMResume() async throws {
        let hour = Hour()
        let (session, tone, k, _) = try await readyMorningBreak(hour: hour)
        hour.value = 14
        session.timeOfDayMayHaveChanged()
        let aired = await air(session, from: k)
        assertOneNewGreeting(aired, tone: tone)
        await session.stop()
    }

    private func lines(_ part: DayPart, _ tone: EditorialTone) -> [String] {
        tone.greetings[part, default: []] + tone.atmosphere[part, default: []] + tone.opener.setup[part, default: []]
    }

    private func speaks(_ texts: [String], anyOf pool: [String]) -> Bool {
        texts.contains { text in pool.contains { text.contains($0) } }
    }

    private func greetingCount(_ texts: [String], _ part: DayPart, _ tone: EditorialTone) -> Int {
        let pool = tone.greetings[part, default: []]
        return texts.filter { text in pool.contains { text.hasPrefix($0) } }.count
    }

    private func assertOneNewGreeting(_ aired: [String], tone: EditorialTone, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(speaks(aired, anyOf: lines(.morning, tone)), "a morning line aired: \(aired)", file: file, line: line)
        XCTAssertEqual(greetingCount(aired, .afternoon, tone), 1, "aired greetings: \(aired)", file: file, line: line)
    }

    /// Queues at 8 AM and leaves the break after the playing song ready, with morning wording.
    private func readyMorningBreak(hour: Hour) async throws -> (DJBreakSession, EditorialTone, Int, Int) {
        let (session, tone) = await session(hour: { hour.value })
        let reservation = session.reserveQueueSetup()
        session.acceptStationAppends(generation: reservation.generation, queueEpoch: 1)
        let queued = (0..<20).map { DJTrack(id: "s\($0)", title: "Song \($0)", artist: "Artist") }
        await session.beginQueueInBackground(reservation, queued).value
        let k = try XCTUnwrap(session.plannedBoundaries.first, "the morning queue plans a break")
        await session.songStarted(index: k, remaining: .seconds(180))
        let morning = try XCTUnwrap(session.testPlannedBreaks[k])
        XCTAssertEqual(session.testPreparedDayPart(afterTrack: k), .morning)
        XCTAssertEqual(greetingCount(morning.cues.map(\.text), .morning, tone), 1, "the ready break greets the morning")
        await session.testPreparer.testRecord(.ready(PreparedDJBreak(
            afterTrack: k, cues: morning.cues, clips: [], attributions: morning.attributions)), afterTrack: k)
        let ready = await session.testPreparer.isReady(afterTrack: k)
        XCTAssertTrue(ready)
        return (session, tone, k, reservation.generation)
    }

    /// Hands out every break from `start` on. A ready break is taken as the preparer holds it.
    /// One that is only planned is recorded from the plan first, so a re-plan is what airs.
    private func air(_ session: DJBreakSession, from start: Int) async -> [String] {
        var aired: [String] = []
        var i = start
        while i < session.testQueueTrackIDs.count - 1 {
            if await session.testPreparer.isReady(afterTrack: i) {
                if let handed = await session.naturalBoundary(afterTrack: i) {
                    aired.append(contentsOf: handed.cues.map(\.text))
                }
            } else if session.testPlannedBreaks[i] != nil {
                await session.songStarted(index: i, remaining: .seconds(180))
                if let planned = session.testPlannedBreaks[i] {
                    await session.testPreparer.testRecord(.ready(PreparedDJBreak(
                        afterTrack: i, cues: planned.cues, clips: [], attributions: planned.attributions)), afterTrack: i)
                }
                if let handed = await session.naturalBoundary(afterTrack: i) {
                    aired.append(contentsOf: handed.cues.map(\.text))
                }
            }
            i += 1
        }
        return aired
    }

    private func session(hour: @escaping () -> Int) async -> (DJBreakSession, EditorialTone) {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let route = VoiceRoute(providerID: "device", provider: HangingTailVoice(), voice: djVoice)
        let renderer = VoiceRenderer(routes: [route], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 1,
                                     hour: hour)
        await session.start()
        return (session, .forPersonality(station.active.personality))
    }
}

private final class Hour: @unchecked Sendable {
    var value = 8
}

private struct HangingTailVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
        throw CancellationError()
    }
}
