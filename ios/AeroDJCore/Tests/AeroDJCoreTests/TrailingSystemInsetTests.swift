import XCTest
@testable import AeroDJCore

/// Build 58 follow-up (-Nova): the window's trailing system inset (on the device, the status
/// column), read at the window root because the player's reader sits inside the safe area and
/// sees 0. No device or orientation detection: the inset itself, or 0 when there is none.
final class TrailingSystemInsetTests: XCTestCase {
    func testNoInsetIsZero() {
        // iPhone portrait, and every iPad and simulator window.
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(trailing: 0), 0)
    }

    func testTrailingOnlyInsetPassesThrough() {
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(trailing: 73), 73)
    }

    func testSymmetricInsetPassesThrough() {
        // iPhone landscape (59 / 59): the trailing side is reported as is.
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(trailing: 59), 59)
    }

    func testSubPointInsetIsZero() {
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(trailing: 0.5), 0)
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(trailing: -12), 0)
    }

    func testNonFiniteIsZero() {
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(DuoStationsLayout.trailingSystemInset(trailing: bad), 0, "\(bad)")
        }
    }
}
