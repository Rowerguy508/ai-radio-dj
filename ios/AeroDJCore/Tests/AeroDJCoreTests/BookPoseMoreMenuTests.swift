import XCTest
@testable import AeroDJCore

/// #507 rest (-Nova): the player's rail ⋯ panel in book pose. It grows inward with large text;
/// it stops at the content column's leading edge (after the fold), never on the crease.
final class BookPoseMoreMenuTests: XCTestCase {
    func testWithoutALimitTheMenuIsTodays() {
        let today = DuoMoreMenuLayout.resolve(safeWidth: 820, safeHeight: 640)
        XCTAssertEqual(DuoMoreMenuLayout.resolve(safeWidth: 820, safeHeight: 640, leadingLimit: nil), today)
        XCTAssertEqual(today.trailingGap, 16 + 56 + 8)
        XCTAssertEqual(today.width, 820 - 80)
    }

    func testInBookPoseTheMenuStopsAtTheContentColumn() throws {
        // The reported 352…416 fold: the content column starts at 416.
        let decision = FoldAwareness.resolve(containerWidth: 820, containerHeight: 640,
                                             hinge: .init(status: .partiallyOpen, angleDegrees: 150),
                                             divisions: [.init(minX: 352, minY: 0, width: 64, height: 640, isActive: true)],
                                             artMin: 140, artMax: 420)
        XCTAssertTrue(decision.isBookPose)
        let limit = decision.metrics.contentMinX
        XCTAssertEqual(limit, 416)
        let menu = DuoMoreMenuLayout.resolve(safeWidth: 820, safeHeight: 640, leadingLimit: limit)
        let frame = menu.rect(in: CGRect(x: 0, y: 0, width: 820, height: 640))
        XCTAssertGreaterThanOrEqual(Double(frame.minX), limit - 0.001, "the panel \(frame) reaches the fold")
        XCTAssertEqual(Double(frame.maxX), 820 - menu.trailingGap, accuracy: 0.001, "the trailing edge stays put")
        XCTAssertEqual(menu.width, 820 - 80 - 416)
        XCTAssertEqual(menu.trailingGap, DuoMoreMenuLayout.resolve(safeWidth: 820, safeHeight: 640).trailingGap)
    }

    func testTheMenuNeverDropsUnderATarget() {
        let menu = DuoMoreMenuLayout.resolve(safeWidth: 820, safeHeight: 640, leadingLimit: 730)
        XCTAssertEqual(menu.width, 44)
        let nonsense = DuoMoreMenuLayout.resolve(safeWidth: 820, safeHeight: 640, leadingLimit: .nan)
        XCTAssertEqual(nonsense, DuoMoreMenuLayout.resolve(safeWidth: 820, safeHeight: 640))
    }
}
