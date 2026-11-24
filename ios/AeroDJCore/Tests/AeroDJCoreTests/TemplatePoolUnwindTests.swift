import XCTest
@testable import AeroDJCore

/// #319: replanned-away breaks, cap-trimmed optional lines, and over-cap skipped breaks
/// release their `TemplatePool` slots so unaired draws never shrink the effective pool size. -Echo
final class TemplatePoolUnwindTests: XCTestCase {
    private func tracks(_ count: Int) -> [DJTrack] {
        (0..<count).map { DJTrack(id: "t\($0)", title: "Song \($0)", artist: "Artist \($0)", origin: .catalog) }
    }

    func testTemplatePoolReleaseRestoresUnusedSlotAndClearsLastOnlyIfMatching() {
        var pool = TemplatePool(["A {x}", "B {x}", "C {x}"])
        var rng = SeededGenerator(seed: 1)
        let first = pool.nextPicked(filling: ["x": "1"], using: &rng)
        XCTAssertNotNil(first)
        XCTAssertEqual(pool.testUsedCount, 1)

        pool.release(first!.template)
        XCTAssertEqual(pool.testUsedCount, 0)

        // All three templates remain available in the first cycle (no premature repeat).
        var drawn: Set<String> = []
        for _ in 0..<3 {
            if let pick = pool.nextPicked(filling: ["x": "2"], using: &rng) { drawn.insert(pick.template) }
        }
        XCTAssertEqual(drawn.count, 3)
    }

    func testForgetPlannedBreaksUnwindsTemplatePoolsInNaturalMode() {
        var writer = DJScriptWriter(cadence: DJCadence(talkFraction: 1.0, minSongsBetweenBreaks: 1),
                                    seed: 7, shapes: DJBreakShapeConfig())
        let plan = writer.plan(tracks: tracks(20), briefing: nil, hour: 15)
        XCTAssertGreaterThan(plan.breaks.count, 2)
        XCTAssertGreaterThan(writer.testTotalPoolUsedCount, 0)

        writer.forgetPlannedBreaks(plan.breaks)
        XCTAssertEqual(writer.testTotalPoolUsedCount, 0,
                       "forgetting every planned break must return all drawn templates to their pools")
    }

    func testForgetPlannedBreaksUnwindsTemplatePoolsInClassicMode() {
        var writer = DJScriptWriter(cadence: DJCadence(talkFraction: 1.0, minSongsBetweenBreaks: 1),
                                    seed: 7, shapes: nil)
        let plan = writer.plan(tracks: tracks(20), briefing: nil, hour: 15)
        XCTAssertGreaterThan(plan.breaks.count, 2)
        XCTAssertGreaterThan(writer.testTotalPoolUsedCount, 0)

        writer.forgetPlannedBreaks(plan.breaks)
        XCTAssertEqual(writer.testTotalPoolUsedCount, 0,
                       "classic mode must also release TemplatePool slots when planned breaks are discarded")
    }

    func testForgettingTailBreaksPreservesKeptBreaksPoolUsage() {
        var writer = DJScriptWriter(cadence: DJCadence(talkFraction: 1.0, minSongsBetweenBreaks: 1),
                                    seed: 3, shapes: DJBreakShapeConfig())
        let plan = writer.plan(tracks: tracks(16), briefing: nil, hour: 15)
        XCTAssertGreaterThan(plan.breaks.count, 2)
        let usedBefore = writer.testTotalPoolUsedCount

        let discarded = Array(plan.breaks.dropFirst())
        writer.forgetPlannedBreaks(discarded)
        XCTAssertGreaterThan(writer.testTotalPoolUsedCount, 0, "kept break's drawn templates stay marked used")
        XCTAssertLessThan(writer.testTotalPoolUsedCount, usedBefore, "discarded tail breaks release their templates")
    }

    func testOverCapSkippedBreaksDoNotConsumePoolSlots() {
        // 1-second ordinary cap skips every ordinary break over cap in both natural and classic modes.
        for shapes in [DJBreakShapeConfig(), nil] {
            var writer = DJScriptWriter(
                cadence: DJCadence(talkFraction: 1.0, minSongsBetweenBreaks: 1,
                                   maxOrdinaryBreakSeconds: 1, maxOpenerBreakSeconds: 1),
                seed: 5, shapes: shapes)
            let plan = writer.plan(tracks: tracks(12), briefing: nil, hour: 15)
            XCTAssertTrue(plan.breaks.isEmpty, "1 s cap must skip all breaks")
            XCTAssertEqual(writer.testTotalPoolUsedCount, 0,
                           "breaks skipped for the cap must not leave templates marked used")
        }
    }
}
