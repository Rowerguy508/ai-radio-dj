import XCTest
@testable import AeroDJCore

/// Owner-reported on the Duo (-Fry): a Siri interruption mid-break left the DJ voice and Siri
/// talking over each other. `BreakInterruptionState` decides what the break does on each
/// interruption notice. Linux green is not device evidence.
final class BreakInterruptionStateTests: XCTestCase {
    private func speaking(at line: Int, _ kind: BreakInterruptionKind = .boundary) -> BreakInterruptionState {
        var s = BreakInterruptionState()
        s.breakStarted(kind)
        for i in 0...line { s.lineStarted(i) }
        return s
    }

    func testBeganMidLinePausesAndRecordsTheLine() {
        var s = speaking(at: 2)
        XCTAssertEqual(s.interruptionBegan(), .pause(line: 2))
        XCTAssertEqual(s.phase, .paused(line: 2))
        XCTAssertTrue(s.isHolding)
    }

    func testBeganOnTheFirstLinePausesAtZero() {
        var s = BreakInterruptionState()
        s.breakStarted(.boundary)
        XCTAssertEqual(s.interruptionBegan(), .pause(line: 0))
    }

    func testEndedWithShouldResumeAcknowledgesThenResumesAtTheInterruptedLine() {
        var s = speaking(at: 1)
        _ = s.interruptionBegan()
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true), .playAcknowledgement(thenLine: 1))
        XCTAssertEqual(s.phase, .acknowledging(resumeLine: 1))
        XCTAssertFalse(s.isHolding)
        // The acknowledgement never moves the line.
        s.lineStarted(0)
        XCTAssertEqual(s.acknowledgementEnded(), .resume(fromLine: 1), "not from the start")
        XCTAssertEqual(s.phase, .speaking(line: 1))
        s.lineStarted(2)
        XCTAssertEqual(s.phase, .speaking(line: 2))
    }

    func testEndedWithShouldResumeAndNoAcknowledgementResumesAtOnce() {
        var s = speaking(at: 3)
        _ = s.interruptionBegan()
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: false), .resume(fromLine: 3))
        XCTAssertEqual(s.phase, .speaking(line: 3))
        XCTAssertEqual(s.acknowledgementEnded(), .none, "no acknowledgement was played")
    }

    func testEndedWithoutShouldResumeStaysPaused() {
        var s = speaking(at: 1)
        _ = s.interruptionBegan()
        XCTAssertEqual(s.interruptionEnded(shouldResume: false, acknowledgementReady: true), .stayPaused(line: 1))
        XCTAssertEqual(s.phase, .held(line: 1))
        XCTAssertTrue(s.isHolding)
        // Nothing restarts it on its own: no further notice or acknowledgement end resumes.
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true), .none)
        XCTAssertEqual(s.interruptionBegan(), .none)
        XCTAssertEqual(s.acknowledgementEnded(), .none)
        XCTAssertEqual(s.phase, .held(line: 1))
    }

    func testBeganWithNoBreakIsANoOp() {
        var s = BreakInterruptionState()
        XCTAssertEqual(s.interruptionBegan(), .none)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertFalse(s.isHolding)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true), .none)
        XCTAssertEqual(s.phase, .idle)
    }

    func testBeganAfterTheBreakEndedIsANoOp() {
        var s = speaking(at: 2)
        s.breakEnded()
        XCTAssertEqual(s.interruptionBegan(), .none)
        XCTAssertEqual(s.phase, .idle)
    }

    func testDoubleBeganIsIdempotent() {
        var s = speaking(at: 2)
        XCTAssertEqual(s.interruptionBegan(), .pause(line: 2))
        XCTAssertEqual(s.interruptionBegan(), .none)
        XCTAssertEqual(s.phase, .paused(line: 2))
        // A line start reported late (a delegate in flight) does not move a paused break.
        s.lineStarted(3)
        XCTAssertEqual(s.phase, .paused(line: 2))
    }

    func testDoubleEndedIsIdempotent() {
        var s = speaking(at: 2)
        _ = s.interruptionBegan()
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true), .playAcknowledgement(thenLine: 2))
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true), .none)
        XCTAssertEqual(s.phase, .acknowledging(resumeLine: 2))
    }

    func testEndedWithoutBeganIsANoOp() {
        var s = speaking(at: 1)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true), .none)
        XCTAssertEqual(s.interruptionEnded(shouldResume: false, acknowledgementReady: true), .none)
        XCTAssertEqual(s.phase, .speaking(line: 1))
    }

    func testInterruptionDuringTheAcknowledgementKeepsTheOwedLine() {
        var s = speaking(at: 2)
        _ = s.interruptionBegan()
        _ = s.interruptionEnded(shouldResume: true, acknowledgementReady: true)
        XCTAssertEqual(s.interruptionBegan(), .pause(line: 2), "the acknowledgement pauses; line 2 is still owed")
        XCTAssertEqual(s.phase, .paused(line: 2))
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true), .playAcknowledgement(thenLine: 2))
        XCTAssertEqual(s.acknowledgementEnded(), .resume(fromLine: 2))
    }

    func testInterruptionDuringTheAcknowledgementWithoutShouldResumeHolds() {
        var s = speaking(at: 1)
        _ = s.interruptionBegan()
        _ = s.interruptionEnded(shouldResume: true, acknowledgementReady: true)
        _ = s.interruptionBegan()
        XCTAssertEqual(s.interruptionEnded(shouldResume: false, acknowledgementReady: true), .stayPaused(line: 1))
        XCTAssertEqual(s.phase, .held(line: 1))
    }

    func testInterruptionDuringTalkoverOverlapStopsTheVoiceAndNeverReplays() {
        var s = speaking(at: 1, .talkover)
        XCTAssertEqual(s.interruptionBegan(), .stopTalkover)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertFalse(s.isHolding)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true), .none,
                       "the outro moved on: no acknowledgement, no replay")
        XCTAssertEqual(s.interruptionBegan(), .none)
    }

    func testTalkoverOnItsFirstLineStopsToo() {
        var s = BreakInterruptionState()
        s.breakStarted(.talkover)
        XCTAssertEqual(s.interruptionBegan(), .stopTalkover)
    }

    func testANewBreakAfterATalkoverIsABoundaryBreakAgain() {
        var s = speaking(at: 0, .talkover)
        s.breakEnded()
        s.breakStarted(.boundary)
        XCTAssertEqual(s.interruptionBegan(), .pause(line: 0))
    }

    func testBreakEndedWhileHeldClearsTheHold() {
        var s = speaking(at: 1)
        _ = s.interruptionBegan()
        _ = s.interruptionEnded(shouldResume: false, acknowledgementReady: false)
        s.breakEnded()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertFalse(s.isHolding)
    }

    func testTheAcknowledgementIsOneShortLocalOnlyConstant() {
        XCTAssertEqual(BreakInterruptionAcknowledgement.line, "Sorry, little interruption there.")
        let cue = BreakInterruptionAcknowledgement.cue()
        XCTAssertEqual(cue.text, BreakInterruptionAcknowledgement.line)
        XCTAssertNil(cue.sourceItemID)
        XCTAssertLessThanOrEqual(cue.maxSeconds, 4)
        // No attribution: never eligible for an off-device or paid route.
        XCTAssertFalse(VoiceRenderer.mayLeaveDevice(cue, attribution: nil))
    }
}
