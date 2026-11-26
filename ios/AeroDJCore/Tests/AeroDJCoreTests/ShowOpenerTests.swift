import Foundation
import XCTest
@testable import AeroDJCore

/// The show opener (build 34): the first break of a session sets the stage. Greeting and the
/// real station name, a mood line, the time from the time-check machinery when it can be said
/// truthfully, then the first song. 22 s cap; ordinary 12 s and briefing 45 s unchanged. -Echo
private struct OpenerVoice: VoiceProvider {
    /// Seconds of audio by a substring of the cue text.
    let seconds: [String: Double]
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let s = seconds.first { text.contains($0.key) }?.value ?? 1
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: s, billableUnits: 0, provider: "avspeech", cacheKey: nil)
    }
}

private final class OpenerEvents: @unchecked Sendable {
    let done: XCTestExpectation
    init(_ done: XCTestExpectation) { self.done = done }
}

final class ShowOpenerTests: XCTestCase {
    private let dense = DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1)
    static let tones: [(name: String, tone: EditorialTone)] =
        DJPersonality.allCases.map { ($0.rawValue, EditorialTone.forPersonality($0)) }

    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        eastern.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: hour, minute: minute))!
    }

    private func clock(_ hour: Int, _ minute: Int, airTimes: [Int: Date] = [:]) -> DJPlanClock {
        DJPlanClock(now: date(hour, minute), calendar: eastern, style: .twelveHour, airTimes: airTimes)
    }

    private func writer(_ tone: EditorialTone = .warm, seed: UInt64 = 1, cadence: DJCadence? = nil,
                        config: DJBreakShapeConfig = .natural, station: String = "OnAirly") -> DJScriptWriter {
        DJScriptWriter(cadence: cadence ?? dense, seed: seed, stationName: station, tone: tone, shapes: config)
    }

    private func greetingCount(_ djBreak: DJBreak, _ tone: EditorialTone, _ hour: Int) -> Bool {
        let first = djBreak.cues.first?.text ?? ""
        return tone.greetings[DayPart(hour: hour), default: []].contains { first.hasPrefix($0) }
    }

    // MARK: Planning

    func testTheFirstBreakOpensTheShowForEveryTone() {
        let tracks = djTracks(30)
        for (name, tone) in Self.tones {
            var timeChecks = 0, setups = 0
            for seed in UInt64(1)...30 {
                for hour in [5, 9, 14, 19, 23] {
                    var w = writer(tone, seed: seed)
                    let plan = w.plan(tracks: tracks, briefing: nil, hour: hour, clock: clock(hour, 41))
                    let context = "\(name) seed \(seed) hour \(hour)"
                    guard let opener = plan.breaks.first else { return XCTFail(context) }
                    XCTAssertEqual(opener.shape, .showOpener, context)
                    XCTAssertTrue(greetingCount(opener, tone, hour), "starts with the day-part greeting: \(context)")
                    XCTAssertTrue(opener.cues[0].text.contains("OnAirly"), "names the real station: \(context)")
                    XCTAssertLessThanOrEqual(opener.cues.count, DJBreakShapeConfig.natural.maxCuesPerBreak, context)
                    XCTAssertEqual(opener.cues.last?.id, opener.talkOverCueID, "ends on the talk-over intro: \(context)")
                    XCTAssertTrue(opener.cues.last!.text.contains("Song \(opener.afterTrack + 1)")
                                  || opener.cues.last!.text.contains("Artist \(opener.afterTrack + 1)"), context)
                    XCTAssertLessThanOrEqual(DJScriptWriter.wholeSeconds(opener), 22, context)
                    XCTAssertLessThanOrEqual(opener.mainSeconds, 22, context)
                    if opener.timeCheck != nil { timeChecks += 1 }
                    if opener.cues.count >= 3 { setups += 1 }
                    // Only one opener, and every later ordinary break keeps the 12 s cap.
                    for later in plan.breaks.dropFirst() {
                        XCTAssertNotEqual(later.shape, .showOpener, context)
                        XCTAssertLessThanOrEqual(DJScriptWriter.wholeSeconds(later), 12, context)
                        XCTAssertLessThanOrEqual(later.mainSeconds, 15, context)
                    }
                }
            }
            XCTAssertEqual(timeChecks, 150, "\(name): a clock and no other time check: the opener gives the time")
            XCTAssertGreaterThan(setups, 100, "\(name): the mood line airs")
        }
    }

    func testTheOpenerTimeIsTheTimeCheckMachinerys() {
        var w = writer()
        let plan = w.plan(tracks: djTracks(12), briefing: nil, hour: 19, clock: clock(19, 41))
        let opener = plan.breaks[0]
        guard let timeCheck = opener.timeCheck, let line = opener.cues.first(where: { $0.id == timeCheck.cueID }) else {
            return XCTFail("no planned time check")
        }
        XCTAssertTrue(line.text.contains("7:40"), line.text)
        XCTAssertEqual(timeCheck.plannedAt, date(19, 41))
        XCTAssertEqual(opener.timeCheckCueID, timeCheck.cueID)
        XCTAssertEqual(opener.optionalCueIDs.first, timeCheck.cueID, "the time check drops first at render, then the mood")
        XCTAssertFalse(opener.optionalCueIDs.contains(opener.cues[0].id), "never the welcome")
        XCTAssertFalse(opener.optionalCueIDs.contains(opener.cues.last!.id), "never the closing line")
        XCTAssertEqual(plan.ordinaryCapReport.omittedOpenerTimeChecks, [:])
        XCTAssertEqual(w.testTimeCheckCount, 1, "counts toward the 30-minute spacing")
        // The render-time line is re-read from the clock and kept truthful (#347).
        XCTAssertEqual(timeCheck.text(at: date(19, 47)).map { $0.contains("7:45") }, true)
    }

    func testWithoutATruthfulTimeTheOpenerOmitsItAndSaysWhy() {
        let tracks = djTracks(12)
        func omission(_ plan: DJSessionPlan) -> DJOpenerTimeCheckOmission? {
            XCTAssertEqual(plan.breaks.first?.shape, .showOpener)
            XCTAssertNil(plan.breaks.first?.timeCheck)
            // No spoken time: no digits outside the closing line (which names "Song 1").
            for cue in plan.breaks.first?.cues.dropLast() ?? [] { XCTAssertNil(cue.text.rangeOfCharacter(from: .decimalDigits), cue.text) }
            return plan.ordinaryCapReport.omittedOpenerTimeChecks[plan.breaks.first?.afterTrack ?? -1]
        }
        var noClock = writer()
        XCTAssertEqual(omission(noClock.plan(tracks: tracks, briefing: nil, hour: 9)), .noClock)

        var drift = writer()
        let far = Dictionary(uniqueKeysWithValues: (0..<12).map { ($0, date(9, 30)) })
        XCTAssertEqual(omission(drift.plan(tracks: tracks, briefing: nil, hour: 9, clock: clock(9, 10, airTimes: far))), .airTimeDrift)

        var spaced = writer()
        _ = spaced.plan(tracks: tracks, briefing: nil, hour: 9, clock: clock(9, 10))
        spaced.greetAgain()
        XCTAssertEqual(omission(spaced.plan(tracks: tracks, briefing: nil, hour: 9, clock: clock(9, 25))), .spacing)

        var config = DJBreakShapeConfig.natural
        config.timeChecks = DJTimeCheckPhrases(on: [], comingUp: [], justAfter: [])
        var unphrased = writer(config: config)
        XCTAssertEqual(omission(unphrased.plan(tracks: tracks, briefing: nil, hour: 9, clock: clock(9, 10))), .noPhrasing)
    }

    func testOverTheOpenerCapTheMoodThenTheTimeDropAndAreReported() {
        var sawOverCap = false, sawTrim = false
        for seed in UInt64(1)...40 {
            var cadence = dense
            cadence.maxOpenerBreakSeconds = 9
            var w = writer(seed: seed, cadence: cadence)
            let plan = w.plan(tracks: djTracks(12), briefing: nil, hour: 9, clock: clock(9, 10))
            let first = plan.breaks[0], k = first.afterTrack
            if first.shape == .showOpener {
                XCTAssertLessThanOrEqual(DJScriptWriter.wholeSeconds(first), 9, "seed \(seed)")
                if first.timeCheck == nil {
                    XCTAssertEqual(plan.ordinaryCapReport.omittedOpenerTimeChecks[k], .overCap, "seed \(seed)")
                    sawOverCap = true
                }
                if plan.ordinaryCapReport.trimmedOptionalLines[k] != nil { sawTrim = true }
            } else {
                // Required lines alone over the cap: the short greeting takes the boundary.
                XCTAssertNil(first.shape)
                XCTAssertLessThanOrEqual(DJScriptWriter.wholeSeconds(first), 12)
                XCTAssertNil(plan.ordinaryCapReport.omittedOpenerTimeChecks[k])
            }
        }
        XCTAssertTrue(sawOverCap, "a time check dropped to fit is reported, never silent")
        XCTAssertTrue(sawTrim, "the mood line is dropped (and counted) before the time")
    }

    func testTheMoodLineGoesBeforeTheTimeCheck() {
        // Drop order: the mood line first, the time only if the break still runs over.
        var sawTimeKeptAfterTrim = false
        for cap in 9...16 {
            for seed in UInt64(1)...30 {
                var cadence = dense
                cadence.maxOpenerBreakSeconds = cap
                var w = writer(seed: seed, cadence: cadence)
                let plan = w.plan(tracks: djTracks(12), briefing: nil, hour: 9, clock: clock(9, 10))
                let first = plan.breaks[0], k = first.afterTrack
                guard first.shape == .showOpener else { continue }
                let trimmed = plan.ordinaryCapReport.trimmedOptionalLines[k] != nil
                if plan.ordinaryCapReport.omittedOpenerTimeChecks[k] == .overCap {
                    XCTAssertTrue(trimmed, "cap \(cap) seed \(seed): time dropped while the mood line stayed")
                }
                if trimmed, first.timeCheck != nil { sawTimeKeptAfterTrim = true }
            }
        }
        XCTAssertTrue(sawTimeKeptAfterTrim, "dropping the mood line alone fits some openers, so the time stays")
    }

    func testTheCapsStaySeparate() {
        let cadence = DJCadence()
        XCTAssertEqual(cadence.maxOrdinaryBreakSeconds, 12)
        XCTAssertEqual(cadence.maxBriefingBreakSeconds, 45)
        XCTAssertEqual(cadence.maxOpenerBreakSeconds, 22)
        XCTAssertLessThan(cadence.maxOpenerBreakSeconds, cadence.maxBriefingBreakSeconds)
        XCTAssertEqual(DJCadence(maxBriefingBreakSeconds: 20, maxOpenerBreakSeconds: 30).maxOpenerBreakSeconds, 20,
                       "never above the briefing cap")
        for personality in DJPersonality.allCases {
            let config = StationConfiguration(personality: personality)
            XCTAssertEqual(config.cadence(base: DJCadence(maxOpenerBreakSeconds: 21)).maxOpenerBreakSeconds, 21)
        }
        #if DEBUG
        XCTAssertEqual(TestStation.cadence.maxOpenerBreakSeconds, 22)
        #endif
    }

    func testABriefingFirstBreakKeepsTheShortGreeting() {
        let note = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "You've got Grocery list. From your notes.",
                                estimatedSeconds: 4, maxSeconds: 12, sourceItemID: UUID(), source: .obsidian, provenance: "n:1")
        var w = writer()
        let plan = w.plan(tracks: djTracks(12), briefing: NarrationHandoff(cues: [note], maxSpokenSeconds: 150, experienceSeconds: 300),
                          hour: 9, clock: clock(9, 10))
        XCTAssertTrue(plan.breaks[0].hasBriefing)
        XCTAssertNil(plan.breaks[0].shape)
        XCTAssertFalse(plan.breaks.contains { $0.shape == .showOpener }, "the session already greeted")
    }

    func testTheOpenerIsOptInAndTheClassicWriterIsUnchanged() {
        var off = DJBreakShapeConfig.natural
        off.showOpener = false
        var a = writer(config: off)
        XCTAssertNil(a.plan(tracks: djTracks(12), briefing: nil, hour: 9, clock: clock(9, 10)).breaks[0].shape)
        var classic = DJScriptWriter(cadence: dense, seed: 1)
        let plan = classic.plan(tracks: djTracks(12), briefing: nil, hour: 9, clock: clock(9, 10))
        XCTAssertFalse(plan.breaks.contains { $0.shape != nil })
    }

    func testAPlannedAwayOpenerOpensTheShowAgain() {
        var w = writer()
        let plan = w.plan(tracks: djTracks(12), briefing: nil, hour: 9, clock: clock(9, 10))
        XCTAssertTrue(w.testHasGreeted)
        w.forgetPlannedBreaks(Array(plan.breaks.dropFirst()))
        XCTAssertTrue(w.testHasGreeted, "forgetting later breaks keeps the greeting")
        w.forgetPlannedBreaks([plan.breaks[0]])
        XCTAssertFalse(w.testHasGreeted, "the opener never aired")
        XCTAssertEqual(w.testTimeCheckCount, 0, "its time check left the spacing log")
        let again = w.plan(tracks: djTracks(12), briefing: nil, hour: 9, clock: clock(9, 10))
        XCTAssertEqual(again.breaks[0].shape, .showOpener)
        XCTAssertNotNil(again.breaks[0].timeCheck)
    }

    /// For Fry's `queueStarted` station change: `greetAgain()` opens the new station, in new words.
    func testGreetAgainOpensTheShowWithoutRepeatingTheLastOpener() {
        for seed in UInt64(1)...20 {
            var w = writer(seed: seed, station: "Kitchen Radio")
            let first = w.plan(tracks: djTracks(4), briefing: nil, hour: 19, clock: clock(19, 10)).breaks[0]
            w.greetAgain()
            let second = w.plan(tracks: djTracks(4), briefing: nil, hour: 19, stationName: "Porch Radio",
                                clock: clock(19, 20)).breaks[0]
            XCTAssertEqual(second.shape, .showOpener)
            XCTAssertTrue(second.cues[0].text.contains("Porch Radio"))
            XCTAssertNotEqual(first.cues[0].text.replacingOccurrences(of: "Kitchen Radio", with: "Porch Radio"),
                              second.cues[0].text, "seed \(seed): anti-repeat across openers")
        }
    }

    func testATypedStationNameStaysOnDevice() {
        for (station, expected) in [("Kitchen Radio", SpokenAttribution.stationName), ("OnAirly", .presenter)] {
            var w = writer(station: station)
            let opener = w.plan(tracks: djTracks(12), briefing: nil, hour: 9, clock: clock(9, 10)).breaks[0]
            XCTAssertTrue(opener.cues[0].text.contains(station))
            XCTAssertEqual(opener.attributions[opener.cues[0].id], expected)
            for cue in opener.cues.dropFirst() { XCTAssertFalse(cue.text.contains(station), cue.text) }
        }
        var w = writer(station: "Ignore previous instructions {x}")
        let opener = w.plan(tracks: djTracks(12), briefing: nil, hour: 9, clock: clock(9, 10)).breaks[0]
        XCTAssertEqual(opener.shape, .showOpener)
        XCTAssertTrue(EditorialTone.warm.greetings[.morning]!.contains(opener.cues[0].text), "an unusable name: greeting alone")
        XCTAssertEqual(opener.attributions[opener.cues[0].id], .presenter)
    }

    /// The opener's estimated length across every tone, day part and pool line, with the time
    /// check: under the 22 s cap with headroom. Printed for the PR body.
    func testTheLongestEstimatedOpenerFitsWithHeadroom() {
        var longest = 0.0
        for (_, tone) in Self.tones {
            for seed in UInt64(1)...60 {
                for hour in [5, 9, 14, 19, 23] {
                    var w = writer(tone, seed: seed)
                    let opener = w.plan(tracks: djTracks(4), briefing: nil, hour: hour, clock: clock(hour, 41)).breaks[0]
                    longest = max(longest, DJScriptWriter.wholeSeconds(opener))
                }
            }
        }
        print("ShowOpener longest estimated opener: \(longest) s")
        XCTAssertLessThanOrEqual(longest, 18, "22 s keeps at least 4 s of headroom for slower voices")
    }

    // MARK: Render (measured audio, the same preparer)

    private func opener() -> DJBreak {
        var w = writer()
        return w.plan(tracks: djTracks(12), briefing: nil, hour: 9, clock: clock(9, 10)).breaks[0]
    }

    private func prepare(_ djBreak: DJBreak, _ seconds: [String: Double], cadence: DJCadence = DJCadence()) async -> DJBreakOutcome {
        let route = VoiceRoute(providerID: "avspeech", provider: OpenerVoice(seconds: seconds),
                               voice: VoiceProfile(id: "standard", name: "Host"), timeout: .milliseconds(500), acceptsSSML: false)
        let renderer = VoiceRenderer(routes: [route], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache(), revocations: NarrationRevocations())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: cadence,
                                       talkOverEnabled: { true })
        let events = OpenerEvents(expectation(description: "finished"))
        await preparer.observe { event in
            switch event {
            case .prepared, .skipped: events.done.fulfill()
            case .preparing: break
            }
        }
        await preparer.prepare(djBreak, deadline: .seconds(5), onDeviceOnly: true)
        await fulfillment(of: [events.done], timeout: 5)
        return await preparer.takeBreak(afterTrack: djBreak.afterTrack)
    }

    func testAMeasured18SecondOpenerAirsWhole() async {
        var b = opener()
        b.timeCheck = nil   // the late time-check render is #347's, tested there
        let seconds = Dictionary(uniqueKeysWithValues: b.cues.enumerated().map { ($1.text, [8.0, 6.0, 1.0, 2.5][$0]) })
        guard case .ready(let ready) = await prepare(b, seconds) else { return XCTFail("an opener under 22 s airs") }
        XCTAssertEqual(ready.cues.count, b.cues.count)
        XCTAssertEqual(ready.trimmedCueIDs, [])
    }

    func testAMeasuredOpenerOver22DropsAnOptionalLineNeverTheWelcomeOrIntro() async {
        var b = opener()
        b.timeCheck = nil
        guard b.cues.count == 4 else { return XCTFail("expected welcome, mood, time, intro") }
        let mood = b.cues[1], time = b.cues[2]
        // Each line within its own render limit (`maxSeconds`), 22.3 s together.
        let seconds = [b.cues[0].text: 7.5, mood.text: 7.5, time.text: 4.0, b.cues[3].text: 3.0]
        guard case .ready(let ready) = await prepare(b, seconds) else { return XCTFail("trimmed, not skipped") }
        XCTAssertEqual(ready.trimmedCueIDs, [time.id], "the planner's drop order: the time line first")
        XCTAssertTrue(ready.cues.contains { $0.id == mood.id })
        XCTAssertEqual(ready.cues.first?.id, b.cues[0].id)
        XCTAssertEqual(ready.cues.last?.id, b.cues[3].id)
    }

    /// A line never renders past its own limit, so a lower opener cap shows the skip: the
    /// welcome and intro alone over the cap leave the boundary music-only, never cut mid-line.
    func testAMeasuredOpenerWhoseRequiredLinesRunOverTheCapIsSkipped() async {
        var b = opener()
        b.timeCheck = nil
        let seconds = [b.cues[0].text: 7.5, b.cues.last!.text: 3.0]   // + 0.3 s pause: 10.8 s
        let outcome = await prepare(b, seconds, cadence: DJCadence(maxOpenerBreakSeconds: 10))
        guard case .skipped(.overBreakBudget) = outcome else { return XCTFail("over the cap: music only, got \(outcome)") }
    }

    func testAnOrdinaryBreakStillCapsAt12() async {
        var b = opener()
        b.timeCheck = nil
        b.shape = .classic
        let seconds = Dictionary(uniqueKeysWithValues: b.cues.enumerated().map { ($1.text, [8.0, 6.0, 1.0, 2.5][$0]) })
        guard case .ready(let ready) = await prepare(b, seconds) else { return XCTFail("trimmed to fit 12 s") }
        XCTAssertFalse(ready.trimmedCueIDs.isEmpty, "the same 17.8 s at the ordinary cap trims")
    }

    // MARK: Copy (casual house style)

    /// Announcer boilerplate and uncontracted forms a friend would not say (build 34 owner note).
    static let formalPhrases = [
        "welcome to", "ladies and gentlemen", "you are listening to", "thank you for tuning in", "thanks for tuning in",
        "thank you for listening", "we are", "you are", "it is", "that is", "let us", "do not", "we will", "you have",
        "i am", "here is", "please enjoy", "stay tuned", "coming to you",
    ]

    static func formal(_ line: String) -> [String] {
        let lower = line.lowercased()
        return formalPhrases.filter { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    func testTheCasualLintCatchesAnnouncerPhrasing() {
        for line in ["Welcome to OnAirly.", "Ladies and gentlemen, OnAirly.", "You are listening to OnAirly.",
                     "Thank you for tuning in.", "We are glad you're here.", "It is a quiet night."] {
            XCTAssertFalse(Self.formal(line).isEmpty, line)
        }
        for line in ["Hey, good evening. You're on OnAirly.", "Hey hey, it's OnAirly. Kick back, we've got a good one going.",
                     "Evening. It's just after 7:40."] {
            XCTAssertEqual(Self.formal(line), [], line)
        }
    }

    func testOpenerCopyIsCasualCleanAndFactFree() {
        let warm = Set(EditorialTone.warm.opener.allLines)
        for (name, tone) in Self.tones {
            let opener = tone.opener
            XCTAssertGreaterThanOrEqual(opener.station.count, 4, name)
            XCTAssertEqual(Set(opener.station).count, opener.station.count, "\(name): duplicate station line")
            for line in opener.station {
                XCTAssertEqual(line.components(separatedBy: "{").count - 1, 1, "\(name): one slot: \(line)")
                XCTAssertTrue(line.contains("{station}"), "\(name): \(line)")
            }
            for part in DayPart.allCases {
                let lines = opener.setup[part, default: []]
                XCTAssertGreaterThanOrEqual(lines.count, 3, "\(name) setup \(part)")
                XCTAssertEqual(Set(lines).count, lines.count, "\(name) setup \(part): duplicate")
                for line in lines {
                    XCTAssertFalse(line.contains("{"), "\(name): mood lines have no slots: \(line)")
                    let lower = line.lowercased()
                    for claim in ["halfway", "o'clock", "middle of", "almost", "nearly", "midday", "noon", "midnight",
                                  "rain", "sunny", "weather"] {
                        XCTAssertNil(lower.range(of: "\\b\(claim)\\b", options: .regularExpression), "\(name), \(claim): \(line)")
                    }
                }
            }
            for line in opener.allLines {
                let filled = TemplatePool.fill(line, ["station": "OnAirly"]) ?? line
                XCTAssertEqual(SpokenScriptLintTests.problems(filled), [], "\(name): \(line)")
                XCTAssertEqual(Self.formal(line), [], "\(name): \(line)")
                XCTAssertFalse(line.contains(where: \.isNumber), "\(name): \(line)")
                for sentence in line.split(whereSeparator: { ".?!".contains($0) }) {
                    XCTAssertLessThanOrEqual(sentence.split(separator: " ").count, 12, "\(name): \(line)")
                }
                if tone != .warm { XCTAssertFalse(warm.contains(line), "\(name) copies warm: \(line)") }
                if tone == .minimal {
                    XCTAssertLessThanOrEqual(line.split(separator: " ").count, 5, "minimal stays brief: \(line)")
                }
            }
            let contractions = opener.allLines.filter { $0.contains("'") }.count
            let share = Double(contractions) / Double(opener.allLines.count)
            XCTAssertGreaterThanOrEqual(share, tone == .minimal ? 0.25 : 0.5, "\(name): contractions (\(share))")
        }
    }

    /// Whole planned openers, with the greeting, the station and the spoken time.
    func testPlannedOpenersSpeakOnlyCasualCleanLines() {
        for (name, tone) in Self.tones {
            for seed in UInt64(1)...30 {
                for hour in [5, 9, 14, 19, 23] {
                    var w = writer(tone, seed: seed)
                    let opener = w.plan(tracks: djTracks(4), briefing: nil, hour: hour, clock: clock(hour, 41)).breaks[0]
                    for cue in opener.cues {
                        XCTAssertEqual(SpokenScriptLintTests.problems(cue.text), [], "\(name): \(cue.text)")
                        XCTAssertEqual(Self.formal(cue.text), [], "\(name): \(cue.text)")
                    }
                }
            }
        }
    }
}

extension DJBreak {
    /// A shape the picker chose (natural ordinary break). The show opener has a shape too, but
    /// the writer plans it, so tests of the picker's breaks leave it out.
    var isPickedShape: Bool { shape != nil && shape != .showOpener }
}
