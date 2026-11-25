#if DEBUG
import XCTest
@testable import AeroDJCore

/// #465 item 1 (DEBUG capture only, -Nova): the system vertical bar is attached only when every
/// gate holds, and each capture frame is one the open-Duo rail path takes.
final class SystemVerticalBarsCaptureTests: XCTestCase {
    func testOnlyEveryGateTogetherAttachesTheSystemBar() {
        for mask in 0..<16 {
            let capture = mask & 1 != 0, station = mask & 2 != 0, flag = mask & 4 != 0, sdk = mask & 8 != 0
            XCTAssertEqual(SystemVerticalBarsCapture.attachesSystemBar(studioCapture: capture, testStation: station,
                                                                       launchFlag: flag, sdkHasVerticalBar: sdk),
                           mask == 15, "mask \(mask)")
        }
    }

    func testTheDefaultDebugRunKeepsRailD() {
        // A capture run without the flag (every existing Rail D shot) keeps the custom rail.
        XCTAssertFalse(SystemVerticalBarsCapture.attachesSystemBar(studioCapture: true, testStation: true,
                                                                   launchFlag: false, sdkHasVerticalBar: true))
        // The flag on the iOS 26.5 SDK (the Studio UI job) has no vertical bar to draw.
        XCTAssertFalse(SystemVerticalBarsCapture.attachesSystemBar(studioCapture: true, testStation: true,
                                                                   launchFlag: true, sdkHasVerticalBar: false))
    }

    func testLaunchKeyAndScenarioNames() {
        XCTAssertEqual(SystemVerticalBarsCapture.launchKey, "AeroDJCaptureSystemVerticalBars")
        XCTAssertEqual(SystemVerticalBarsCapture.Scenario.named("systemVerticalBarsDuoOpenPortrait"), .duoOpenPortrait)
        XCTAssertEqual(SystemVerticalBarsCapture.Scenario.named("systemVerticalBarsDuoOpenLandscape"), .duoOpenLandscape)
        XCTAssertNil(SystemVerticalBarsCapture.Scenario.named("railDPortrait"))
        XCTAssertNil(SystemVerticalBarsCapture.Scenario.named(nil))
        XCTAssertEqual(SystemVerticalBarsCapture.Scenario.allCases.map(\.shotName),
                       ["system-vertical-bars-duo-open-portrait", "system-vertical-bars-duo-open-landscape"])
        XCTAssertEqual(SystemVerticalBarsCapture.Scenario.duoOpenPortrait.collapsedShotName,
                       "system-vertical-bars-duo-open-portrait-collapsed")
    }

    /// `keepSystemVerticalBar` is `placement == .duoHorizontal` (PlayingScreen), so each frame has
    /// to route to the open-Duo rail on both idioms, or the capture would show no system bar.
    func testEveryFrameIsTheOpenDuoRailPath() {
        for scenario in SystemVerticalBarsCapture.Scenario.allCases {
            for phone in [true, false] {
                let layout = DisplayContinuity.layout(hasRegularWidth: scenario.hasRegularWidth,
                                                      containerWidth: scenario.containerWidth,
                                                      containerHeight: scenario.containerHeight,
                                                      accessibilityTextSize: false, isPhoneIdiom: phone)
                XCTAssertEqual(layout, .duoHorizontal, "\(scenario) phone=\(phone)")
            }
        }
    }

    /// The frames match Rail D's portrait and landscape capture frames exactly.
    func testFramesAreRailDFrames() {
        let portrait = SystemVerticalBarsCapture.Scenario.duoOpenPortrait
        XCTAssertEqual([portrait.containerWidth, portrait.containerHeight], [640, 820])
        XCTAssertFalse(portrait.hasRegularWidth)
        let landscape = SystemVerticalBarsCapture.Scenario.duoOpenLandscape
        XCTAssertEqual([landscape.containerWidth, landscape.containerHeight], [820, 640])
        XCTAssertTrue(landscape.hasRegularWidth)
    }
}
#endif
