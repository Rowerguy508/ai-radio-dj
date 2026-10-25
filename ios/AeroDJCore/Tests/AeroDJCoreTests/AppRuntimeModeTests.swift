import XCTest
@testable import AeroDJCore

final class AppRuntimeModeTests: XCTestCase {
    func testNoFlagIsLive() {
        XCTAssertEqual(AppRuntimeMode.resolve(testStationFlag: false, allowsTestStation: true), .live)
    }

    func testDebugBuildWithFlagActivatesTestStation() {
        XCTAssertEqual(AppRuntimeMode.resolve(testStationFlag: true, allowsTestStation: true), .testStation)
    }

    /// Release passes `allowsTestStation: false`, so the flag cannot switch dependencies.
    func testReleaseCannotActivateTestStationEvenWithFlag() {
        XCTAssertEqual(AppRuntimeMode.resolve(testStationFlag: true, allowsTestStation: false), .live)
    }

    func testReleaseWithoutFlagIsLive() {
        XCTAssertEqual(AppRuntimeMode.resolve(testStationFlag: false, allowsTestStation: false), .live)
    }
}
