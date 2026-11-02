import XCTest
@testable import AeroDJCore

/// The 12 s ordinary-break cap on MEASURED audio (#320): optional clips are dropped in the
/// planner's order (continuation, then color), the closing line never; a break whose opener plus
/// closing alone run over is skipped. Briefing breaks keep 45 s. -Echo
private struct TimedVoice: VoiceProvider {
    /// Seconds of audio by cue text.
    let seconds: [String: Double]
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let s = seconds.first { text.contains($0.key) }?.value ?? 1
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: s, billableUnits: 0, provider: "avspeech", cacheKey: nil)
    }
}

/// A different extra line at every boundary (as weather would read), so anti-repeat keeps it.
private struct WeatherExtra: DJBreakExtraLineSource {
    func extraLine(after previous: DJTrack, before next: DJTrack, shape: DJBreakShape) -> DJExtraLine? {
        DJExtraLine(text: "Rain later by \(previous.id).", attribution: .presenter)
    }
}

private final class Events: @unchecked Sendable {
    let done: XCTestExpectation
    init(_ done: XCTestExpectation) { self.done = done }
}

final class RenderedOrdinaryCapTests: XCTestCase {
    private func cue(_ text: String, _ order: Int, item: UUID? = nil) -> NarrationCue {
        NarrationCue(id: UUID(), order: order, group: 1, kind: item == nil ? .transition : .note, text: text,
                     estimatedSeconds: 2, maxSeconds: 20, sourceItemID: item, source: item == nil ? nil : .calendar,
                     provenance: item == nil ? nil : "p")
    }

    /// Opener, color, continuation, closing (talk-over), as the planner builds an ordinary break.
    private func ordinaryBreak() -> (DJBreak, opener: UUID, color: UUID, cont: UUID, closing: UUID) {
        let cues = [cue("Opener", 1), cue("Color", 2), cue("Cont", 3), cue("Closing", 4)]
        var b = DJBreak(afterTrack: 0, cues: cues,
                        attributions: Dictionary(uniqueKeysWithValues: cues.map { ($0.id, SpokenAttribution.presenter) }))
        b.talkOverCueID = cues[3].id
        b.optionalCueIDs = [cues[2].id, cues[1].id]
        return (b, cues[0].id, cues[1].id, cues[2].id, cues[3].id)
    }

    private func prepare(_ djBreak: DJBreak, _ seconds: [String: Double], talkOver: Bool = true) async -> DJBreakOutcome {
        let route = VoiceRoute(providerID: "avspeech", provider: TimedVoice(seconds: seconds),
                               voice: VoiceProfile(id: "standard", name: "Host"), timeout: .milliseconds(500), acceptsSSML: false)
        let renderer = VoiceRenderer(routes: [route], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache(), revocations: NarrationRevocations())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: DJCadence(),
                                       talkOverEnabled: { talkOver })
        let events = Events(expectation(description: "finished"))
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

    func testARenderedTotalOf12point5DropsTheContinuationAndKeepsTheClosingLine() async throws {
        let (b, opener, color, cont, closing) = ordinaryBreak()
        let outcome = await prepare(b, ["Opener": 4, "Color": 2, "Cont": 3, "Closing": 3.5])   // 12.5 s
        guard case .ready(let ready) = outcome else { return XCTFail("12.5 s must trim, not skip: \(outcome)") }
        XCTAssertEqual(ready.cues.map(\.id), [opener, color, closing])
        XCTAssertEqual(ready.clips.map(\.cueID), [opener, color, closing])
        XCTAssertEqual(ready.trimmedCueIDs, [cont])
        XCTAssertNil(ready.attributions[cont])
        XCTAssertEqual(ready.measuredSeconds, 9.5, accuracy: 0.001)
        XCTAssertLessThanOrEqual(ready.measuredSeconds, 12)
        // Talk-over hooks recompute from the kept clips: one line at a time, never overlapping.
        XCTAssertEqual(ready.talkOverCueID, closing)
        XCTAssertEqual(try XCTUnwrap(ready.talkOverStartSeconds), 6.3, accuracy: 0.001)
        let plan = DJSessionPlan(breaks: [b], briefingReport: NarrationScheduleReport(entries: []))
        XCTAssertEqual(plan.capReport(afterBreaks: [0: outcome]).trimmedOptionalLines, [0: 1])
        XCTAssertEqual(plan.capReport(afterBreaks: [0: outcome]).skippedOverCap, [])
    }

