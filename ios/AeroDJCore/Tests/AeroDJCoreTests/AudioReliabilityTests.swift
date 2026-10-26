import XCTest
@testable import AeroDJCore

/// Session notices, user pause, and narration resume. No AVFoundation and no clock sleeps.
final class AudioReliabilityTests: XCTestCase {
    func testIncomingCallBeginsAndEndsWithPermission() {
        var policy = AudioSessionPolicy()
        policy.userPlay()

        XCTAssertEqual(policy.handle(.interruptionBegan, breakIsActive: false), .suspendPlayback)
        XCTAssertTrue(policy.pausedBySystem)
        XCTAssertFalse(policy.mayAutoResume)

        XCTAssertEqual(
            policy.handle(.interruptionEnded(shouldResume: true), breakIsActive: false),
            .resumeIfPermitted
        )
        XCTAssertFalse(policy.pausedBySystem)
        XCTAssertTrue(policy.mayAutoResume)
    }

    func testInterruptionEndedWithoutShouldResumeDoesNotResume() {
        var policy = AudioSessionPolicy()
        policy.userPlay()
        _ = policy.handle(.interruptionBegan, breakIsActive: false)

        XCTAssertEqual(
            policy.handle(.interruptionEnded(shouldResume: false), breakIsActive: false),
            .none
        )
        XCTAssertTrue(policy.pausedBySystem)
        XCTAssertFalse(policy.mayAutoResume, "the system did not grant resume")

        policy.userPlay()
        XCTAssertTrue(policy.mayAutoResume, "only an explicit play clears the hold")
    }

    func testHeadphonesDisconnectHoldsUntilUserPlay() {
        var policy = AudioSessionPolicy()
        policy.userPlay()

        XCTAssertEqual(
            policy.handle(.routeChange(deviceRemoved: true), breakIsActive: false),
            .suspendPlayback
        )
        XCTAssertEqual(
            policy.handle(.routeChange(deviceRemoved: false), breakIsActive: false),
            .none,
            "a route change that is not oldDeviceUnavailable does not pause"
        )
        XCTAssertFalse(policy.mayAutoResume)

        _ = policy.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertEqual(
            policy.handle(.interruptionEnded(shouldResume: true), breakIsActive: false),
            .none,
            "the call ending must not release the headphone hold"
        )
        XCTAssertFalse(policy.mayAutoResume)

        policy.userPlay()
        XCTAssertTrue(policy.mayAutoResume)
        XCTAssertFalse(policy.pausedBySystem)
    }

    func testUserPauseDuringADJBreakDoesNotResume() {
        var policy = AudioSessionPolicy()
        policy.userPlay()
        XCTAssertEqual(policy.userPause(), .suspendPlayback)
        XCTAssertFalse(policy.userWantsPlayback)

        let ended = policy.handle(.interruptionEnded(shouldResume: true), breakIsActive: true)
        XCTAssertEqual(ended, .none)

        let decision = NarrationResumePolicy.decide(.cancelled, mayAutoResume: policy.mayAutoResume, phase: .voice)
        XCTAssertFalse(decision.resumeMusic)
        XCTAssertEqual(decision.audioEvent, .interludeEnded)
        guard let event = decision.audioEvent else { return XCTFail("a speaking break returns to music") }
        var machine = AudioStateMachine(state: .voice)
        XCTAssertEqual(machine.apply(event), .music)
    }

    func testFailedBreakIsAFailureNotACancel() {
        XCTAssertEqual(NarrationResumePolicy.narrationEnd(for: .failed), .failed)
        let decision = NarrationResumePolicy.decide(
            NarrationResumePolicy.narrationEnd(for: .failed),
            mayAutoResume: true,
            phase: .voice
        )
        XCTAssertEqual(decision.playbackEvent, .failed)
        XCTAssertEqual(NarrationResumePolicy.narrationEnd(for: .cancelled), .cancelled)
        XCTAssertEqual(NarrationResumePolicy.narrationEnd(for: .finished), .finished)
    }

    func testNarrationFailureWhileSuspendedStaysPaused() {
        var policy = AudioSessionPolicy()
        policy.userPlay()
        XCTAssertEqual(policy.handle(.interruptionBegan, breakIsActive: true), .suspendPlayback)

        let decision = NarrationResumePolicy.decide(.failed, mayAutoResume: policy.mayAutoResume, phase: .voice)
        XCTAssertFalse(decision.resumeMusic)
        XCTAssertEqual(decision.playbackEvent, .failed)
        XCTAssertEqual(decision.audioEvent, .interludeEnded)

        guard let event = decision.audioEvent else { return XCTFail("a failed line still leaves the voice phase") }
        var machine = AudioStateMachine(state: .voice)
        XCTAssertEqual(machine.apply(event), .music, "failure still leaves the voice phase")
        XCTAssertFalse(policy.mayAutoResume, "returning to music does not clear the call")
    }

    func testNaturalEndInterludeDoesNotResumeTheFinishedEntry() {
        let action = NarrationResumePolicy.musicAfterBreak(
            entryAlreadyFinished: true,
            mayAutoResume: true,
            queueHasEntry: true
        )
        XCTAssertEqual(
            action,
            .startNextTrack,
            "after an interlude that follows a natural end, the next track starts and the finished entry is never resumed"
        )
        let stillPlaying = NarrationResumePolicy.musicAfterBreak(
            entryAlreadyFinished: false,
            mayAutoResume: true,
            queueHasEntry: true
        )
        XCTAssertEqual(stillPlaying, .resumeCurrentEntry, "a break that did not finish the entry may resume it")
    }

