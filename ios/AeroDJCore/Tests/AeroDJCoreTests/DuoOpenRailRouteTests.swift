import XCTest
@testable import AeroDJCore

/// Build 51 (#542 follow-up, -Atlas): the two open-Duo screens that lost the rail.
/// 1. Landscape (820 × 640 window): the layout gate read the reader's height under the navigation
///    bar (~566–590 pt), below `landscapeDuoMinHeight`, so the player was the centred column with the
///    transport off the bottom. The gate now reads `routingHeight` (reader + vertical safe area).
/// 2. Stations sidebar open: a regular-width detail ~500 pt wide and window-tall got the phone or
///    centred column with no rail. `usesRailColumn` sends it to the centred column beside the rail.
final class DuoOpenRailRouteTests: XCTestCase {
    func testTheLandscapeWindowUnderItsNavigationBarWasTheCentredColumn() {
        // The reader alone: the build 51 bug.
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: 820, containerHeight: 590), .centredColumn)
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: 820, containerHeight: 566), .centredColumn)
        // The routed height is the window again: the rail.
        let routed = FoldedColumnLayout.routingHeight(readerHeight: 566, safeAreaTop: 74, safeAreaBottom: 0)
        XCTAssertEqual(routed, 640)
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: 820, containerHeight: routed), .duoHorizontal)
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: 820, containerHeight: routed,
                                                accessibilityTextSize: false), .duoHorizontal)
    }

    func testRoutingHeightIgnoresNegativeInsets() {
        XCTAssertEqual(FoldedColumnLayout.routingHeight(readerHeight: 400, safeAreaTop: -3, safeAreaBottom: 20), 420)
    }

    /// CI run 44014298982 (iPhone 16e): the Studio resize probe's widened column (Studio-height,
    /// wider than the 390 pt window) is centred off screen, at about (−235, −96). Its insets are
    /// the hidden parts under the bars, so it keeps the reader height and the two-zone Studio.
    func testAContainerCentredOffScreenKeepsItsReaderHeight() {
        let probeHeight = FoldedColumnLayout.landscapeDuoMinHeight - 80
        XCTAssertEqual(FoldedColumnLayout.routingHeight(readerHeight: probeHeight, safeAreaTop: 197, safeAreaBottom: 0,
                                                        readerMinX: -235, readerMinY: -96), probeHeight)
        XCTAssertEqual(FoldedColumnLayout.routingHeight(readerHeight: probeHeight, safeAreaTop: 197, safeAreaBottom: 0,
                                                        readerMinX: 10, readerMinY: -96), probeHeight)
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: 780, containerHeight: probeHeight,
                                                accessibilityTextSize: false), .studio)
        // On screen (the open Duo's window, or the 820 × 640 capture container centred in the iPad
        // window at x = 0): the insets count.
        XCTAssertEqual(FoldedColumnLayout.routingHeight(readerHeight: 590, safeAreaTop: 50, safeAreaBottom: 0,
                                                        readerMinX: 0, readerMinY: 320), 640)
        XCTAssertEqual(FoldedColumnLayout.routingHeight(readerHeight: 590, safeAreaTop: 50, safeAreaBottom: 0,
                                                        readerMinX: -0.5, readerMinY: 50), 640)
    }

    /// Phones keep their layouts with the routed height: iPhone landscape is at most 430 pt
    /// tall as a window, and phone portrait is under `wideMinWidth`.
    func testPhonesKeepTheirLayoutsWithTheRoutedHeight() {
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: 932, containerHeight: 430), .centredColumn)
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: 430, containerHeight: 932), .phoneBottom)
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: 640, containerHeight: 820), .duoHorizontal)
    }

    func testTheSidebarOpenDetailGetsTheRailColumn() {
        for width in [320.0, 445, 499.5, 500, 560, 715] {
            XCTAssertTrue(FoldedColumnLayout.usesRailColumn(hasRegularWidth: true, containerWidth: width, containerHeight: 640),
                          "regular \(width) × 640")
        }
        // A wide-enough iPad portrait detail with the sidebar is already the two-halves rail.
        XCTAssertFalse(FoldedColumnLayout.usesRailColumn(hasRegularWidth: true, containerWidth: 500, containerHeight: 1180))
        XCTAssertTrue(FoldedColumnLayout.usesRailColumn(hasRegularWidth: true, containerWidth: 480, containerHeight: 1180))
    }

    func testTheRailColumnNeverReplacesTheHorizontalDuoOrAPhone() {
        // The whole landscape window and the portrait Duo are the two-halves rail.
        XCTAssertFalse(FoldedColumnLayout.usesRailColumn(hasRegularWidth: true, containerWidth: 820, containerHeight: 640))
        XCTAssertFalse(FoldedColumnLayout.usesRailColumn(hasRegularWidth: false, containerWidth: 640, containerHeight: 820))
        // iPhone landscape (regular on the large phones) is too short.
        XCTAssertFalse(FoldedColumnLayout.usesRailColumn(hasRegularWidth: true, containerWidth: 932, containerHeight: 430))
        XCTAssertFalse(FoldedColumnLayout.usesRailColumn(hasRegularWidth: true, containerWidth: 500, containerHeight: 599))
        // Compact class (phone portrait, the folded Duo, a narrow split) is never the rail column.
        XCTAssertFalse(FoldedColumnLayout.usesRailColumn(hasRegularWidth: false, containerWidth: 500, containerHeight: 640))
        XCTAssertFalse(FoldedColumnLayout.usesRailColumn(hasRegularWidth: false, containerWidth: 390, containerHeight: 844))
        // Too narrow for the column beside the rail.
        XCTAssertFalse(FoldedColumnLayout.usesRailColumn(hasRegularWidth: true, containerWidth: 319, containerHeight: 900))
        XCTAssertFalse(FoldedColumnLayout.usesRailColumn(hasRegularWidth: true, containerWidth: .infinity, containerHeight: 900))
        XCTAssertFalse(FoldedColumnLayout.usesRailColumn(hasRegularWidth: true, containerWidth: 500, containerHeight: .nan))
    }
}
