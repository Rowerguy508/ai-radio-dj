import XCTest
@testable import AeroDJCore

/// Orion P1 on #125 (-Atlas): deferred notices are scoped to the attempt they came from.
/// `Harness` wires the same Core pieces `MusicKitService` uses (attempts, gate, policy, replay)
/// and models the one hop that remains, a scheduled resume, as an explicit queue the test runs
/// whenever it chooses, so every interleaving is deterministic.
final class DeferredInterruptionReplayTests: XCTestCase {

    private struct Harness {
        var attempts = PlaybackAttempts()
        var gate = SelfStartInterruptionGate()
        var policy = AudioSessionPolicy()
        var callActive = false
        var breakActive = false
        /// Which attempt the player is playing, if any. A suspend clears it.
        var playing: PlaybackAttemptID?
        var pauses: [PlaybackAttemptID?] = []
        var resumesStarted: [PlaybackAttemptID] = []
        var scheduledResumes: [DeferredInterruptionReplay.ResumeTicket] = []
        var now: TimeInterval = 100

        /// A user tap: new attempt, play() called and returned at `now`.
        mutating func start() -> PlaybackAttemptID {
            policy.userPlay()
            let a = attempts.beginStart()
            gate.startBegan(a)
            gate.playCalled(a, at: now)
            gate.playReturned(a, at: now)
            return a
        }

        mutating func confirmPlaying(_ a: PlaybackAttemptID) {
            guard attempts.isCurrent(a) else { return }
            _ = gate.startConfirmed(a)
            playing = a
        }

        /// The live path for a notice.
        mutating func notice(_ n: AudioSessionNotice) {
            switch gate.decide(n, at: now, current: attempts.current, callActive: callActive, breakActive: breakActive) {
            case .deferSelfStart, .ignorePairedEnd: return
            case .apply:
                let d = policy.handle(n, breakIsActive: breakActive)
                if d == .suspendPlayback { suspend() }
                if d == .resumeIfPermitted, let cur = attempts.current {
                    scheduledResumes.append(.init(origin: cur))
                }
            }
        }

        /// `applyDeferredInterruptions`: synchronous steps, resume via ticket.
        mutating func applyDeferred(_ notices: [AudioSessionNotice]) {
            guard !notices.isEmpty else { return }
            let replay = DeferredInterruptionReplay.run(notices, origin: attempts.current,
                                                        policy: &policy, breakIsActive: breakActive)
            for step in replay.steps where step.directive == .suspendPlayback { suspend() }
            if let t = replay.resume { scheduledResumes.append(t) }
        }

        mutating func startFailed(_ a: PlaybackAttemptID) { applyDeferred(gate.startFailed(a)) }
        mutating func callAppeared() { callActive = true; applyDeferred(gate.flush()) }

        mutating func suspend() { pauses.append(playing); playing = nil }

        /// The scheduled Task runs (after any interleaving the test chose).
        mutating func runScheduledResumes() {
            let tickets = scheduledResumes
            scheduledResumes = []
            for t in tickets where t.mayResume(current: attempts.current, callActive: callActive, policy: policy) {
                let a = start()
                resumesStarted.append(a)
                playing = a
            }
        }
    }

    // MARK: - Replay unit

    func testStepsKeepArrivalOrderAndALaterSuspendCancelsAnEarlierResume() {
        var policy = AudioSessionPolicy()
        policy.userPlay()
        let a = PlaybackAttempts().current ?? PlaybackAttemptID(number: 1)
        let r = DeferredInterruptionReplay.run(
            [.interruptionBegan, .interruptionEnded(shouldResume: true), .interruptionBegan],
            origin: a, policy: &policy, breakIsActive: false)
        XCTAssertEqual(r.steps.map(\.directive), [.suspendPlayback, .resumeIfPermitted, .suspendPlayback])
        XCTAssertNil(r.resume, "the final suspend wins; nothing resumes")
        XCTAssertTrue(policy.pausedBySystem)
    }

    func testResumeTicketOnlyForOriginAttempt() {
        var policy = AudioSessionPolicy()
        policy.userPlay()
        var attempts = PlaybackAttempts()
        let a = attempts.beginStart()
        let r = DeferredInterruptionReplay.run([.interruptionBegan, .interruptionEnded(shouldResume: true)],
                                               origin: a, policy: &policy, breakIsActive: false)
        XCTAssertEqual(r.resume, .init(origin: a))
        XCTAssertTrue(r.resume!.mayResume(current: a, callActive: false, policy: policy))
        let b = attempts.beginStart()
        XCTAssertFalse(r.resume!.mayResume(current: b, callActive: false, policy: policy))
        XCTAssertFalse(r.resume!.mayResume(current: nil, callActive: false, policy: policy))
        XCTAssertFalse(r.resume!.mayResume(current: a, callActive: true, policy: policy))
    }

