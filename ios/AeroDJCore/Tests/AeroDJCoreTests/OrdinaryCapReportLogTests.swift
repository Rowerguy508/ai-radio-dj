#if DEBUG || AERODJ_P0_DIAG
import Foundation
import XCTest
@testable import AeroDJCore

/// #329 (2) (-Fry): the cap-report log line carries integers and closed reason codes only.
final class OrdinaryCapReportLogTests: XCTestCase {
    /// Every token the line may hold: fixed words, integers, 0/1 and reason `rawValue`s.
    static let shape = try! NSRegularExpression(pattern:
        #"^AeroDJ\.dj capReport after=\d+ trimmed=\d+ overCap=[01] timeCheckDrop=[A-Za-z]+ openerTime=[A-Za-z]+$"#)

    static func assertShape(_ line: String, file: StaticString = #filePath, line number: UInt = #line) {
        let range = NSRange(line.startIndex..., in: line)
        XCTAssertNotNil(shape.firstMatch(in: line, range: range), "unexpected log line: \(line)", file: file, line: number)
        XCTAssertNil(line.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#, options: .regularExpression),
                     "log line carries a UUID: \(line)", file: file, line: number)
    }

    func testNothingAtTheBoundaryLogsNothing() {
        var report = OrdinaryBreakCapReport()
        report.trimmedOptionalLines[3] = 2
        XCTAssertNil(OrdinaryCapReportLog.message(report, afterTrack: 4))
        XCTAssertNil(OrdinaryCapReportLog.record(OrdinaryBreakCapReport(), afterTrack: 0))
    }

    func testEveryFieldIsACountOrAReasonCode() {
        let cue = UUID()
        var report = OrdinaryBreakCapReport()
        report.trimmedOptionalLines[5] = 2
        report.skippedOverCap = [5]
        report.droppedTimeChecks[5] = DJTimeCheckDrop(cueID: cue, reason: .late)
        report.omittedOpenerTimeChecks[5] = .spacing
        let line = OrdinaryCapReportLog.record(report, afterTrack: 5)
        XCTAssertEqual(line, "AeroDJ.dj capReport after=5 trimmed=2 overCap=1 timeCheckDrop=late openerTime=spacing")
        Self.assertShape(try! XCTUnwrap(line))
        XCTAssertFalse(line!.contains(cue.uuidString), "the dropped time check's cue ID is never logged")
    }

    func testEveryReasonCodeKeepsTheShape() {
        for reason in DJTimeCheckDropReason.allCases {
            var report = OrdinaryBreakCapReport()
            report.droppedTimeChecks[1] = DJTimeCheckDrop(cueID: UUID(), reason: reason)
            Self.assertShape(try! XCTUnwrap(OrdinaryCapReportLog.message(report, afterTrack: 1)))
        }
        for omission in DJOpenerTimeCheckOmission.allCases {
            var report = OrdinaryBreakCapReport()
            report.omittedOpenerTimeChecks[1] = omission
            Self.assertShape(try! XCTUnwrap(OrdinaryCapReportLog.message(report, afterTrack: 1)))
        }
    }
}
#endif
