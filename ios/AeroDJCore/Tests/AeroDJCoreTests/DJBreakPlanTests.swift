import XCTest
@testable import AeroDJCore

final class DJBreakPlanTests: XCTestCase {
    func testLineIsKeyedByFinishedTrack() {
        let plan = DJBreakPlan(linesAfterTrack: [0: "That was song one."])
        XCTAssertEqual(plan.line(afterTrack: 0), "That was song one.")
        XCTAssertNil(plan.line(afterTrack: 1), "no line for a boundary the plan does not cover")
    }

    func testEmptyLineIsTreatedAsNoLine() {
        let plan = DJBreakPlan(linesAfterTrack: [0: ""])
        XCTAssertNil(plan.line(afterTrack: 0))
    }

    func testEmptyPlanHasNoLines() {
        XCTAssertNil(DJBreakPlan(linesAfterTrack: [:]).line(afterTrack: 0))
    }
}