    // MARK: - Orion's interleavings

    /// A defers, the flush is triggered, B starts, the scheduled part runs: B keeps playing.
    func testADefersFlushThenBStartsBKeepsPlaying() {
        var h = Harness()
        let a = h.start()
        h.notice(.interruptionBegan)                       // A's self-start .began: deferred
        XCTAssertTrue(h.gate.hasDeferred)
        h.startFailed(a)                                   // flush: the suspend applies now, to A
        XCTAssertEqual(h.pauses, [nil], "A's .began paused A synchronously (A was not yet playing)")
        let b = h.start()
        h.confirmPlaying(b)
        h.runScheduledResumes()                            // whatever was scheduled runs now
        XCTAssertEqual(h.playing, b, "B keeps playing")
        XCTAssertEqual(h.pauses.count, 1, "nothing from A paused B")
        XCTAssertTrue(h.resumesStarted.isEmpty)
    }

    /// Paired `.ended` deferred with A: its resume must not run once B has started.
    func testPairedEndedFromADoesNotResumeAfterBStarts() {
        var h = Harness()
        let a = h.start()
        h.notice(.interruptionBegan)
        h.notice(.interruptionEnded(shouldResume: true))   // queued with the .began
        h.startFailed(a)
        XCTAssertEqual(h.scheduledResumes, [.init(origin: a)])
        let b = h.start()
        h.confirmPlaying(b)
        h.runScheduledResumes()
        XCTAssertTrue(h.resumesStarted.isEmpty, "A's .ended never resumes after B")
        XCTAssertEqual(h.playing, b)
        XCTAssertEqual(h.attempts.current, b, "no extra attempt superseded B")
    }

    /// Same pair with no new start: A's own resume still runs (nothing was dropped).
    func testPairedEndedResumesWhenOriginIsStillCurrent() {
        var h = Harness()
        let a = h.start()
        h.notice(.interruptionBegan)
        h.notice(.interruptionEnded(shouldResume: true))
        h.startFailed(a)
        h.runScheduledResumes()
        XCTAssertEqual(h.resumesStarted.count, 1)
    }

    /// A call while A's `.began` is deferred: the hold applies at once, and a later resume
    /// ticket is refused while the call is up.
    func testCallActivatingAppliesTheHoldToTheCurrentAttemptAtOnce() {
        var h = Harness()
        let a = h.start()
        h.confirmPlaying(a)                                // e.g. audible; deferral still pending
        h.gate = SelfStartInterruptionGate(); h.gate.startBegan(a)
        h.gate.playCalled(a, at: h.now); h.gate.playReturned(a, at: h.now)
        h.notice(.interruptionBegan)
        XCTAssertTrue(h.gate.hasDeferred)
        h.callAppeared()
        XCTAssertNil(h.playing, "the call's hold paused the current attempt synchronously")
        XCTAssertTrue(h.policy.pausedBySystem)
        h.notice(.interruptionEnded(shouldResume: true))   // live path, call still up
        h.runScheduledResumes()
        XCTAssertNil(h.playing, "no resume while a call is active")
    }

    /// Route loss is never deferred and holds across a replayed `.ended`.
    func testRouteHoldSurvivesAReplayedEnded() {
        var h = Harness()
        let a = h.start()
        h.notice(.interruptionBegan)
        h.notice(.routeChanged(.oldDeviceUnavailable))     // applied immediately
        XCTAssertEqual(h.pauses.count, 1)
        h.notice(.interruptionEnded(shouldResume: true))
        h.startFailed(a)
        XCTAssertNil(h.scheduledResumes.first, "route hold: the policy gives no resume")
        h.runScheduledResumes()
        XCTAssertTrue(h.resumesStarted.isEmpty)
        XCTAssertTrue(h.policy.pausedBySystem)
    }

    /// The user's pause (consent to play withdrawn) between flush and the scheduled resume wins.
    func testUserPauseBeforeScheduledResumeRunsWins() {
        var h = Harness()
        let a = h.start()
        h.notice(.interruptionBegan)
        h.notice(.interruptionEnded(shouldResume: true))
        h.startFailed(a)
        XCTAssertEqual(h.scheduledResumes.count, 1)
        h.policy.userPause()
        h.runScheduledResumes()
        XCTAssertTrue(h.resumesStarted.isEmpty, "a user pause is never undone by a replay")
    }

    /// A deferred `.began` that B's start dropped is never replayed: no flush can reach B.
    func testNewStartDropsDeferredSoALaterFlushIsEmpty() {
        var h = Harness()
        _ = h.start()
        h.notice(.interruptionBegan)
        let b = h.start()
        h.confirmPlaying(b)
        h.callActive = false
        h.applyDeferred(h.gate.flush())
        XCTAssertEqual(h.playing, b)
        XCTAssertTrue(h.pauses.isEmpty)
    }
}