    func testPlaybackResumesOnlyWhenPermitted() {
        var playing = AudioSessionPolicy()
        playing.userPlay()
        _ = playing.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertEqual(playing.handle(.interruptionEnded(shouldResume: true), breakIsActive: false), .resumeIfPermitted)

        var duringBreak = AudioSessionPolicy()
        duringBreak.userPlay()
        _ = duringBreak.handle(.interruptionBegan, breakIsActive: true)
        _ = duringBreak.handle(.interruptionEnded(shouldResume: true), breakIsActive: true)
        let afterSpeech = NarrationResumePolicy.decide(.finished, mayAutoResume: duringBreak.mayAutoResume, phase: .voice)
        XCTAssertTrue(afterSpeech.resumeMusic, "the break asks once, after speech, and only if the call allowed it")

        var denied = AudioSessionPolicy()
        denied.userPlay()
        _ = denied.handle(.interruptionBegan, breakIsActive: true)
        _ = denied.handle(.interruptionEnded(shouldResume: false), breakIsActive: true)
        let blocked = NarrationResumePolicy.decide(.finished, mayAutoResume: denied.mayAutoResume, phase: .voice)
        XCTAssertFalse(blocked.resumeMusic)

        var paused = AudioSessionPolicy()
        paused.userPlay()
        _ = paused.userPause()
        let afterPause = NarrationResumePolicy.decide(.finished, mayAutoResume: paused.mayAutoResume, phase: .voice)
        XCTAssertFalse(afterPause.resumeMusic)
    }

    func testRapidNoticesApplyInArrivalOrder() {
        var policy = AudioSessionPolicy()
        policy.userPlay()
        let notices: [AudioSessionNotice] = [
            .interruptionBegan,
            .interruptionEnded(shouldResume: true),
            .routeChange(deviceRemoved: true),
            .interruptionBegan,
            .interruptionEnded(shouldResume: true),
        ]
        var directives: [AudioSessionDirective] = []
        for notice in notices {
            directives.append(policy.handle(notice, breakIsActive: false))
        }
        XCTAssertEqual(directives, [
            .suspendPlayback,
            .resumeIfPermitted,
            .suspendPlayback,
            .suspendPlayback,
            .none,
        ])
        XCTAssertFalse(policy.mayAutoResume, "the later headphone removal still holds after the call ends")
    }

    func testCallEndingCannotClearALaterHeadphoneRemoval() {
        var forward = AudioSessionPolicy()
        forward.userPlay()
        _ = forward.handle(.interruptionBegan, breakIsActive: false)
        _ = forward.handle(.routeChange(deviceRemoved: true), breakIsActive: false)
        _ = forward.handle(.interruptionEnded(shouldResume: true), breakIsActive: false)
        XCTAssertFalse(forward.mayAutoResume)

        var reversed = AudioSessionPolicy()
        reversed.userPlay()
        _ = reversed.handle(.routeChange(deviceRemoved: true), breakIsActive: false)
        _ = reversed.handle(.interruptionBegan, breakIsActive: false)
        _ = reversed.handle(.interruptionEnded(shouldResume: true), breakIsActive: false)
        XCTAssertFalse(reversed.mayAutoResume)
    }

    func testPlayReturnRechecksAHoldThatLandedDuringPlay() {
        var policy = AudioSessionPolicy()
        policy.userPlay()
        _ = policy.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertEqual(
            PlaybackStartGuard.afterPlay(mayAutoResume: policy.mayAutoResume, userWantsPlayback: policy.userWantsPlayback),
            .pauseBecauseHeld,
            "an interruption that lands during play() must not be left playing"
        )
    }

    func testPlayReturnRechecksAUserPauseThatLandedDuringPlay() {
        var policy = AudioSessionPolicy()
        policy.userPlay()
        _ = policy.userPause()
        XCTAssertEqual(
            PlaybackStartGuard.afterPlay(mayAutoResume: policy.mayAutoResume, userWantsPlayback: policy.userWantsPlayback),
            .pauseBecauseHeld,
            "a user pause that lands during play() must not be left playing"
        )
    }

    func testReleasingTheMonitorFinishesTheStream() async {
        let stream: AsyncStream<Int> = {
            let monitor = FinishingStream<Int>()
            return monitor.stream
        }()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                _ = await iterator.next()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(finished, "releasing the monitor must finish its AsyncStream")
    }

    func testObserverRegistrationIsOnceEvenIfActivationFailed() {
        var gate = SessionRegistrationGate()
        XCTAssertTrue(gate.registerIfNeeded(), "first attempt registers even when setActive throws")
        XCTAssertFalse(gate.registerIfNeeded(), "the retry must not add a second observer")
        XCTAssertFalse(gate.registerIfNeeded())
        XCTAssertTrue(gate.isRegistered)
    }

    func testNoticeMappingMatchesTheSessionKeys() {
        XCTAssertEqual(AudioSessionNotice.interruption(began: true, shouldResume: false), .interruptionBegan)
        XCTAssertEqual(
            AudioSessionNotice.interruption(began: false, shouldResume: false),
            .interruptionEnded(shouldResume: false)
        )
        XCTAssertEqual(
            AudioSessionNotice.interruption(began: false, shouldResume: true),
            .interruptionEnded(shouldResume: true)
        )
        XCTAssertEqual(AudioSessionNotice.routeChange(deviceRemoved: true), .routeChanged(.oldDeviceUnavailable))
        XCTAssertEqual(AudioSessionNotice.routeChange(deviceRemoved: false), .routeChanged(.other))
    }
}