    func testColorIsDroppedOnlyAfterTheContinuation() async {
        let (b, opener, color, cont, closing) = ordinaryBreak()
        let outcome = await prepare(b, ["Opener": 7, "Color": 3, "Cont": 1, "Closing": 3])   // 14 s, then 13 s
        guard case .ready(let ready) = outcome else { return XCTFail("opener + closing fit: \(outcome)") }
        XCTAssertEqual(ready.cues.map(\.id), [opener, closing])
        XCTAssertEqual(ready.trimmedCueIDs, [cont, color])
        XCTAssertEqual(ready.measuredSeconds, 10, accuracy: 0.001)
    }

    func testOpenerPlusClosingOver12SkipsTheBreakAndIsReported() async {
        let (b, _, _, _, _) = ordinaryBreak()
        let outcome = await prepare(b, ["Opener": 9, "Color": 1, "Cont": 1, "Closing": 3.5])   // required 12.5 s
        XCTAssertEqual(outcome, .skipped(.overBreakBudget), "the boundary stays music-only; never cut mid-line")
        let plan = DJSessionPlan(breaks: [b], briefingReport: NarrationScheduleReport(entries: []))
        XCTAssertEqual(plan.capReport(afterBreaks: [0: outcome]).skippedOverCap, [0])
        XCTAssertEqual(plan.capReport(afterBreaks: [0: outcome]).trimmedOptionalLines, [:])
    }

    func testABreakWithin12IsUntouched() async {
        let (b, _, _, _, _) = ordinaryBreak()
        let outcome = await prepare(b, ["Opener": 4, "Color": 2, "Cont": 2, "Closing": 3.7])   // 11.7 s + 0.3 s gap = 12 s
        guard case .ready(let ready) = outcome else { return XCTFail("12 s fits: \(outcome)") }
        XCTAssertEqual(ready.cues.map(\.id), b.cues.map(\.id))
        XCTAssertEqual(ready.trimmedCueIDs, [])
    }

    /// The 0.3 s pause before the closing line counts toward 12 s (Fry, Orion on #320): 12.0 s of
    /// clips plays as 12.3 s, so it trims, with talk-over on or off.
    func testThePauseBeforeTheClosingLineCountsTowardTheCap() async {
        for talkOver in [true, false] {
            let (b, opener, color, cont, closing) = ordinaryBreak()
            let outcome = await prepare(b, ["Opener": 4, "Color": 2, "Cont": 2, "Closing": 4], talkOver: talkOver)
            guard case .ready(let ready) = outcome else { return XCTFail("trims, not skips: \(outcome)") }
            XCTAssertEqual(ready.cues.map(\.id), [opener, color, closing], "talkOver=\(talkOver)")
            XCTAssertEqual(ready.trimmedCueIDs, [cont], "talkOver=\(talkOver)")
            XCTAssertLessThanOrEqual(ready.measuredSeconds + PreparedDJBreak.talkOverGapSeconds, 12)
        }
    }

    func testOpenerPlusClosingThatFitOnlyWithoutThePauseIsSkipped() async {
        let (b, _, _, _, _) = ordinaryBreak()
        let outcome = await prepare(b, ["Opener": 8, "Color": 1, "Cont": 1, "Closing": 3.9], talkOver: false)   // 11.9 + 0.3
        XCTAssertEqual(outcome, .skipped(.overBreakBudget))
    }

