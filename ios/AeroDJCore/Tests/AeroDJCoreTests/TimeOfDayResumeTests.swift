import XCTest
@testable import AeroDJCore

/// A voice that never finishes on its own: a render stays in flight until it is cancelled, so a
/// test decides what is "prepared" with `testRecord`. Cancellation ends the wait. No sleeps.
private struct HangingVoice: VoiceProvider {
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

/// The injected wall clock. Tests move it; nothing reads the system clock.
private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// #445 (-Atlas): "stuck on morning". The DJ's time of day (`DayPart`) comes from the session's
/// injected clock for every plan: a pause at 8 AM and a Play (or the app coming to the
/// foreground) at 2 PM or 9 PM re-plans the show for the afternoon or evening and greets again; a
/// break prepared in the morning is dropped at its boundary; one prepared in the same day part is
/// kept. The session is built without `hour:`, so the one `now` seam drives the day part.
@MainActor
final class TimeOfDayResumeTests: XCTestCase {
    private static let eastern: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private static func at(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
        eastern.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private struct Rig {
        let session: DJBreakSession
        let preparer: DJBreakPreparer
        let clock: TestClock
        let tone: EditorialTone
    }

    private func rig(startingAt start: Date, seed: UInt64 = 1) async -> Rig {
        let config = StationConfiguration(genres: ["jazz", "soul"], moods: ["mellow"], commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: HangingVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let clock = TestClock(start)
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: seed,
                                     now: { clock.now }, calendar: Self.eastern)
        await session.start()
        return Rig(session: session, preparer: preparer, clock: clock,
                   tone: .forPersonality(station.active.personality))
    }

    /// Every line of the tone that belongs to one day part: greetings, atmosphere, opener setup.
    private func lines(_ part: DayPart, _ tone: EditorialTone) -> [String] {
        tone.greetings[part, default: []] + tone.atmosphere[part, default: []] + tone.opener.setup[part, default: []]
    }

    private func texts(_ session: DJBreakSession, after k: Int) -> [String] {
        session.testPlannedBreaks.filter { $0.key > k }.values.flatMap { $0.cues.map(\.text) }
    }

    private func speaks(_ texts: [String], anyOf pool: [String]) -> Bool {
        texts.contains { text in pool.contains { text.contains($0) } }
    }

    /// The first break greets in `part`: the opener's welcome starts with that day part's greeting.
    private func greets(_ session: DJBreakSession, after k: Int, in part: DayPart, _ tone: EditorialTone) -> Bool {
        guard let first = session.testPlannedBreaks.filter({ $0.key > k }).min(by: { $0.key < $1.key })?.value,
              let text = first.cues.first?.text else { return false }
        return tone.greetings[part, default: []].contains { text.hasPrefix($0) }
    }

    private func openers(_ session: DJBreakSession, after k: Int) -> [Int] {
        session.testPlannedBreaks.filter { $0.key > k && $0.value.shape == .showOpener }.keys.sorted()
    }

    /// Opens the show at `start` and airs the opener: the song after it is playing. `remaining`
    /// is inside the boundary margin, so nothing renders. Returns the playing song.
    private func openTheShow(_ r: Rig, file: StaticString = #filePath, line: UInt = #line) async -> Int {
        await r.session.queueStarted(djTracks(30))
        let opened = openers(r.session, after: -1)
        XCTAssertEqual(opened.count, 1, "the queue opens the show", file: file, line: line)
        let k = opened.first ?? 0
        await r.session.songStarted(index: k + 1, remaining: .seconds(1))
        return k + 1
    }

    /// A ready break with exactly the cues the session planned for boundary `k`.
    private func recordReady(_ r: Rig, afterTrack k: Int) async throws {
        let planned = try XCTUnwrap(r.session.testPlannedBreaks[k], "a break is planned after song \(k)")
        await r.preparer.testRecord(.ready(PreparedDJBreak(
            afterTrack: k, cues: planned.cues, clips: [], attributions: planned.attributions)), afterTrack: k)
    }

    // MARK: Bucket boundaries

    func testDayPartBucketBoundaries() {
        let expected: [(Int, DayPart)] = [
            (0, .lateNight), (3, .lateNight), (4, .earlyMorning), (6, .earlyMorning), (7, .morning),
            (11, .morning), (12, .afternoon), (16, .afternoon), (17, .evening), (21, .evening),
            (22, .lateNight), (23, .lateNight),
        ]
        for (hour, part) in expected { XCTAssertEqual(DayPart(hour: hour), part, "\(hour):00") }
    }

    /// The session reads the hour from its injected clock in its calendar's time zone (no `hour:`).
    func testTheSessionReadsTheDayPartFromTheInjectedClock() async {
        for (hour, part) in [(8, DayPart.morning), (14, .afternoon), (21, .evening)] {
            let r = await rig(startingAt: Self.at(hour))
            await r.session.queueStarted(djTracks(30))
            XCTAssertTrue(greets(r.session, after: -1, in: part, r.tone), "\(hour):00 opens in \(part)")
            await r.session.stop()
        }
    }

    // MARK: Pause in the morning, resume later

    func testPauseAtEightResumeAtTwoGreetsTheAfternoonAndSaysNothingMorning() async {
        for seed in UInt64(0)..<10 {
            let r = await rig(startingAt: Self.at(8), seed: seed)
            let playing = await openTheShow(r)
            XCTAssertTrue(greets(r.session, after: -1, in: .morning, r.tone), "seed \(seed): 8 AM greets the morning")

            r.clock.now = Self.at(14)                      // paused for six hours
            r.session.timeOfDayMayHaveChanged()            // Play (or foreground) at 2 PM
            XCTAssertTrue(greets(r.session, after: playing, in: .afternoon, r.tone),
                          "seed \(seed): the next break greets the afternoon")
            XCTAssertEqual(openers(r.session, after: playing).count, 1, "seed \(seed): the show opens again, once")
            let later = texts(r.session, after: playing)
            XCTAssertFalse(speaks(later, anyOf: lines(.morning, r.tone) + lines(.earlyMorning, r.tone)),
                           "seed \(seed): no morning greeting, atmosphere or setup after 2 PM")
            await r.session.stop()
        }
    }

    func testPauseAtEightResumeAtNineInTheEveningGreetsTheEvening() async {
        for seed in UInt64(0)..<10 {
            let r = await rig(startingAt: Self.at(8), seed: seed)
            let playing = await openTheShow(r)
            r.clock.now = Self.at(21)
            r.session.timeOfDayMayHaveChanged()
            XCTAssertTrue(greets(r.session, after: playing, in: .evening, r.tone), "seed \(seed): 9 PM greets the evening")
            let later = texts(r.session, after: playing)
            XCTAssertFalse(speaks(later, anyOf: lines(.morning, r.tone) + lines(.afternoon, r.tone)),
                           "seed \(seed): nothing morning or afternoon at 9 PM")
            await r.session.stop()
        }
    }

    /// Foreground recompute in the same day part changes nothing: no re-plan, no second opener.
    func testForegroundInTheSameDayPartKeepsThePlan() async {
        let r = await rig(startingAt: Self.at(8))
        let playing = await openTheShow(r)
        let before = r.session.testPlannedBreaks
        r.clock.now = Self.at(11, 59)
        r.session.timeOfDayMayHaveChanged()
        XCTAssertEqual(r.session.testPlannedBreaks, before, "still morning: the plan is untouched")
        XCTAssertEqual(openers(r.session, after: playing), [], "no second opener")
        await r.session.stop()
    }

    /// Foreground and resume are the same call: repeating it after the re-plan is a no-op.
    func testARepeatedRecomputeInTheNewDayPartIsANoOp() async {
        let r = await rig(startingAt: Self.at(8))
        let playing = await openTheShow(r)
        r.clock.now = Self.at(14)
        r.session.timeOfDayMayHaveChanged()            // foreground
        let replanned = r.session.testPlannedBreaks
        r.session.timeOfDayMayHaveChanged()            // then Play
        XCTAssertEqual(r.session.testPlannedBreaks, replanned)
        XCTAssertEqual(openers(r.session, after: playing).count, 1)
        await r.session.stop()
    }

    /// Without any foreground or Play (continuous listening across noon), the next song start
    /// re-plans its break and the rest in the afternoon. The show does not open a second time.
    func testContinuousPlayAcrossNoonReplansAtTheNextSongWithoutAGreeting() async {
        let r = await rig(startingAt: Self.at(11))
        let playing = await openTheShow(r)
        r.clock.now = Self.at(12, 5)
        guard let next = r.session.plannedBoundaries.first(where: { $0 > playing }) else {
            return XCTFail("a later break is planned")
        }
        await r.session.songStarted(index: next, remaining: .seconds(180))
        let later = r.session.testPlannedBreaks.filter { $0.key >= next }.values.flatMap { $0.cues.map(\.text) }
        XCTAssertFalse(speaks(later, anyOf: lines(.morning, r.tone)), "no morning lines after noon")
        XCTAssertEqual(openers(r.session, after: playing), [], "no second opener mid-show")
        await r.session.stop()
    }

    // MARK: Prepared breaks

    /// A break prepared at 8 AM and reached at 2 PM (paused mid-song) is not handed out: music
    /// plays at once, and the rest of the queue is planned for the afternoon.
    func testAStalePreparedBreakIsDiscardedAtItsBoundary() async throws {
        let r = await rig(startingAt: Self.at(8))
        let playing = await openTheShow(r)
        let k = try XCTUnwrap(r.session.plannedBoundaries.first { $0 >= playing })
        await r.session.songStarted(index: k, remaining: .seconds(180))
        try await recordReady(r, afterTrack: k)

        r.clock.now = Self.at(14)
        r.session.timeOfDayMayHaveChanged()
        let handed = await r.session.naturalBoundary(afterTrack: k)
        XCTAssertNil(handed, "a morning break never airs in the afternoon")
        XCTAssertEqual(r.session.lastNoBreak?.reason, .cancelled)
        XCTAssertNil(r.session.testPlannedBreaks[k], "dropped, not kept for later")
        XCTAssertFalse(speaks(texts(r.session, after: k), anyOf: lines(.morning, r.tone)),
                       "what is still planned is afternoon copy")
        await r.session.stop()
    }

    /// The same without any foreground or Play hook: the boundary alone catches it.
    func testAStalePreparedBreakIsDiscardedEvenWithoutAResumeCall() async throws {
        let r = await rig(startingAt: Self.at(8))
        let playing = await openTheShow(r)
        let k = try XCTUnwrap(r.session.plannedBoundaries.first { $0 >= playing })
        await r.session.songStarted(index: k, remaining: .seconds(180))
        try await recordReady(r, afterTrack: k)
        r.clock.now = Self.at(21)
        let handed = await r.session.naturalBoundary(afterTrack: k)
        XCTAssertNil(handed)
        XCTAssertEqual(r.session.lastNoBreak?.reason, .cancelled)
        await r.session.stop()
    }

    /// A seek after the resume re-plans the playing song's break in the afternoon, but the
    /// preparer still holds the morning audio: it is still dropped at the boundary.
    func testASeekAfterTheResumeDoesNotLaunderTheMorningAudio() async throws {
        let r = await rig(startingAt: Self.at(8))
        let playing = await openTheShow(r)
        let k = try XCTUnwrap(r.session.plannedBoundaries.first { $0 >= playing })
        await r.session.songStarted(index: k, remaining: .seconds(180))
        try await recordReady(r, afterTrack: k)
        r.clock.now = Self.at(14)
        await r.session.songSeeked(index: k, remaining: .seconds(120))
        let handed = await r.session.naturalBoundary(afterTrack: k)
        XCTAssertNil(handed, "the ready audio is still the morning's")
        await r.session.stop()
    }

    /// A break prepared and reached in the same day part is handed out as before.
    func testAFreshPreparedBreakIsKept() async throws {
        let r = await rig(startingAt: Self.at(8))
        let playing = await openTheShow(r)
        let k = try XCTUnwrap(r.session.plannedBoundaries.first { $0 >= playing })
        await r.session.songStarted(index: k, remaining: .seconds(180))
        try await recordReady(r, afterTrack: k)
        r.clock.now = Self.at(11, 30)                  // still morning
        r.session.timeOfDayMayHaveChanged()
        let taken = await r.session.naturalBoundary(afterTrack: k)
        let handed = try XCTUnwrap(taken, "same day part: it airs")
        XCTAssertEqual(handed.cues.map(\.id), r.session.testPlannedBreaks[k]?.cues.map(\.id))
        XCTAssertNil(r.session.lastNoBreak)
        await r.session.stop()
    }

    /// A song that starts after the resume prepares the afternoon break, which then airs.
    func testTheBreakPreparedAfterTheResumeAirs() async throws {
        let r = await rig(startingAt: Self.at(8))
        let playing = await openTheShow(r)
        r.clock.now = Self.at(14)
        r.session.timeOfDayMayHaveChanged()
        let k = try XCTUnwrap(r.session.plannedBoundaries.first { $0 > playing })
        await r.session.songStarted(index: k, remaining: .seconds(180))
        try await recordReady(r, afterTrack: k)
        let taken = await r.session.naturalBoundary(afterTrack: k)
        let handed = try XCTUnwrap(taken, "the afternoon break airs")
        XCTAssertFalse(speaks(handed.cues.map(\.text), anyOf: lines(.morning, r.tone)))
        await r.session.stop()
    }

    // MARK: App wiring (iOS-only files, checked from source on Linux)

    func testTheAppRecomputesOnPlayAndOnForeground() throws {
        let queue = try appSource("StationQueuePlayer.swift")
        XCTAssertTrue(queue.contains("music.onUserResumed = { [weak self] in self?.djSession.timeOfDayMayHaveChanged() }"))
        XCTAssertTrue(queue.contains("UIApplication.willEnterForegroundNotification"))
        XCTAssertTrue(queue.contains("MainActor.assumeIsolated { self?.djSession.timeOfDayMayHaveChanged() }"))
        let music = try appSource("MusicKitService.swift")
        let start = try XCTUnwrap(music.range(of: "func resume() async throws {"))
        let resume = music[start.upperBound...].prefix(4000)
        XCTAssertTrue(resume.contains("send(.userResumed)\n            stateMachine.apply(.resume)\n            onUserResumed?()"),
                      "Play reports the resume after the gate passed")
        let deps = try appSource("AppDependencies.swift")
        XCTAssertFalse(deps.contains("hour:"), "the live session reads the hour from its clock, not a launch value")
    }

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
