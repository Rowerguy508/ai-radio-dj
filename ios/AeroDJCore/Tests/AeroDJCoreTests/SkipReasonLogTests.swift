import XCTest
@testable import AeroDJCore

/// Release logs carry the session's real skip reason, not a blanket `notPlanned`.
final class SkipReasonLogTests: XCTestCase {
    func testNoBreakLogsTheSessionsOwnReason() {
        for reason in [DJBreakSkipReason.notReadyAtBoundary, .cancelled, .timedOut, .renderFailed,
                       .overBreakBudget, .sourceRevoked, .interrupted] {
            XCTAssertEqual(PlaybackLog.noBreakReason((reason, true)), reason)
            XCTAssertEqual(PlaybackLog.breakSkipped(after: 0, reason: PlaybackLog.noBreakReason((reason, false))),
                           "break skipped after=0 reason=\(reason.rawValue)")
        }
    }

    func testNoRecordedReasonIsNotPlanned() {
        XCTAssertEqual(PlaybackLog.noBreakReason(nil), .notPlanned)
    }

    func testHandedOutSkipsMapToFixedReasons() {
        XCTAssertEqual(PlaybackLog.handedOutReason(.emptyLine), .renderFailed)
        XCTAssertEqual(PlaybackLog.handedOutReason(.decodeFailed), .renderFailed)
        XCTAssertEqual(PlaybackLog.handedOutReason(.notPlayable), .notPlanned)
    }

    /// PlayerView must not hard-code `.notPlanned` when it logs a skipped break.
    func testPlayerViewLogsTheRealReason() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/PlayerView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("logBreakSkipped(after: finishedIndex, reason: .notPlanned)"))
        XCTAssertTrue(source.contains("PlaybackLog.noBreakReason(djSession.lastNoBreak)"))
        XCTAssertTrue(source.contains("PlaybackLog.handedOutReason(reason)"))
    }
}
