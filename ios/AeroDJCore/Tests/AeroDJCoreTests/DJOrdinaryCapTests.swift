import XCTest
@testable import AeroDJCore

/// The 12 s ordinary-break cap: the whole break, closing line included, at the word-rate estimate
/// (150 wpm, rounded up per line). Briefing breaks keep their own cap. -Echo
final class DJOrdinaryCapTests: XCTestCase {
    private func filler(_ n: Int) -> String { Array(repeating: "la", count: n).joined(separator: " ") }

    /// Opener `openerWords` words, closing 10 words (4 s), continuation "Okay." (1 s). No color pools.
    private func tone(openerWords: Int) -> EditorialTone {
        let opener = "{title} " + filler(openerWords - 1) + "."
        return EditorialTone(backAnnounce: [opener], closing: ["{nextTitle} " + filler(9) + "."], artistFocus: [opener],
                             stationID: [], atmosphere: [:], continuation: ["Okay."], briefingLead: ["Quick one."],
                             briefingOutro: ["Back to it."], greetings: [:])
    }

    private let tracks = (0..<24).map { DJTrack(id: "t\($0)", title: "T\($0)", artist: "A\($0)", origin: .catalog) }

    private func cadence(cap: Int = 12, closing: Int = 4) -> DJCadence {
        DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1, maxClosingSeconds: closing, maxOrdinaryBreakSeconds: cap)
    }

    func testABreakExactlyAtTheCapKeepsItsClosingLineAndDropsTheOptionalLine() {
        var trimmedTotal = 0
        for seed: UInt64 in 0..<40 {
            var w = DJScriptWriter(cadence: cadence(), seed: seed, tone: tone(openerWords: 20))   // 8 s + 4 s = 12 s
            let plan = w.plan(tracks: tracks, briefing: nil, hour: 15)
            XCTAssertFalse(plan.breaks.isEmpty)
            for b in plan.breaks {
                XCTAssertEqual(b.estimatedSeconds, 12, "opener 8 s + closing 4 s lands exactly on the cap")
                XCTAssertTrue(b.cues.last!.text.hasPrefix("T\(b.afterTrack + 1) "), "the next-song closing line is never dropped")
                XCTAssertEqual(b.talkOverCueID, b.cues.last!.id)
                XCTAssertFalse(b.cues.contains { $0.text == "Okay." }, "a 1 s continuation would make it 13 s")
            }
            XCTAssertTrue(Set(plan.ordinaryCapReport.trimmedOptionalLines.keys).isSubset(of: Set(plan.breaks.map(\.afterTrack))))
            XCTAssertTrue(plan.ordinaryCapReport.skippedOverCap.isEmpty)
            trimmedTotal += plan.ordinaryCapReport.trimmedOptionalLines.values.reduce(0, +)
        }
        XCTAssertGreaterThan(trimmedTotal, 0, "every dropped continuation is reported")
    }

    func testTheSameBreaksKeepTheContinuationWhenTheCapAllowsIt() {
        var kept = false
        for seed: UInt64 in 0..<40 {
            var w = DJScriptWriter(cadence: cadence(cap: 13), seed: seed, tone: tone(openerWords: 20))
            let plan = w.plan(tracks: tracks, briefing: nil, hour: 15)
            kept = kept || plan.breaks.contains { $0.cues.contains { $0.text == "Okay." } && $0.estimatedSeconds == 13 }
            XCTAssertTrue(plan.ordinaryCapReport.trimmedOptionalLines.isEmpty)
        }
        XCTAssertTrue(kept, "control: the trim above is the 12 s cap, not the shape roll")
    }

    func testABreakWhoseRequiredLinesExceedTheCapIsSkippedAndReportedNotCutMidLine() {
        var w = DJScriptWriter(cadence: cadence(), seed: 7, tone: tone(openerWords: 22))   // 9 s + 4 s = 13 s
        let plan = w.plan(tracks: tracks, briefing: nil, hour: 15)
        XCTAssertTrue(plan.breaks.isEmpty, "no truncated line and no break without its closing line")
        XCTAssertFalse(plan.ordinaryCapReport.skippedOverCap.isEmpty)
        XCTAssertTrue(plan.ordinaryCapReport.trimmedOptionalLines.isEmpty, "a skipped boundary is reported once, as skipped")
    }

    func testAClosingLineThatIsNotTalkOverStillCountsTowardTheCap() {
        var w = DJScriptWriter(cadence: cadence(closing: 3), seed: 3, tone: tone(openerWords: 20))  // closing 4 s > 3 s
        let plan = w.plan(tracks: tracks, briefing: nil, hour: 15)
        XCTAssertFalse(plan.breaks.isEmpty)
        for b in plan.breaks {
            XCTAssertNil(b.talkOverCueID)
            XCTAssertEqual(b.estimatedSeconds, 12)
            XCTAssertEqual(b.mainSeconds, 12)
        }
    }

    func testBriefingBreaksKeepTheirOwnLimit() {
        func cue(_ order: Int) -> NarrationCue {
            NarrationCue(id: UUID(), order: order, group: 0, kind: .note, text: "Item \(order).", estimatedSeconds: 8, maxSeconds: 20,
                         sourceItemID: UUID(), source: .calendar, provenance: "p")
        }
        let handoff = NarrationHandoff(cues: (1...3).map(cue), maxSpokenSeconds: 150, experienceSeconds: 300)
        var w = DJScriptWriter(cadence: cadence(), seed: 1, tone: tone(openerWords: 20))
        let plan = w.plan(tracks: tracks, briefing: handoff, hour: 9)
        let briefing = plan.breaks.filter(\.hasBriefing)
        XCTAssertFalse(briefing.isEmpty)
        XCTAssertTrue(briefing.contains { $0.estimatedSeconds > 12 }, "the 12 s cap is for ordinary breaks only")
        XCTAssertTrue(briefing.allSatisfy { $0.estimatedSeconds <= 45 })
    }

    func testTheDefaultCapIsTwelveAndStationCadenceCarriesIt() {
        XCTAssertEqual(DJCadence().maxOrdinaryBreakSeconds, 12)
        #if DEBUG
        // TestStation exists only in DEBUG builds; the release check compiles these tests without it.
        XCTAssertEqual(TestStation.configuration.cadence().maxOrdinaryBreakSeconds, 12)
        XCTAssertEqual(TestStation.configuration.cadence(base: DJCadence(maxOrdinaryBreakSeconds: 10)).maxOrdinaryBreakSeconds, 10)
        #endif
    }
}
