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

    private func timed(_ id: String, playing: Bool, at position: Double, of duration: Double = 200) -> PlaybackObservation {
        PlaybackObservation(entryID: id, isPlaying: playing, position: position, duration: duration)
    }

    func testSingleEntryQueueKeptAfterItsEndReportsQueueFinished() {
        // MusicKit kept the last entry instead of clearing it: the end comes from the position.
        var d = PlaybackBoundaryDetector()
        XCTAssertNil(d.consume(timed("A", playing: true, at: 10)))
        XCTAssertNil(d.consume(timed("A", playing: true, at: 150)))
        XCTAssertEqual(d.consume(timed("A", playing: false, at: 199)), .queueFinished(lastEntryID: "A"))
    }

    func testEndByPositionIsReportedOnce() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(timed("A", playing: true, at: 199))
        XCTAssertEqual(d.consume(timed("A", playing: false, at: 199.5)), .queueFinished(lastEntryID: "A"))
        XCTAssertNil(d.consume(timed("A", playing: false, at: 199.5)))
        XCTAssertNil(d.consume(timed("A", playing: false, at: 199.5)))
    }

    func testPauseMidSongIsNotAnEnd() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(timed("A", playing: true, at: 60))
        XCTAssertNil(d.consume(timed("A", playing: false, at: 60)))
        XCTAssertNil(d.consume(timed("A", playing: true, at: 61)))
    }

    func testPositionEndIsNotReportedWhenPausedBeforeIt() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(timed("A", playing: true, at: 190))
        XCTAssertNil(d.consume(timed("A", playing: false, at: 190)), "a pause 10 s before the end is not a finish")
    }

    func testPositionEndNeedsADuration() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(PlaybackObservation(entryID: "A", isPlaying: true, position: 199))
        XCTAssertNil(d.consume(PlaybackObservation(entryID: "A", isPlaying: false, position: 199)))
    }

    func testNextEntryAfterAPositionEndStartsFresh() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(timed("A", playing: true, at: 199))
        XCTAssertEqual(d.consume(timed("A", playing: false, at: 199)), .queueFinished(lastEntryID: "A"))
        // A new queue with the same song later reports its own end.
        _ = d.consume(timed("B", playing: true, at: 0))
        XCTAssertEqual(d.consume(timed("B", playing: false, at: 199)), .queueFinished(lastEntryID: "B"))
    }

    func testUserStopNearTheEndIsNotAFinish() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(timed("A", playing: true, at: 199))
        d.userRequestedChange()
        XCTAssertNil(d.consume(timed("A", playing: false, at: 199)))
    }

    private func assertNoBreak(for cause: PlaybackBoundaryDetector.HoldCause, file: StaticString = #filePath, line: UInt = #line) {
        var d = PlaybackBoundaryDetector()
        XCTAssertNil(d.consume(timed("A", playing: true, at: 199)), file: file, line: line)
        d.pausedByApp(cause)
        XCTAssertNil(
            d.consume(timed("A", playing: false, at: 199.2)),
            "\(cause) inside the last 1.5s produces no break",
            file: file,
            line: line
        )
    }

    func testUserPauseInsideTheLastSecondProducesNoBreak() {
        assertNoBreak(for: .userPause)
    }

    /// Build 18 P0 (-Fry): changed from "no break". A system interruption is not a user
    /// decision, and one that begins inside the last 1.5 s does not cancel the end: the stop is
    /// reported once (SongEndInterruptionTests has the full matrix and the hold rules).
    func testInterruptionInsideTheLastSecondIsStillTheEndOnce() {
        var d = PlaybackBoundaryDetector()
        XCTAssertNil(d.consume(timed("A", playing: true, at: 199)))
        d.pausedByApp(.systemInterruption)
        XCTAssertEqual(d.consume(timed("A", playing: false, at: 199.2)), .queueFinished(lastEntryID: "A"))
        XCTAssertNil(d.consume(timed("A", playing: false, at: 199.2)))
        XCTAssertTrue(d.interruptionBeganNearEnd)
    }

    func testRouteLossInsideTheLastSecondProducesNoBreak() {
        assertNoBreak(for: .routeLoss)
    }

    func testAPauseTheAppMadeInTheLastSecondsIsNotAFinish() {
        // A user pause, call or route change at 199.5 s must not play the break or advance the queue.
        var d = PlaybackBoundaryDetector()
        _ = d.consume(timed("A", playing: true, at: 199))
        d.pausedByApp()
        XCTAssertNil(d.consume(timed("A", playing: false, at: 199.5)))
        XCTAssertNil(d.consume(timed("A", playing: false, at: 199.5)))
        // After a resume, a real end at the same entry is still reported, once.
        _ = d.consume(timed("A", playing: true, at: 199.6))
        XCTAssertEqual(d.consume(timed("A", playing: false, at: 199.9)), .queueFinished(lastEntryID: "A"))
        XCTAssertNil(d.consume(timed("A", playing: false, at: 199.9)))
    }
}
