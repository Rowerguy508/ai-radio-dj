import XCTest
@testable import AeroDJCore

final class OnboardingDuoLayoutTests: XCTestCase {
    func testPhoneClosedDuoAndPortraitStaySingleColumn() {
        let sizes: [(Double, Double)] = [
            (390, 844),  // iPhone / closed Duo portrait
            (844, 390),  // iPhone landscape
            (956, 440),  // iPhone Pro Max landscape
            (640, 820),  // Open-Duo Portrait (keeps duoWideLocalArea 560 pt column)
            (340, 760),  // Narrow Split View
            (540, 620),  // Standard sheet
        ]
        for (w, h) in sizes {
            let d = OnboardingDuoLayout.decide(.init(containerWidth: w, containerHeight: h))
            XCTAssertEqual(d.mode, .singleColumn, "Expected singleColumn for \(w)x\(h)")
        }
    }

    func testAccessibilityTextSizeStaysSingleColumn() {
        let d = OnboardingDuoLayout.decide(.init(containerWidth: 820, containerHeight: 640, accessibilityTextSize: true))
        XCTAssertEqual(d.mode, .singleColumn)
    }

    func testDuoLandscapeAlignsSymmetricPanesAround410() {
        let d = OnboardingDuoLayout.decide(OnboardingDuoLayout.duoLandscape)
        XCTAssertEqual(d.mode, .twoPane)
        XCTAssertEqual(d.leadingPadding, 24, accuracy: 0.001)
        XCTAssertEqual(d.leftPaneWidth, 370, accuracy: 0.001)
        XCTAssertEqual(d.gutterWidth, 32, accuracy: 0.001)
        XCTAssertEqual(d.rightPaneWidth, 370, accuracy: 0.001)
        XCTAssertEqual(d.trailingPadding, 24, accuracy: 0.001)
        XCTAssertEqual(d.gutterMinX, 394, accuracy: 0.001)
        XCTAssertEqual(d.gutterMaxX, 426, accuracy: 0.001)
        XCTAssertEqual(d.gutterMidX, 410, accuracy: 0.001)
        XCTAssertEqual(d.totalWidth, 820, accuracy: 0.001)
        XCTAssertEqual(d.decisionText, "twoPane 370/370")
    }

    func testCustomFoldCenterTracksFoldAndFallsBackWhenCrushed() {
        let shifted = OnboardingDuoLayout.Input(containerWidth: 820, containerHeight: 640, foldCenterX: 430)
        let d = OnboardingDuoLayout.decide(shifted)
        XCTAssertEqual(d.mode, .twoPane)
        XCTAssertEqual(d.gutterMidX, 430, accuracy: 0.001)
        XCTAssertEqual(d.leftPaneWidth, 390, accuracy: 0.001)
        XCTAssertEqual(d.rightPaneWidth, 350, accuracy: 0.001)
        XCTAssertEqual(d.totalWidth, 820, accuracy: 0.001)

        let crushed = OnboardingDuoLayout.Input(containerWidth: 820, containerHeight: 640, foldCenterX: 540)
        XCTAssertEqual(OnboardingDuoLayout.decide(crushed).mode, .singleColumn)
    }
}
