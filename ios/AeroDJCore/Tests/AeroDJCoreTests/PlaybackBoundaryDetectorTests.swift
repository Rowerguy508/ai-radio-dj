import XCTest
@testable import AeroDJCore

final class PlaybackBoundaryDetectorTests: XCTestCase {
    private func obs(_ id: String?, playing: Bool = true) -> PlaybackObservation {
        PlaybackObservation(entryID: id, isPlaying: playing)
    }

    func testNaturalAdvanceReportsOnce() {
        var d = PlaybackBoundaryDetector()
        XCTAssertNil(d.consume(obs("A")))
        XCTAssertNil(d.consume(obs("A")))
        XCTAssertEqual(d.consume(obs("B")), .naturalEnd(finishedEntryID: "A"))
        // Same samples again must not report a second boundary.
        XCTAssertNil(d.consume(obs("B")))
        XCTAssertNil(d.consume(obs("B")))
    }

    func testAutoAdvanceMissedBetweenSamplesStillReports() {
        var d = PlaybackBoundaryDetector()
        XCTAssertNil(d.consume(obs("A")))
        // The poll never saw A's end; it only sees B. The change is the signal.
        XCTAssertEqual(d.consume(obs("C")), .naturalEnd(finishedEntryID: "A"))
    }

    func testUserSkipIsNotNatural() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("A"))
        d.userRequestedChange()
        XCTAssertNil(d.consume(obs("B")))
        XCTAssertNil(d.consume(obs("B")))
    }

    func testQueueReplacementIsNotNatural() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("A"))
        d.userRequestedChange()
        XCTAssertNil(d.consume(obs("X")))
        // The next real end after the replacement is reported normally.
        XCTAssertEqual(d.consume(obs("Y")), .naturalEnd(finishedEntryID: "X"))
    }

    func testPhoneCallPauseIsNotAnEnd() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("A"))
        XCTAssertNil(d.consume(obs("A", playing: false)))
        XCTAssertNil(d.consume(obs("A", playing: false)))
        XCTAssertNil(d.consume(obs("A", playing: true)))
    }

    func testNaturalEndAfterInterruptionReportsOnce() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("A"))
        _ = d.consume(obs("A", playing: false))
        _ = d.consume(obs("A", playing: true))
        XCTAssertEqual(d.consume(obs("B")), .naturalEnd(finishedEntryID: "A"))
    }

    func testChangeWhilePausedIsNotNatural() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("A", playing: false))
        XCTAssertNil(d.consume(obs("B", playing: false)))
    }

    func testLastEntryFinishingReportsQueueFinishedOnce() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("A"))
        XCTAssertEqual(d.consume(obs(nil, playing: false)), .queueFinished(lastEntryID: "A"))
        XCTAssertNil(d.consume(obs(nil, playing: false)))
    }

    func testUserSkipOfLastEntryIsNotQueueFinished() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("A"))
        d.userRequestedChange()
        XCTAssertNil(d.consume(obs(nil, playing: false)))
    }
}
