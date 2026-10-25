import XCTest
@testable import AeroDJCore

final class SharedItemValidatorTests: XCTestCase {
    func testValidTextAccepted() throws {
        let v = SharedItemValidator()
        let item = try v.validate("  Hello world  ", source: "userShared")
        XCTAssertEqual(item.text, "Hello world")
        XCTAssertFalse(item.isURL)
    }

    func testEmptyRejected() {
        let v = SharedItemValidator()
        XCTAssertThrowsError(try v.validate("   \n  ", source: "userShared")) { err in
            XCTAssertEqual(err as? SharedItemValidator.ValidationError, .empty)
        }
    }

    func testTooLongRejected() {
        let v = SharedItemValidator(maxLength: 10)
        XCTAssertThrowsError(try v.validate("this is way too long", source: "userShared")) { err in
            XCTAssertEqual(err as? SharedItemValidator.ValidationError, .tooLong)
        }
    }

    func testURLDetected() throws {
        let v = SharedItemValidator()
        let item = try v.validate("https://example.com", source: "userShared")
        XCTAssertTrue(item.isURL)
    }

    func testPruneEnforcesRetentionAndCap() {
        let v = SharedItemValidator(maxItems: 2, retentionDays: 7)
        let now = Date()
        let old = SharedItem(text: "old", source: "s", createdAt: now.addingTimeInterval(-8 * 86_400))
        let a = SharedItem(text: "a", source: "s", createdAt: now)
        let b = SharedItem(text: "b", source: "s", createdAt: now.addingTimeInterval(-60))
        let c = SharedItem(text: "c", source: "s", createdAt: now.addingTimeInterval(-120))
        let kept = v.prune([old, a, b, c], now: now)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.map(\.text), ["a", "b"]) // newest first, cap 2
    }
}
