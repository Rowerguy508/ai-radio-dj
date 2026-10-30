#if DEBUG
import XCTest
@testable import AeroDJCore

/// The animation freeze is a UI-test-only hook: every other combination leaves motion alone. -Atlas
final class UITestAnimationFreezePolicyTests: XCTestCase {
    func testActiveOnlyOnTheDebugCapturePathWithTheFlag() {
        XCTAssertTrue(UITestAnimationFreezePolicy.isActive(flag: true, mode: .testStation,
                                                           studioCapture: true, allowsUITestHooks: true))
    }

    /// Release passes `allowsUITestHooks: false`: the flag is ignored whatever else is set.
    func testReleaseIgnoresTheFlag() {
        for mode in [AppRuntimeMode.live, .testStation] {
            for capture in [false, true] {
                XCTAssertFalse(UITestAnimationFreezePolicy.isActive(flag: true, mode: mode,
                                                                    studioCapture: capture, allowsUITestHooks: false),
                               "Release must ignore the flag (mode \(mode), capture \(capture))")
            }
        }
    }

    func testLiveModeIgnoresTheFlag() {
        XCTAssertFalse(UITestAnimationFreezePolicy.isActive(flag: true, mode: .live,
                                                            studioCapture: true, allowsUITestHooks: true))
    }

    func testOutsideStudioCaptureIgnoresTheFlag() {
        XCTAssertFalse(UITestAnimationFreezePolicy.isActive(flag: true, mode: .testStation,
                                                            studioCapture: false, allowsUITestHooks: true))
    }

    func testNoFlagNoFreeze() {
        XCTAssertFalse(UITestAnimationFreezePolicy.isActive(flag: false, mode: .testStation,
                                                            studioCapture: true, allowsUITestHooks: true))
    }

    func testLaunchArgumentKeyIsStable() {
        // StudioScreenTests passes `-AERODJ_UITEST_DISABLE_ANIMATIONS YES`; renaming one side
        // without the other would silently turn the freeze off.
        XCTAssertEqual(UITestAnimationFreezePolicy.defaultsKey, "AERODJ_UITEST_DISABLE_ANIMATIONS")
    }
}
#endif
