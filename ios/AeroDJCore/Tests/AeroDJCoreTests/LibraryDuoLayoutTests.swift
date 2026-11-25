import XCTest
@testable import AeroDJCore

final class LibraryDuoLayoutTests: XCTestCase {
    func testPhoneClosedDuoAndPortraitStaySingleColumn() {
        let sizes: [(Double, Double)] = [
            (390, 844),  // iPhone / closed Duo portrait
            (844, 390),  // iPhone landscape
            (956, 440),  // iPhone Pro Max landscape
            (640, 820),  // Open-Duo Portrait (keeps duoWideLibrary 2-column grid)
            (340, 760),  // Narrow Split View
            (540, 620),  // Standard sheet
        ]
        for (w, h) in sizes {
            let d = LibraryDuoLayout.decide(.init(containerWidth: w, containerHeight: h))
            XCTAssertEqual(d.mode, .singleColumn, "Expected singleColumn for \(w)x\(h)")
        }
    }

    func testSplitInsetsAndAccessibilityStaySingleColumn() {
        let split = LibraryDuoLayout.Input(containerWidth: 820, containerHeight: 640, hasSplitInsets: true)
        XCTAssertEqual(LibraryDuoLayout.decide(split).mode, .singleColumn)

        let a11y = LibraryDuoLayout.Input(containerWidth: 820, containerHeight: 640, accessibilityTextSize: true)
        XCTAssertEqual(LibraryDuoLayout.decide(a11y).mode, .singleColumn)
    }

    func testDuoLandscapeAlignsGutterToMidpoint410() {
        let d = LibraryDuoLayout.decide(LibraryDuoLayout.duoLandscape)
        XCTAssertEqual(d.mode, .twoPane)
        XCTAssertEqual(d.leadingPadding, 24, accuracy: 0.001)
        XCTAssertEqual(d.leftPaneWidth, 370, accuracy: 0.001)
        XCTAssertEqual(d.gutterWidth, 32, accuracy: 0.001)
        XCTAssertEqual(d.rightPaneWidth, 318, accuracy: 0.001)
        XCTAssertEqual(d.trailingPadding, 20, accuracy: 0.001)
        XCTAssertEqual(d.railWidth, 56, accuracy: 0.001)
        XCTAssertEqual(d.gutterMinX, 394, accuracy: 0.001)
        XCTAssertEqual(d.gutterMaxX, 426, accuracy: 0.001)
        XCTAssertEqual(d.gutterMidX, 410, accuracy: 0.001)
        XCTAssertEqual(d.totalWidth, 820, accuracy: 0.001)
        XCTAssertEqual(d.decisionText, "twoPane 370/318 rail 56")
    }

    func testCustomFoldCenterTracksFoldAndFallsBackWhenCrushed() {
        let shifted = LibraryDuoLayout.Input(containerWidth: 820, containerHeight: 640, foldCenterX: 430)
        let d = LibraryDuoLayout.decide(shifted)
        XCTAssertEqual(d.mode, .twoPane)
        XCTAssertEqual(d.gutterMidX, 430, accuracy: 0.001)
        XCTAssertEqual(d.leftPaneWidth, 390, accuracy: 0.001)
        XCTAssertEqual(d.rightPaneWidth, 298, accuracy: 0.001)
        XCTAssertEqual(d.totalWidth, 820, accuracy: 0.001)

        let crushed = LibraryDuoLayout.Input(containerWidth: 820, containerHeight: 640, foldCenterX: 520)
        XCTAssertEqual(LibraryDuoLayout.decide(crushed).mode, .singleColumn)
    }
}
