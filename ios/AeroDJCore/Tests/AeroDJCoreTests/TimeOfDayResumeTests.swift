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

    private func rig(startingAt start: Date, seed: UInt64 = 1, calendar: Calendar = TimeOfDayResumeTests.eastern) async -> Rig {
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
                                     now: { clock.now }, calendar: calendar)
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

    // MARK: The day part goes with the audio the preparer holds (GPT-6 P1 on #447)

    /// Ready audio for exactly `planned` (a break the session handed out earlier).
    private func recordReady(_ r: Rig, _ planned: DJBreak, afterTrack k: Int) async {
        await r.preparer.testRecord(.ready(PreparedDJBreak(
            afterTrack: k, cues: planned.cues, clips: [], attributions: planned.attributions)), afterTrack: k)
    }

    /// The song after the opener starts at 8 AM and its break is prepared in the morning. Returns
    /// the boundary and the morning break the preparer was given.
    private func prepareAMorningBreak(_ r: Rig, file: StaticString = #filePath,
                                      line: UInt = #line) async throws -> (Int, DJBreak) {
        let playing = await openTheShow(r, file: file, line: line)
        let k = try XCTUnwrap(r.session.plannedBoundaries.first { $0 >= playing }, file: file, line: line)
        await r.session.songStarted(index: k, remaining: .seconds(180))
        let morning = try XCTUnwrap(r.session.testPlannedBreaks[k], file: file, line: line)
        XCTAssertEqual(r.session.testPlannedDayPart(afterTrack: k), .morning, file: file, line: line)
        XCTAssertEqual(r.session.testPreparedDayPart(afterTrack: k), .morning, "the accepted render is tagged",
                       file: file, line: line)
        return (k, morning)
    }

    /// A duplicate start report for song `k` at 2 PM re-plans `k` in the afternoon. The preparer
    /// keeps the morning audio it already has; the tag must not move to the new plan.
    private func duplicateStartAtTwo(_ r: Rig, afterTrack k: Int, morning: DJBreak,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        r.clock.now = Self.at(14)
        await r.session.songStarted(index: k, remaining: .seconds(170))
        let replanned = try XCTUnwrap(r.session.testPlannedBreaks[k], "a new plan for the same boundary",
                                      file: file, line: line)
        XCTAssertNotEqual(replanned.cues.map(\.id), morning.cues.map(\.id), "re-planned", file: file, line: line)
        XCTAssertEqual(r.session.testPlannedDayPart(afterTrack: k), .afternoon, file: file, line: line)
        XCTAssertEqual(r.session.testPreparedDayPart(afterTrack: k), .morning,
                       "the preparer ignored the duplicate: the tag stays the morning's", file: file, line: line)
    }

    /// (1) Ready morning audio, clock to 2 PM, duplicate `songStarted(k)` with a new plan for k:
    /// the take drops it.
    func testADuplicateSongStartDoesNotRelabelReadyMorningAudio() async throws {
        let r = await rig(startingAt: Self.at(8))
        let (k, morning) = try await prepareAMorningBreak(r)
        await recordReady(r, morning, afterTrack: k)
        try await duplicateStartAtTwo(r, afterTrack: k, morning: morning)
        let handed = await r.session.naturalBoundary(afterTrack: k)
        XCTAssertNil(handed, "the morning audio never airs at 2 PM")
        XCTAssertEqual(r.session.lastNoBreak?.reason, .cancelled)
        await r.session.stop()
    }

    /// (2) The same while the morning render is still in flight at the duplicate start; it
    /// finishes afterwards with the morning cues and is dropped at the take.
    func testADuplicateSongStartDoesNotRelabelAnInFlightMorningRender() async throws {
        let r = await rig(startingAt: Self.at(8))
        let (k, morning) = try await prepareAMorningBreak(r)
        let inFlight = await r.preparer.testInFlight
        XCTAssertTrue(inFlight.contains(k), "the morning render is still running")
        try await duplicateStartAtTwo(r, afterTrack: k, morning: morning)
        await recordReady(r, morning, afterTrack: k)    // the morning render finishes
        let handed = await r.session.naturalBoundary(afterTrack: k)
        XCTAssertNil(handed, "the in-flight morning render never airs at 2 PM")
        XCTAssertEqual(r.session.lastNoBreak?.reason, .cancelled)
        await r.session.stop()
    }

    /// (3) A seek re-arms the morning break; while `songSeeked` is suspended on `rearm`, the
    /// clock passes noon and a duplicate start re-plans the boundary. The re-armed render keeps
    /// the tag read before the await (morning) and is dropped at the take.
    func testTheRearmTagIsReadBeforeTheAwait() async throws {
        let r = await rig(startingAt: Self.at(8))
        let playing = await openTheShow(r)
        let k = try XCTUnwrap(r.session.plannedBoundaries.first { $0 >= playing })
        await r.session.songStarted(index: k, remaining: .seconds(1))    // too late to render
        let morning = try XCTUnwrap(r.session.testPlannedBreaks[k])
        XCTAssertNil(r.session.testPreparedDayPart(afterTrack: k), "nothing was prepared")
        let session = r.session, clock = r.clock
        session.testRearmReturned = {
            session.testRearmReturned = nil
            clock.now = Self.at(14)
            await session.songStarted(index: k, remaining: .seconds(170))   // re-plans k; prepare no-ops
        }
        await r.session.songSeeked(index: k, remaining: .seconds(180))     // seek back: re-arm at 8 AM
        XCTAssertEqual(r.session.testPlannedDayPart(afterTrack: k), .afternoon, "re-planned during the await")
        XCTAssertEqual(r.session.testPreparedDayPart(afterTrack: k), .morning, "the re-armed render is the morning's")
        await recordReady(r, morning, afterTrack: k)
        let handed = await r.session.naturalBoundary(afterTrack: k)
        XCTAssertNil(handed, "the re-armed morning render never airs at 2 PM")
        await r.session.stop()
    }

    /// (4) Ready audio with no day-part tag (the session never handed the preparer a break for
    /// that boundary) is of unknown time of day: dropped, even in the same day part.
    func testReadyAudioWithNoDayPartTagIsDropped() async throws {
        let r = await rig(startingAt: Self.at(8))
        let playing = await openTheShow(r)
        let k = try XCTUnwrap(r.session.plannedBoundaries.first { $0 >= playing })
        await r.session.songStarted(index: k, remaining: .seconds(1))    // nothing prepared, no tag
        XCTAssertNil(r.session.testPreparedDayPart(afterTrack: k))
        try await recordReady(r, afterTrack: k)
        let handed = await r.session.naturalBoundary(afterTrack: k)
        XCTAssertNil(handed, "untagged audio fails closed")
        XCTAssertEqual(r.session.lastNoBreak?.reason, .cancelled)
        await r.session.stop()
    }

    // MARK: Approved all-day personal updates across the re-plan (#332)

    /// (5) An approved update aired at 8 AM never airs again after the 2 PM re-plan; an approved,
    /// valid one not aired yet still airs (once); one that expired at 1 PM or was revoked never airs.
    func testApprovedPersonalUpdatesAcrossTheAfternoonReplan() async throws {
        let r = await rig(startingAt: Self.at(8))
        let ids = (0..<4).map { _ in UUID() }
        let (first, valid, expiring, revoked) = (ids[0], ids[1], ids[2], ids[3])
        let titles = ["Dentist at 4", "Pick up the dry cleaning", "Parking permit", "Book club"]
        let cues = ids.enumerated().map { i, id in
            NarrationCue(id: UUID(), order: i + 1, group: i, kind: .note, text: "From your notes: \(titles[i]).",
                         estimatedSeconds: 4, maxSeconds: 16, sourceItemID: id, source: .obsidian, provenance: "note:\(i)")
        }
        let rows = ids.enumerated().map { i, id in
            ConnectionItem(id: id, integration: .obsidian, title: titles[i], state: .approved,
                           expiresAt: id == expiring ? Self.at(13) : nil, sensitivity: .low)
        }
        await r.session.queueStarted(djTracks(30), briefing: NarrationHandoff(cues: cues, maxSpokenSeconds: 60,
                                                                              experienceSeconds: 300), sources: rows)
        var next = 0
        /// Plays songs from `next` on, airing every break, until `stop` says so. Returns the
        /// personal items aired.
        func play(until stop: ([UUID]) -> Bool) async throws -> [UUID] {
            var aired: [UUID] = []
            while next < 29, !stop(aired) {
                let k = next
                next += 1
                guard r.session.testPlannedBreaks[k] != nil else {
                    await r.session.songStarted(index: k, remaining: .seconds(1))
                    continue
                }
                await r.session.songStarted(index: k, remaining: .seconds(180))
                try await recordReady(r, afterTrack: k)
                guard let handed = await r.session.naturalBoundary(afterTrack: k) else { continue }
                r.session.playbackStarted(afterTrack: k)
                for cue in handed.cues { r.session.lineFinished(afterTrack: k, cueID: cue.id) }
                r.session.playbackFinished(afterTrack: k)
                aired += handed.cues.compactMap(\.sourceItemID)
            }
            return aired
        }
        let morning = try await play { !$0.isEmpty }
        XCTAssertEqual(morning, [first], "the first approved update airs in the morning")

        r.clock.now = Self.at(14)                          // paused until 2 PM
        r.session.purge(sourceItemIDs: [revoked])          // revoked while paused
        r.session.timeOfDayMayHaveChanged()                // Play at 2 PM: re-planned
        let afternoon = try await play { _ in false }
        XCTAssertFalse(afternoon.contains(first), "aired once: never re-airs after the re-plan")
        XCTAssertEqual(afternoon.filter { $0 == valid }.count, 1, "an approved update not aired yet is still eligible")
        XCTAssertFalse(afternoon.contains(expiring), "expired at 1 PM: never aired")
        XCTAssertFalse(afternoon.contains(revoked), "revoked: never aired")
        await r.session.stop()
    }

    // MARK: Midnight and time-zone changes

    /// (6a) Midnight: 11:50 PM to 12:10 AM is late night on both sides, so the prepared break airs;
    /// 9:50 PM (evening) to 12:10 AM is dropped and the show greets the late night.
    func testMidnightCrossing() async throws {
        let sameNight = await rig(startingAt: Self.at(23, 50))
        let (k1, b1) = try await prepareABreak(sameNight, .lateNight)
        await recordReady(sameNight, b1, afterTrack: k1)
        sameNight.clock.now = Self.at(0, 10, day: 11)
        sameNight.session.timeOfDayMayHaveChanged()
        let kept = await sameNight.session.naturalBoundary(afterTrack: k1)
        XCTAssertNotNil(kept, "still late night after midnight: it airs")
        await sameNight.session.stop()

        let evening = await rig(startingAt: Self.at(21, 50))
        let (k2, b2) = try await prepareABreak(evening, .evening)
        await recordReady(evening, b2, afterTrack: k2)
        evening.clock.now = Self.at(0, 10, day: 11)
        evening.session.timeOfDayMayHaveChanged()
        XCTAssertTrue(greets(evening.session, after: k2, in: .lateNight, evening.tone), "greets the late night")
        let dropped = await evening.session.naturalBoundary(afterTrack: k2)
        XCTAssertNil(dropped, "an evening break never airs after midnight")
        await evening.session.stop()
    }

    /// (6b) A time-zone change with the clock standing still: the app's calendar follows the
    /// device time zone (`.autoupdatingCurrent`). 10 AM in New York is midnight in Tokyo: the
    /// morning break is dropped and the show greets the late night.
    func testATimeZoneChangeMovesTheDayPart() async throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        try XCTSkipUnless(Calendar.autoupdatingCurrent.timeZone.identifier == "America/New_York",
                          "this platform's autoupdating calendar does not follow NSTimeZone.default")
        let r = await rig(startingAt: Self.at(10), calendar: .autoupdatingCurrent)
        let (k, morning) = try await prepareAMorningBreak(r)
        await recordReady(r, morning, afterTrack: k)
        NSTimeZone.default = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(Calendar.autoupdatingCurrent.component(.hour, from: r.clock.now), 0)
        r.session.timeOfDayMayHaveChanged()                // the app comes to the foreground
        XCTAssertTrue(greets(r.session, after: k, in: .lateNight, r.tone), "greets the late night in Tokyo")
        let handed = await r.session.naturalBoundary(afterTrack: k)
        XCTAssertNil(handed, "the New York morning break never airs at midnight in Tokyo")
        await r.session.stop()
    }

    /// Opens the show and prepares the next break; it is tagged with `part`, the day part now.
    private func prepareABreak(_ r: Rig, _ part: DayPart) async throws -> (Int, DJBreak) {
        let playing = await openTheShow(r)
        let k = try XCTUnwrap(r.session.plannedBoundaries.first { $0 >= playing })
        await r.session.songStarted(index: k, remaining: .seconds(180))
        XCTAssertEqual(r.session.testPreparedDayPart(afterTrack: k), part)
        return (k, try XCTUnwrap(r.session.testPlannedBreaks[k]))
    }

    // MARK: Play after a lock-screen Next while paused (#444's advance path)

    /// Paused at 8 AM, a lock-screen Next is pressed, and Play at 2 PM takes it (#459): the
    /// skipped song is cut and the next one starts. The app re-reads the day part before that
    /// start, so the show greets the afternoon once and nothing morning is left.
    func testAPlayThatAdvancesPastTheSkippedSongGreetsTheNewDayPart() async {
        for seed in UInt64(0)..<10 {
            let r = await rig(startingAt: Self.at(8), seed: seed)
            let playing = await openTheShow(r)
            r.clock.now = Self.at(14)
            r.session.timeOfDayMayHaveChanged()                     // Play at 2 PM (advance path)
            await r.session.songCut(afterTrack: playing)            // the skipped song
            await r.session.songStarted(index: playing + 1, remaining: .seconds(180))
            XCTAssertTrue(greets(r.session, after: playing, in: .afternoon, r.tone),
                          "seed \(seed): the show greets the afternoon")
            XCTAssertEqual(openers(r.session, after: playing).count, 1, "seed \(seed): one opener")
            XCTAssertFalse(speaks(texts(r.session, after: playing), anyOf: lines(.morning, r.tone)),
                           "seed \(seed): no morning lines after 2 PM")
            await r.session.stop()
        }
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
        XCTAssertTrue(resume.contains("case .played:"), "Play reports the resume only when the song plays")
        XCTAssertTrue(resume.contains("send(.userResumed)\n                stateMachine.apply(.resume)\n                onUserResumed?()"),
                      "Play reports the resume after the gate passed")
        let refused = resume[resume.range(of: "case .refused:")!.lowerBound...]
        XCTAssertFalse(refused.contains("onUserResumed?()"), "a refused or closed resume does not re-plan the day part")
        let deps = try appSource("AppDependencies.swift")
        XCTAssertFalse(deps.contains("hour:"), "the live session reads the hour from its clock, not a launch value")
    }

    /// A Play that takes a Next pressed while paused (#459's advance path) is a resume too: it
    /// re-reads the day part before the skip loads the next song, whose start does not greet.
    func testAPlayThatAdvancesPastTheSkippedSongRecomputesTheDayPart() throws {
        let music = try appSource("MusicKitService.swift")
        let start = try XCTUnwrap(music.range(of: "func resume() async throws {"))
        let resume = music[start.upperBound...]
        let branch = try XCTUnwrap(resume.range(of: "if case .advancePastSkipped = SkippedPastResume.decide("))
        let end = try XCTUnwrap(resume[branch.upperBound...].range(of: "await startSkip(skipCoordinator.requestAdvance())"))
        let advance = resume[branch.upperBound..<end.lowerBound]
        XCTAssertTrue(advance.contains("send(.userResumed)"), "the advance path is the Play the gate allowed")
        XCTAssertTrue(advance.contains("onUserResumed?()"),
                      "the advance path re-reads the day part before the next song starts")
    }

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
