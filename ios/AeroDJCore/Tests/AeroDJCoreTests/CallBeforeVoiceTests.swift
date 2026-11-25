import XCTest
@testable import AeroDJCore

/// F3 (-Fry): a call that starts after the boundary hands out a break but before the voice
/// starts (the `naturalBoundary` await) and ends after `play` refused the break.
/// Mirrors `InterludePlaybackAdapter.cancelledPendingPlay` and `MusicKitService.isBreakActive`.
final class CallBeforeVoiceTests: XCTestCase {
    private func breakIsActive(_ machine: AudioStateMachine) -> Bool {
        machine.state == .transition || machine.state == .voice
    }

    func testACallBeforeTheVoiceStartsResumesMusicWhenTheCallEnds() {
        var machine = AudioStateMachine()
        machine.apply(.startMusic)
        machine.apply(.trackEnded)
        XCTAssertEqual(machine.state, .transition, "the natural end of song 4 enters the boundary")

        var policy = AudioSessionPolicy()
        policy.userPlay()
        var play = PendingPlayStop()
        play.handOut(afterTrack: 4)

        // The call rings during `naturalBoundary`.
        XCTAssertEqual(policy.handle(.interruptionBegan, breakIsActive: breakIsActive(machine)), .suspendPlayback)
        let action = InterludeBoundaryStop.action(
            reason: .interruption, afterTrack: nil, isPlaying: false, playingTrack: 4)
        guard case .cancelPending(let tag) = action else {
            return XCTFail("the interruption during preparation is held")
        }
        _ = play.stop(reason: .interruption, afterTrack: tag, mayAutoResume: policy.mayAutoResume)

        // `play` runs while the call is still up: no audio, no resume yet.
        let opened = play.begin(afterTrack: 4, mayAutoResume: policy.mayAutoResume)
        XCTAssertFalse(opened.startAudio)
        XCTAssertFalse(opened.resumeMusic)
        let cancel = HeldBoundaryStopReport.cancellation(
            afterTrack: 4, mayAutoResume: opened.resumeMusic, phase: machine.state)
        XCTAssertEqual(cancel.audioEvent, .noInterlude)
        if let event = cancel.audioEvent { machine.apply(event) }
        XCTAssertEqual(machine.state, .music, "a cancelled hand-out does not leave the break active")

        // The call ends: music must come back, not stay paused until the next boundary.
        let ended = policy.handle(.interruptionEnded(shouldResume: true), breakIsActive: breakIsActive(machine))
        XCTAssertEqual(ended, .resumeIfPermitted)
    }

    func testTheCancelReturnsToMusicFromEveryBreakPhase() {
        XCTAssertEqual(HeldBoundaryStopReport.cancellation(afterTrack: 1, mayAutoResume: false, phase: .transition).audioEvent, .noInterlude)
        XCTAssertEqual(HeldBoundaryStopReport.cancellation(afterTrack: 1, mayAutoResume: false, phase: .voice).audioEvent, .interludeEnded)
        XCTAssertNil(HeldBoundaryStopReport.cancellation(afterTrack: 1, mayAutoResume: true, phase: .music).audioEvent)
        XCTAssertNil(HeldBoundaryStopReport.cancellation(afterTrack: 1, mayAutoResume: true, phase: .idle).audioEvent)
    }
}
