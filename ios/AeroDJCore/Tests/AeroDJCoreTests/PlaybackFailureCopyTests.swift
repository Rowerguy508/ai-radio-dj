import Foundation
import XCTest
@testable import AeroDJCore

/// #133: playback errors show fixed copy, never codes, domains, attempt numbers or indices.
final class PlaybackFailureCopyTests: XCTestCase {
    func testEveryKindHasFixedPlainCopy() {
        for kind in PlaybackFailureKind.allCases {
            let text = PlaybackFailureCopy.message(for: kind)
            XCTAssertFalse(text.isEmpty, "\(kind)")
            XCTAssertFalse(text.contains("TEMPORARY"), "\(kind)")
            XCTAssertFalse(text.lowercased().contains("code"), "\(kind)")
            XCTAssertFalse(text.contains("attempt"), "\(kind)")
            XCTAssertFalse(text.contains("Domain"), "\(kind)")
            XCTAssertFalse(text.contains("MusicKit"), "\(kind)")
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "\(kind)")
        }
    }

    func testFallbackIsCouldNotStart() {
        XCTAssertEqual(PlaybackFailureCopy.message(for: .couldNotStart), PlaybackFailureCopy.fallback)
        XCTAssertEqual(PlaybackFailureCopy.fallback, "Apple Music couldn't start this song. Try again.")
    }

    func testThrownSupersededGetsItsOwnCopy() {
        XCTAssertEqual(PlaybackFailureCopy.bannerMessage(for: ThrownPlaybackFailure.superseded),
                       "Switched to your newer pick.")
        XCTAssertEqual(PlaybackFailureCopy.bannerMessage(for: ThrownPlaybackFailure.superseded),
                       PlaybackFailureCopy.message(for: .superseded))
        XCTAssertNotEqual(PlaybackFailureCopy.bannerMessage(for: ThrownPlaybackFailure.superseded),
                          PlaybackFailureCopy.fallback)
    }

    func testThrownCarriedCopyIsKept() {
        for kind in PlaybackFailureKind.allCases {
            let copy = PlaybackFailureCopy.message(for: kind)
            XCTAssertEqual(PlaybackFailureCopy.bannerMessage(for: ThrownPlaybackFailure.carriesCopy(copy)), copy, "\(kind)")
        }
    }

    func testThrownUnrecognizedGetsTheFallback() {
        XCTAssertEqual(PlaybackFailureCopy.bannerMessage(for: ThrownPlaybackFailure.unrecognized),
                       PlaybackFailureCopy.fallback)
    }

    func testExpiredResultsMatchTheSearchBanner() {
        XCTAssertEqual(PlaybackFailureCopy.message(for: .resultsExpired),
                       SearchFailureCopy.message(for: .resultsExpired))
    }

    func testStartFailuresUseTheCopy() {
        var attempts = PlaybackAttempts()
        let a = attempts.beginStart()
        let cases: [(StartFailure, PlaybackFailureKind)] = [
            (.confirmDeadline(last: .paused), .slowStart),
            (.confirmInterrupted, .interrupted),
            (.threw(PlaybackErrorCode(typeName: "NSError", domain: "MPErrorDomain", code: 6)), .couldNotStart),
            (.noProgressEnd, .stoppedEarly),
        ]
        for (failure, kind) in cases {
            let effect = StartFailurePolicy.effect(failure, attempt: a, current: attempts.current)
            XCTAssertEqual(effect.message, PlaybackFailureCopy.message(for: kind), "\(failure)")
        }
        XCTAssertNil(StartFailurePolicy.effect(.refused(pausedBySystem: true), attempt: a,
                                               current: attempts.current).message)
    }
}