    func testBriefingBreaksKeepTheir45SecondLimit() async {
        let cues = [cue("Opener", 1), cue("Item", 2, item: UUID()), cue("Closing", 3)]
        let b = DJBreak(afterTrack: 0, cues: cues, attributions: [:])
        let outcome = await prepare(b, ["Opener": 4, "Item": 20, "Closing": 4])   // 28 s
        guard case .ready(let ready) = outcome else { return XCTFail("a 28 s briefing fits 45 s: \(outcome)") }
        XCTAssertEqual(ready.cues.count, 3)
        XCTAssertEqual(ready.trimmedCueIDs, [])
    }

    func testThePlannerListsOnlyOptionalLinesInDropOrder() {
        var w = DJScriptWriter(cadence: DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 7)
        let tracks = (0..<40).map { DJTrack(id: "t\($0)", title: "T\($0)", artist: "A\($0)", origin: .catalog) }
        let plan = w.plan(tracks: tracks, briefing: nil, hour: 15)
        XCTAssertFalse(plan.breaks.isEmpty)
        XCTAssertTrue(plan.breaks.contains { !$0.optionalCueIDs.isEmpty })
        for b in plan.breaks {
            let index = Dictionary(uniqueKeysWithValues: b.cues.enumerated().map { ($1.id, $0) })
            let positions = b.optionalCueIDs.compactMap { index[$0] }
            XCTAssertEqual(positions.count, b.optionalCueIDs.count, "every optional id is a cue of the break")
            XCTAssertFalse(positions.contains(0), "never the opener")
            XCTAssertFalse(positions.contains(b.cues.count - 1), "never the closing line")
            XCTAssertEqual(positions, positions.sorted(by: >), "continuation (later) drops first")
        }
    }

    // MARK: Classic planner and rendered cap agree (#339 follow-up, -Fry)

    /// Opener `openerWords` words, closing 10 words (4 s, talk-over), continuation "Okay." (1 s).
    private func capTone(openerWords: Int) -> EditorialTone {
        let opener = "{title} " + Array(repeating: "la", count: openerWords - 1).joined(separator: " ") + "."
        return EditorialTone(backAnnounce: [opener], closing: ["{nextTitle} " + Array(repeating: "la", count: 9).joined(separator: " ") + "."],
                             artistFocus: [opener], stationID: [], atmosphere: [:], continuation: ["Okay."],
                             briefingLead: ["Quick one."], briefingOutro: ["Back to it."], greetings: [:])
    }

    /// A classic break the planner admits at the cap renders with nothing trimmed and is never
    /// skipped when the audio runs exactly as estimated. Before the fix, 8 s + 4 s planned as
    /// "12 s" and rendered as 12.3 s, so it was skipped after rendering.
    func testAClassicBreakPlannedAtTheCapIsNeverSkippedAtRenderWhenAudioMatchesTheEstimate() async {
        let tracks = (0..<12).map { DJTrack(id: "t\($0)", title: "T\($0)", artist: "A\($0)", origin: .catalog) }
        var rendered = 0
        for words in [17, 18, 20] {   // 7 s, 8 s, 8 s openers with a 4 s closing line
            var w = DJScriptWriter(cadence: DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 3, tone: capTone(openerWords: words))
            for b in w.plan(tracks: tracks, briefing: nil, hour: 15).breaks.prefix(2) {
                XCTAssertNotNil(b.talkOverCueID)
                let seconds = Dictionary(b.cues.map { ($0.text, $0.plannedSeconds) }, uniquingKeysWith: { a, _ in a })
                let outcome = await prepare(b, seconds)
                guard case .ready(let ready) = outcome else { return XCTFail("planned \(b.estimatedSeconds) s skipped at render: \(outcome)") }
                XCTAssertEqual(ready.trimmedCueIDs, [], "nothing to trim when the audio matches the plan")
                XCTAssertLessThanOrEqual(ready.measuredSeconds + PreparedDJBreak.talkOverGapSeconds, 12)
                rendered += 1
            }
        }
        XCTAssertGreaterThan(rendered, 0, "the 7 s opener breaks plan and render")
    }

