import Foundation
import XCTest
@testable import AeroDJCore

/// #124: the search banner shows fixed copy, never the error's own text.
final class SearchFailureCopyTests: XCTestCase {
    private struct Leaky: LocalizedError {
        var errorDescription: String? { "secret query 'Taylor Swift' id=12345 url=https://api.music.apple.com" }
    }

    func testEveryKindHasFixedCopyExceptSuperseded() {
        for kind in SearchFailureKind.allCases {
            let text = SearchFailureCopy.message(for: kind)
            if kind == .superseded {
                XCTAssertNil(text)
            } else {
                XCTAssertNotNil(text, "\(kind)")
                XCTAssertFalse(text!.isEmpty)
                XCTAssertFalse(text!.contains("TEMPORARY"))
                XCTAssertFalse(text!.lowercased().contains("code"))
            }
        }
    }

    func testUnknownErrorUsesFallbackAndNeverItsOwnText() {
        let kind = SearchFailureCopy.kind(for: Leaky())
        XCTAssertEqual(kind, .unknown)
        let text = SearchFailureCopy.message(for: kind)
        XCTAssertEqual(text, "Search isn't available right now. Try again.")
        XCTAssertFalse(text!.contains("Taylor"))
        XCTAssertFalse(text!.contains("12345"))
        XCTAssertFalse(text!.contains("http"))
    }

    func testCancellationUsesFallback() {
        XCTAssertEqual(SearchFailureCopy.kind(for: CancellationError()), .unknown)
    }

    func testURLErrorsMapToNetworkCopy() {
        let offline = NSError(domain: "NSURLErrorDomain", code: -1009,
                              userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        XCTAssertEqual(SearchFailureCopy.kind(for: offline), .offline)
        XCTAssertEqual(SearchFailureCopy.kind(domain: "NSURLErrorDomain", code: -1005), .offline)
        XCTAssertEqual(SearchFailureCopy.kind(domain: "NSURLErrorDomain", code: -1001), .timedOut)
        XCTAssertEqual(SearchFailureCopy.kind(domain: "NSURLErrorDomain", code: -1004), .serviceUnavailable)
        XCTAssertEqual(SearchFailureCopy.kind(domain: "NSURLErrorDomain", code: -999), .unknown)
        XCTAssertEqual(SearchFailureCopy.message(for: .offline),
                       "You're offline. Connect to the internet and search again.")
    }

    func testPrivacyAcknowledgement() {
        XCTAssertEqual(SearchFailureCopy.kind(domain: "ICErrorDomain", code: -7007), .privacyAcknowledgementRequired)
        XCTAssertEqual(SearchFailureCopy.kind(domain: "ICErrorDomain", code: -8102), .unknown)
    }

    func testHTTPStatus() {
        XCTAssertEqual(SearchFailureCopy.kind(httpStatus: 401), .notAuthorized)
        XCTAssertEqual(SearchFailureCopy.kind(httpStatus: 403), .notAuthorized)
        XCTAssertEqual(SearchFailureCopy.kind(httpStatus: 429), .serviceUnavailable)
        XCTAssertEqual(SearchFailureCopy.kind(httpStatus: 503), .serviceUnavailable)
        XCTAssertEqual(SearchFailureCopy.kind(httpStatus: 404), .unknown)
    }

    func testUnknownDomainIsUnknown() {
        XCTAssertEqual(SearchFailureCopy.kind(domain: "SomeOtherDomain", code: -1009), .unknown)
    }
}
