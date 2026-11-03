import XCTest
@testable import AeroDJCore

/// PR B x #379 (-Nova): a gap break paused by a system interruption does not resume its script
/// after a rating dropped its boundary, so a dropped cue is never re-aired. The adapter asks
/// `StationRatingResumeGate.mayResume` before `BreakInterruptionState`'s resume or apology.
final class StationRatingResumeGateTests: XCTestCase {
    func testDropOfTheOpenBreakRefusesItsResume() {
        var gate = StationRatingResumeGate()
        gate.breakOpened(afterTrack: 4)
        XCTAssertTrue(gate.mayResume)
        XCTAssertTrue(gate.boundaryDropped(afterTrack: 4))
        XCTAssertFalse(gate.mayResume)
    }

    func testDropOfAnotherBoundaryChangesNothing() {
        var gate = StationRatingResumeGate()
        gate.breakOpened(afterTrack: 4)
        XCTAssertFalse(gate.boundaryDropped(afterTrack: 5))
        XCTAssertFalse(gate.boundaryDropped(afterTrack: 3))
        XCTAssertTrue(gate.mayResume)
    }

    func testDropWithNoBreakOpenDoesNotCarryToTheNextBreak() {
        var gate = StationRatingResumeGate()
        XCTAssertFalse(gate.boundaryDropped(afterTrack: 4))
        gate.breakOpened(afterTrack: 4)
        XCTAssertTrue(gate.mayResume, "a drop before the hand-out is the session's job (songCut), not a resume block")
    }

    func testCloseAndNextBreakStartUnwithdrawn() {
        var gate = StationRatingResumeGate()
        gate.breakOpened(afterTrack: 4)
        gate.boundaryDropped(afterTrack: 4)
        gate.breakClosed()
        XCTAssertNil(gate.openBreak)
        XCTAssertTrue(gate.mayResume)
        gate.breakOpened(afterTrack: 4)
        gate.boundaryDropped(afterTrack: 4)
        gate.breakOpened(afterTrack: 5)
        XCTAssertTrue(gate.mayResume)
        XCTAssertEqual(gate.openBreak, 5)
    }

    /// The adapter's order: the interruption pauses line 1, a never rating on song 5 drops
    /// boundaries 4 and 5 (`StationRatingBreakDrop`), `.ended` with `shouldResume` comes. The
    /// interruption machine alone would resume from line 1; the gate ends the break instead.
    func testPausedBreakAtADroppedBoundaryIsNotResumed() {
        var gate = StationRatingResumeGate()
        var interruption = BreakInterruptionState()
        gate.breakOpened(afterTrack: 4)
        interruption.breakStarted(.boundary)
        interruption.lineStarted(1)
        XCTAssertEqual(interruption.interruptionBegan(at: 10), .pause(line: 1))
        for k in StationRatingBreakDrop.boundaries(forUpcoming: [5], playing: 4) { gate.boundaryDropped(afterTrack: k) }
        XCTAssertFalse(gate.mayResume)
        XCTAssertEqual(interruption.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 20),
                       .playAcknowledgement(thenLine: 1), "without the gate the break would resume")
    }

    /// Dropped during the apology: `acknowledgementEnded` would resume the script; the gate still refuses.
    func testDropDuringTheApologyStillRefusesTheScript() {
        var gate = StationRatingResumeGate()
        var interruption = BreakInterruptionState()
        gate.breakOpened(afterTrack: 2)
        interruption.breakStarted(.boundary)
        _ = interruption.interruptionBegan(at: 0)
        _ = interruption.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 5)
        gate.boundaryDropped(afterTrack: 2)
        XCTAssertEqual(interruption.acknowledgementEnded(), .resume(fromLine: 0))
        XCTAssertFalse(gate.mayResume)
    }
}