    // MARK: Natural shapes (#344) in the #339 forward merge

    private func naturalPlan(seed: UInt64) -> [DJBreak] {
        var w = DJScriptWriter(cadence: DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed,
                               shapes: DJBreakShapeConfig(weights: [.classic: 1]))
        w.extraLineSource = WeatherExtra()
        let tracks = (0..<40).map { DJTrack(id: "t\($0)", title: "T\($0)", artist: "A\($0)", origin: .catalog) }
        return w.plan(tracks: tracks, briefing: nil, hour: 15).breaks.filter { $0.shape != nil }
    }

    /// Natural breaks list their optional lines last-placed first, so the extra (weather) line,
    /// which sits just before the closing line, is the first one rendered trimming drops.
    func testNaturalBreaksListTheExtraLineFirstAndNeverARequiredLine() {
        var withExtra = 0
        for seed in UInt64(0)..<40 {
            for b in naturalPlan(seed: seed) {
                let index = Dictionary(uniqueKeysWithValues: b.cues.enumerated().map { ($1.id, $0) })
                let positions = b.optionalCueIDs.compactMap { index[$0] }
                XCTAssertEqual(positions.count, b.optionalCueIDs.count, "every optional id is a cue of the break")
                XCTAssertEqual(positions, positions.sorted(by: >), "last-placed optional line drops first")
                if let closing = b.talkOverCueID { XCTAssertFalse(b.optionalCueIDs.contains(closing), "never the closing line") }
                XCTAssertFalse(b.optionalCueIDs.contains(b.cues[0].id), "never the classic opener")
                let optionalTexts = b.cues.filter { b.optionalCueIDs.contains($0.id) }.map(\.text)
                for text in optionalTexts {
                    XCTAssertTrue(text.hasPrefix("Rain later") || EditorialTone.warm.continuation.contains(text)
                                  || EditorialTone.warm.atmosphere.values.contains { $0.contains(text) }, "optional: \(text)")
                }
                if let extra = b.cues.first(where: { $0.text.hasPrefix("Rain later") }) {
                    withExtra += 1
                    XCTAssertEqual(b.optionalCueIDs.first, extra.id, "the extra line drops first")
                }
            }
        }
        XCTAssertGreaterThan(withExtra, 0, "some natural breaks carry the extra line")
    }

    /// End to end: a planned natural break over 12 s of measured audio loses the extra line, and
    /// only it, while the other optional line, the opener and the closing line all stay.
    func testRenderedTrimmingDropsTheNaturalBreaksExtraLineFirst() async throws {
        var planned: DJBreak?
        search: for seed in UInt64(0)..<40 {
            for b in naturalPlan(seed: seed) where b.cues.count == 4 && b.optionalCueIDs.count == 2 {
                if b.talkOverCueID == b.cues[3].id, b.cues[2].text.hasPrefix("Rain later") { planned = b; break search }
            }
        }
        let b = try XCTUnwrap(planned, "a classic natural break with one optional line plus the extra")
        let (opener, other, extra, closing) = (b.cues[0], b.cues[1], b.cues[2], b.cues[3])
        // 3 + 2 + 4 + 3 + 0.3 s pause = 12.3 s, over 12; without the extra 8.3 s.
        let outcome = await prepare(b, [opener.text: 3, other.text: 2, extra.text: 4, closing.text: 3])
        guard case .ready(let ready) = outcome else { return XCTFail("must trim, not skip: \(outcome)") }
        XCTAssertEqual(ready.trimmedCueIDs, [extra.id])
        XCTAssertEqual(ready.cues.map(\.id), [opener.id, other.id, closing.id])
        XCTAssertEqual(ready.talkOverCueID, closing.id)
        XCTAssertEqual(ready.measuredSeconds, 8, accuracy: 0.001)
    }
}
