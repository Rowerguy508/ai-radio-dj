import XCTest
@testable import AeroDJCore

/// Build 58 follow-up (-Nova): the window's trailing system inset (on the device, the status
/// column), read at the window root because the player's reader sits inside the safe area and
/// sees 0. No device or orientation detection: a trailing-only inset, or 0 (#626, Orion: an
/// inset on both sides, as on iPhone landscape, is not a status column).
final class TrailingSystemInsetTests: XCTestCase {
    func testNoInsetIsZero() {
        // iPhone portrait, and every iPad and simulator window.
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(leading: 0, trailing: 0), 0)
    }

    func testTrailingOnlyInsetPassesThrough() {
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(leading: 0, trailing: 73), 73)
    }

    func testInsetOnBothSidesIsZero() {
        // iPhone landscape (59 / 59) keeps the stock rail.
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(leading: 59, trailing: 59), 0)
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(leading: 47, trailing: 47), 0)
    }

    func testLeadingOnlyInsetIsZero() {
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(leading: 73, trailing: 0), 0)
    }

    func testSubPointLeadingStillCountsAsNone() {
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(leading: 0.5, trailing: 73), 73)
    }

    func testNonFiniteLeadingIsZero() {
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(leading: .nan, trailing: 73), 0)
    }

    func testSubPointInsetIsZero() {
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(leading: 0, trailing: 0.5), 0)
        XCTAssertEqual(DuoStationsLayout.trailingSystemInset(leading: 0, trailing: -12), 0)
    }

    func testNonFiniteIsZero() {
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(DuoStationsLayout.trailingSystemInset(leading: 0, trailing: bad), 0, "\(bad)")
        }
    }
}
