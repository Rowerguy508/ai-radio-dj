import XCTest
@testable import AeroDJCore

final class SettingsMasterDetailLayoutTests: XCTestCase {
    func testPhoneClosedDuoAndPortraitStaySingleColumn() {
        let sizes: [(Double, Double)] = [
            (390, 844),  // iPhone / closed Duo portrait
            (844, 390),  // iPhone landscape
            (956, 440),  // iPhone Pro Max landscape
            (640, 820),  // Open-Duo Portrait (keeps AppWideLayout readable column)
            (340, 760),  // Narrow Split View
            (540, 620),  // Standard form sheet
        ]
        for (w, h) in sizes {
            let d = SettingsMasterDetailLayout.decide(.init(containerWidth: w, containerHeight: h))
            XCTAssertEqual(d.mode, .singleColumn, "Expected singleColumn for \(w)x\(h)")
        }
    }

    func testSplitInsetsAndAccessibilityStaySingleColumn() {
        let split = SettingsMasterDetailLayout.Input(containerWidth: 820, containerHeight: 640, hasSplitInsets: true)
        XCTAssertEqual(SettingsMasterDetailLayout.decide(split).mode, .singleColumn)

        let a11y = SettingsMasterDetailLayout.Input(containerWidth: 820, containerHeight: 640, accessibilityTextSize: true)
        XCTAssertEqual(SettingsMasterDetailLayout.decide(a11y).mode, .singleColumn)
    }

    func testDuoLandscapeAlignsGutterToMidpoint410() {
        let d = SettingsMasterDetailLayout.decide(SettingsMasterDetailLayout.duoLandscape)
        XCTAssertEqual(d.mode, .masterDetail)
        XCTAssertEqual(d.leadingPadding, 24, accuracy: 0.001)
        XCTAssertEqual(d.masterWidth, 370, accuracy: 0.001)
        XCTAssertEqual(d.gutterWidth, 32, accuracy: 0.001)
        XCTAssertEqual(d.detailWidth, 318, accuracy: 0.001)
        XCTAssertEqual(d.trailingPadding, 20, accuracy: 0.001)
        XCTAssertEqual(d.railWidth, 56, accuracy: 0.001)
        XCTAssertEqual(d.gutterMinX, 394, accuracy: 0.001)
        XCTAssertEqual(d.gutterMaxX, 426, accuracy: 0.001)
        XCTAssertEqual(d.gutterMidX, 410, accuracy: 0.001)
        XCTAssertEqual(d.totalWidth, 820, accuracy: 0.001)
        XCTAssertEqual(d.decisionText, "masterDetail 370/318 rail 56")
    }

    func testCustomFoldCenterTracksFoldAndFallsBackWhenCrushed() {
        let shifted = SettingsMasterDetailLayout.Input(containerWidth: 820, containerHeight: 640, foldCenterX: 430)
        let d = SettingsMasterDetailLayout.decide(shifted)
        XCTAssertEqual(d.mode, .masterDetail)
        XCTAssertEqual(d.gutterMidX, 430, accuracy: 0.001)
        XCTAssertEqual(d.masterWidth, 390, accuracy: 0.001)
        XCTAssertEqual(d.detailWidth, 298, accuracy: 0.001)
        XCTAssertEqual(d.totalWidth, 820, accuracy: 0.001)

        let crushed = SettingsMasterDetailLayout.Input(containerWidth: 820, containerHeight: 640, foldCenterX: 520)
        XCTAssertEqual(SettingsMasterDetailLayout.decide(crushed).mode, .singleColumn)
    }

    func testCategoryFilteringAndFallbackSelection() {
        XCTAssertEqual(
            SettingsMasterDetailLayout.availableCategories(hasRatings: false, hasPersonalDataReset: false),
            [.playback, .stationsLayout]
        )
        XCTAssertEqual(
            SettingsMasterDetailLayout.availableCategories(hasRatings: true, hasPersonalDataReset: true),
            [.playback, .stationsLayout, .ratings, .privacy]
        )
        XCTAssertEqual(
            SettingsMasterDetailLayout.resolvedSelection(.privacy, hasRatings: false, hasPersonalDataReset: false),
            .playback
        )
        XCTAssertEqual(
            SettingsMasterDetailLayout.resolvedSelection(.stationsLayout, hasRatings: false, hasPersonalDataReset: false),
            .stationsLayout
        )
    }
}
