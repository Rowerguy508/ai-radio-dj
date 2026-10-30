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

    private func prepare(_ djBreak: DJBreak, _ seconds: [String: Double]) async -> DJBreakOutcome {
        let route = VoiceRoute(providerID: "avspeech", provider: TimedVoice(seconds: seconds),
                               voice: VoiceProfile(id: "standard", name: "Host"), timeout: .milliseconds(500), acceptsSSML: false)
        let renderer = VoiceRenderer(routes: [route], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache(), revocations: NarrationRevocations())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: DJCadence(),
                                       talkOverEnabled: { true })
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
        let outcome = await prepare(b, ["Opener": 4, "Color": 2, "Cont": 2, "Closing": 4])   // exactly 12 s
        guard case .ready(let ready) = outcome else { return XCTFail("12 s fits: \(outcome)") }
        XCTAssertEqual(ready.cues.map(\.id), b.cues.map(\.id))
        XCTAssertEqual(ready.trimmedCueIDs, [])
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
}
