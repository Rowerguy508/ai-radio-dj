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
        XCTAssertEqual(s.interruptionBegan(at: 0), .pause(line: 2))
        XCTAssertEqual(s.phase, .paused(line: 2))
        XCTAssertTrue(s.isHolding)
    }

    func testBeganOnTheFirstLinePausesAtZero() {
        var s = BreakInterruptionState()
        s.breakStarted(.boundary)
        XCTAssertEqual(s.interruptionBegan(at: 0), .pause(line: 0))
    }

    func testEndedWithShouldResumeAcknowledgesThenResumesAtTheInterruptedLine() {
        var s = speaking(at: 1)
        _ = s.interruptionBegan(at: 0)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10), .playAcknowledgement(thenLine: 1))
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
        _ = s.interruptionBegan(at: 0)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: false, at: 10), .resume(fromLine: 3))
        XCTAssertEqual(s.phase, .speaking(line: 3))
        XCTAssertEqual(s.acknowledgementEnded(), .none, "no acknowledgement was played")
    }

    func testEndedWithoutShouldResumeStaysPaused() {
        var s = speaking(at: 1)
        _ = s.interruptionBegan(at: 0)
        XCTAssertEqual(s.interruptionEnded(shouldResume: false, acknowledgementReady: true, at: 10), .stayPaused(line: 1))
        XCTAssertEqual(s.phase, .held(line: 1))
        XCTAssertTrue(s.isHolding)
        // Nothing restarts it on its own: no further notice or acknowledgement end resumes.
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10), .none)
        XCTAssertEqual(s.interruptionBegan(at: 0), .none)
        XCTAssertEqual(s.acknowledgementEnded(), .none)
        XCTAssertEqual(s.phase, .held(line: 1))
    }

    func testNoEndedWithinTheLimitHoldsAndNothingRestarts() {
        var s = speaking(at: 2)
        _ = s.interruptionBegan(at: 0)
        XCTAssertEqual(s.pauseExpired(), .stayPaused(line: 2))
        XCTAssertEqual(s.phase, .held(line: 2))
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10), .none, "a late end resumes nothing")
        XCTAssertEqual(s.pauseExpired(), .none)
        XCTAssertGreaterThan(BreakInterruptionState.maxPausedSeconds, 0)
    }

    func testPauseExpiryOutsideAPauseIsANoOp() {
        var s = speaking(at: 1)
        XCTAssertEqual(s.pauseExpired(), .none)
        XCTAssertEqual(s.phase, .speaking(line: 1))
        _ = s.interruptionBegan(at: 0)
        _ = s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10)
        XCTAssertEqual(s.pauseExpired(), .none, "an acknowledgement on air is not paused")
        XCTAssertEqual(s.phase, .acknowledging(resumeLine: 1))
    }

    func testBeganWithNoBreakIsANoOp() {
        var s = BreakInterruptionState()
        XCTAssertEqual(s.interruptionBegan(at: 0), .none)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertFalse(s.isHolding)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10), .none)
        XCTAssertEqual(s.phase, .idle)
    }

    func testBeganAfterTheBreakEndedIsANoOp() {
        var s = speaking(at: 2)
        s.breakEnded()
        XCTAssertEqual(s.interruptionBegan(at: 0), .none)
        XCTAssertEqual(s.phase, .idle)
    }

    func testDoubleBeganIsIdempotent() {
        var s = speaking(at: 2)
        XCTAssertEqual(s.interruptionBegan(at: 0), .pause(line: 2))
        XCTAssertEqual(s.interruptionBegan(at: 0), .none)
        XCTAssertEqual(s.phase, .paused(line: 2))
        // A line start reported late (a delegate in flight) does not move a paused break.
        s.lineStarted(3)
        XCTAssertEqual(s.phase, .paused(line: 2))
    }

    func testDoubleEndedIsIdempotent() {
        var s = speaking(at: 2)
        _ = s.interruptionBegan(at: 0)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10), .playAcknowledgement(thenLine: 2))
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10), .none)
        XCTAssertEqual(s.phase, .acknowledging(resumeLine: 2))
    }

    func testEndedWithoutBeganIsANoOp() {
        var s = speaking(at: 1)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10), .none)
        XCTAssertEqual(s.interruptionEnded(shouldResume: false, acknowledgementReady: true, at: 10), .none)
        XCTAssertEqual(s.phase, .speaking(line: 1))
    }

    func testInterruptionDuringTheAcknowledgementKeepsTheOwedLineWithoutASecondApology() {
        var s = speaking(at: 2)
        _ = s.interruptionBegan(at: 0)
        _ = s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10)
        XCTAssertEqual(s.interruptionBegan(at: 11), .pause(line: 2), "the acknowledgement pauses; line 2 is still owed")
        XCTAssertEqual(s.phase, .paused(line: 2))
        // At most one apology per break (#379 N3): the interrupted one counts as said.
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 21), .resume(fromLine: 2))
        XCTAssertEqual(s.phase, .speaking(line: 2))
        XCTAssertEqual(s.acknowledgementEnded(), .none)
    }

    // MARK: #379 N3 (Echo): no apology for a very short interruption, at most one per break

    func testAShortInterruptionResumesWithoutAnApology() {
        var s = speaking(at: 1)
        _ = s.interruptionBegan(at: 100)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 101.5), .resume(fromLine: 1))
        XCTAssertEqual(s.phase, .speaking(line: 1))
        XCTAssertFalse(s.apologized)
    }

    func testTheShortInterruptionThresholdIsTwoSecondsInclusive() {
        XCTAssertEqual(BreakInterruptionAcknowledgement.minInterruptionSeconds, 2)
        var under = speaking(at: 1)
        _ = under.interruptionBegan(at: 100)
        XCTAssertEqual(under.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 101.99),
                       .resume(fromLine: 1), "just under 2 s: no apology")
        var at = speaking(at: 1)
        _ = at.interruptionBegan(at: 100)
        XCTAssertEqual(at.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 102),
                       .playAcknowledgement(thenLine: 1), "exactly 2 s: apologized")
    }

    func testAtMostOneApologyPerBreak() {
        var s = speaking(at: 0)
        _ = s.interruptionBegan(at: 0)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10), .playAcknowledgement(thenLine: 0))
        XCTAssertTrue(s.apologized)
        XCTAssertEqual(s.acknowledgementEnded(), .resume(fromLine: 0))
        s.lineStarted(1)
        _ = s.interruptionBegan(at: 20)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 40), .resume(fromLine: 1),
                       "a second long interruption in the same break: no second apology")
    }

    func testAShortInterruptionDoesNotSpendTheApology() {
        var s = speaking(at: 0)
        _ = s.interruptionBegan(at: 0)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 1), .resume(fromLine: 0))
        _ = s.interruptionBegan(at: 5)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 15), .playAcknowledgement(thenLine: 0))
    }

    func testANewBreakMayApologizeAgain() {
        var s = speaking(at: 0)
        _ = s.interruptionBegan(at: 0)
        _ = s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10)
        _ = s.acknowledgementEnded()
        s.breakEnded()
        XCTAssertFalse(s.apologized)
        s.breakStarted(.boundary)
        _ = s.interruptionBegan(at: 100)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 110), .playAcknowledgement(thenLine: 0))
    }

    func testInterruptionDuringTheAcknowledgementWithoutShouldResumeHolds() {
        var s = speaking(at: 1)
        _ = s.interruptionBegan(at: 0)
        _ = s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10)
        _ = s.interruptionBegan(at: 0)
        XCTAssertEqual(s.interruptionEnded(shouldResume: false, acknowledgementReady: true, at: 10), .stayPaused(line: 1))
        XCTAssertEqual(s.phase, .held(line: 1))
    }

    func testInterruptionDuringTalkoverOverlapStopsTheVoiceAndNeverReplays() {
        var s = speaking(at: 1, .talkover)
        XCTAssertEqual(s.interruptionBegan(at: 0), .stopTalkover)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertFalse(s.isHolding)
        XCTAssertEqual(s.interruptionEnded(shouldResume: true, acknowledgementReady: true, at: 10), .none,
                       "the outro moved on: no acknowledgement, no replay")
        XCTAssertEqual(s.interruptionBegan(at: 0), .none)
    }

    func testTalkoverOnItsFirstLineStopsToo() {
        var s = BreakInterruptionState()
        s.breakStarted(.talkover)
        XCTAssertEqual(s.interruptionBegan(at: 0), .stopTalkover)
    }

    func testANewBreakAfterATalkoverIsABoundaryBreakAgain() {
        var s = speaking(at: 0, .talkover)
        s.breakEnded()
        s.breakStarted(.boundary)
        XCTAssertEqual(s.interruptionBegan(at: 0), .pause(line: 0))
    }

    func testBreakEndedWhileHeldClearsTheHold() {
        var s = speaking(at: 1)
        _ = s.interruptionBegan(at: 0)
        _ = s.interruptionEnded(shouldResume: false, acknowledgementReady: false, at: 10)
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
