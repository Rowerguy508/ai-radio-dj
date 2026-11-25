import XCTest
@testable import AeroDJCore

final class StationTunerLayoutTests: XCTestCase {
    func testPhoneAndClosedDuoStaySingleColumn() {
        let sizes: [(Double, Double)] = [
            (390, 844),  // iPhone 15 / closed Duo portrait
            (844, 390),  // iPhone 15 landscape (short height)
            (430, 932),  // iPhone Pro Max portrait
            (956, 440),  // iPhone 16 Pro Max landscape (short height)
            (375, 667),  // iPhone SE
        ]
        for (w, h) in sizes {
            let decision = StationTunerLayout.decide(.init(containerWidth: w, containerHeight: h))
            XCTAssertEqual(decision.mode, .singleColumn, "Expected singleColumn for \(w)x\(h)")
        }
    }

    func testDuoPortraitAndNarrowSplitStaySingleColumn() {
        XCTAssertEqual(StationTunerLayout.decide(StationTunerLayout.duoPortrait).mode, .singleColumn)
        XCTAssertEqual(StationTunerLayout.decide(.init(containerWidth: 340, containerHeight: 760)).mode, .singleColumn)
        XCTAssertEqual(StationTunerLayout.decide(.init(containerWidth: 540, containerHeight: 620)).mode, .singleColumn)
    }

    func testSplitPaneAndAccessibilityStaySingleColumn() {
        let inSplit = StationTunerLayout.Input(containerWidth: 820, containerHeight: 640, isInSplitPane: true)
        XCTAssertEqual(StationTunerLayout.decide(inSplit).mode, .singleColumn)

        let a11y = StationTunerLayout.Input(containerWidth: 820, containerHeight: 640, accessibilityTextSize: true)
        XCTAssertEqual(StationTunerLayout.decide(a11y).mode, .singleColumn)
    }

    func testDuoLandscapeAlignsGutterToDeviceMidpoint410() {
        let d = StationTunerLayout.decide(StationTunerLayout.duoLandscape)
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

    func testSheetOuterInsetPreservesGlobalMidpoint410() {
        // Inside PlayingScreen's workspace sheet, outerHorizontalInset is 16 pt on each side,
        // leaving TuneForm with 788 pt width inside an 820 pt window.
        let input = StationTunerLayout.Input(containerWidth: 788,
                                             containerHeight: 580,
                                             outerHorizontalInset: 16)
        let d = StationTunerLayout.decide(input)
        XCTAssertEqual(d.mode, .twoPane)
        XCTAssertEqual(d.leadingPadding, 8, accuracy: 0.001)
        XCTAssertEqual(d.leftPaneWidth, 370, accuracy: 0.001)
        XCTAssertEqual(d.rightPaneWidth, 318, accuracy: 0.001)
        XCTAssertEqual(d.trailingPadding, 4, accuracy: 0.001)
        XCTAssertEqual(d.railWidth, 56, accuracy: 0.001)
        XCTAssertEqual(d.totalWidth, 788, accuracy: 0.001)
        // Global gutter center = outerInset (16) + local gutterMidX (394) = 410.0 pt exact!
        XCTAssertEqual(16 + d.gutterMidX, 410, accuracy: 0.001)
        XCTAssertEqual(16 + d.gutterMinX, 394, accuracy: 0.001)
        XCTAssertEqual(16 + d.gutterMaxX, 426, accuracy: 0.001)
    }

    func testCustomFoldCenterTracksFoldAndFallsBackWhenCrushed() {
        let shifted = StationTunerLayout.Input(containerWidth: 820, containerHeight: 640, foldCenterX: 430)
        let d = StationTunerLayout.decide(shifted)
        XCTAssertEqual(d.mode, .twoPane)
        XCTAssertEqual(d.gutterMidX, 430, accuracy: 0.001)
        XCTAssertEqual(d.leftPaneWidth, 390, accuracy: 0.001)
        XCTAssertEqual(d.rightPaneWidth, 298, accuracy: 0.001)
        XCTAssertEqual(d.totalWidth, 820, accuracy: 0.001)

        // Fold too far right crushes right pane below minPaneWidth (260 pt) -> falls back.
        let crushed = StationTunerLayout.Input(containerWidth: 820, containerHeight: 640, foldCenterX: 520)
        XCTAssertEqual(StationTunerLayout.decide(crushed).mode, .singleColumn)
    }
}
