import XCTest
@testable import AeroDJCore

/// Replays the build 10 Duo frame with an injected clock (seconds since the tap), through the
/// gate and `AudioSessionPolicy` the way `MusicKitService.applySession` does. A deferred
/// `.began` is resolved by MusicKit's state: `.playing` discards it, a failed or reported start
/// or a call applies it. -Atlas
final class SelfStartInterruptionGateTests: XCTestCase {
    private struct Rig {
        var gate = SelfStartInterruptionGate()
        var session = AudioSessionPolicy()
        var attempts = PlaybackAttempts()
        var paused = 0  // pause.forBreakOrSystem calls

        mutating func start(called: TimeInterval, returned: TimeInterval?) -> PlaybackAttemptID {
            session.userPlay()
            let a = attempts.beginStart()
            gate.startBegan(a)
            gate.playCalled(a, at: called)
            if let returned { gate.playReturned(a, at: returned) }
            return a
        }

        mutating func applyNow(_ notice: AudioSessionNotice, breakActive: Bool = false) {
            if session.handle(notice, breakIsActive: breakActive) == .suspendPlayback { paused += 1 }
        }

        @discardableResult
        mutating func deliver(_ notice: AudioSessionNotice, at t: TimeInterval,
                              call: Bool = false, breakActive: Bool = false) -> SelfStartInterruptionGate.Decision {
            let d = gate.decide(notice, at: t, current: attempts.current, callActive: call, breakActive: breakActive)
            if d == .apply { applyNow(notice, breakActive: breakActive) }
            return d
        }

        mutating func failStart(_ a: PlaybackAttemptID) {
            for n in gate.startFailed(a) { applyNow(n) }
        }

        mutating func callAppears() {
            for n in gate.flush() { applyNow(n) }
        }

        var held: Bool { !session.mayAutoResume }
        var pollGateAdmits: Bool {
            RemotePlayGate.admit(mayAutoResume: session.mayAutoResume,
                                 userWantsPlayback: session.userWantsPlayback) == .keepPlaying
        }
    }

    // MARK: The Duo frame: discarded once MusicKit plays

    // a1: setActive +18, play.returned +849, .began +888 (39 ms after the return).
    func testA1DeferredThenDiscardedWhenMusicKitPlays() {
        var r = Rig()
        let a = r.start(called: 0.018, returned: 0.849)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.888), .deferSelfStart)
        XCTAssertFalse(r.held, "no hold while deferred")
        XCTAssertEqual(r.paused, 0, "no pause.forBreakOrSystem")
        XCTAssertTrue(r.pollGateAdmits, "no pause.pollRemoteGate.held")
        XCTAssertTrue(r.gate.startConfirmed(a), "MusicKit .playing discards it")
        XCTAssertEqual(r.deliver(.interruptionEnded(shouldResume: false), at: 3.0), .ignorePairedEnd)
        XCTAssertFalse(r.held)
        XCTAssertEqual(r.paused, 0)
        XCTAssertEqual(r.deliver(.interruptionEnded(shouldResume: false), at: 4.0), .apply, "only the pair")
    }

    // a2: play.returned +7214, .began +7345 (131 ms after the return).
    func testA2DeferredThenDiscardedWhenMusicKitPlays() {
        var r = Rig()
        let a = r.start(called: 7.194, returned: 7.214)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 7.345), .deferSelfStart)
        XCTAssertFalse(r.held)
        XCTAssertEqual(r.paused, 0)
        XCTAssertTrue(r.gate.startConfirmed(a))
        XCTAssertFalse(r.held)
    }

    // MARK: Orion's P1: a real non-call interruption (Siri, alarm, another app) is never lost

    /// The system stops MusicKit for a real interruption, so `.playing` never arrives and the
    /// start reports at 8 s (or MusicKit says `.interrupted`): the `.began` is applied then.
    func testSiriShapedInterruptionIsAppliedWhenMusicKitNeverPlays() {
        var r = Rig()
        let a = r.start(called: 0.018, returned: 0.849)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.888), .deferSelfStart)
        r.failStart(a)  // 8 s report / .interrupted / throw
        XCTAssertTrue(r.held, "hold applied exactly as before")
        XCTAssertEqual(r.paused, 1)
        XCTAssertEqual(r.deliver(.interruptionEnded(shouldResume: false), at: 9.0), .apply)
        XCTAssertTrue(r.held, "shouldResume=false never auto-resumes")
    }

    func testEndedThatArrivesWhileDeferredIsAppliedAfterItsBegan() {
        var r = Rig()
        let a = r.start(called: 0.018, returned: 0.849)
        r.deliver(.interruptionBegan, at: 0.888)
        XCTAssertEqual(r.deliver(.interruptionEnded(shouldResume: true), at: 2.0), .deferSelfStart)
        r.failStart(a)
        XCTAssertEqual(r.paused, 1, "began applied")
        XCTAssertFalse(r.held, "then its shouldResume=true end, in order")
    }

    func testDeferredResolvedByMusicPlayingAfterItsEndedStaysDiscarded() {
        var r = Rig()
        let a = r.start(called: 0.018, returned: 0.849)
        r.deliver(.interruptionBegan, at: 0.888)
        r.deliver(.interruptionEnded(shouldResume: false), at: 1.0)
        XCTAssertTrue(r.gate.startConfirmed(a))
        XCTAssertEqual(r.deliver(.interruptionEnded(shouldResume: false), at: 5.0), .apply,
                       "the pair was already consumed; a later end is real")
        XCTAssertEqual(r.paused, 0)
    }

    // MARK: Calls

    func testSameTimingWithACallStillHoldsAndPauses() {
        for (returned, began) in [(0.849, 0.888), (7.214, 7.345)] {
            var r = Rig()
            _ = r.start(called: returned - 0.7, returned: returned)
            XCTAssertEqual(r.deliver(.interruptionBegan, at: began, call: true), .apply)
            XCTAssertTrue(r.held, "call-shaped interruption keeps the hold")
            XCTAssertEqual(r.paused, 1)
            XCTAssertEqual(r.deliver(.interruptionEnded(shouldResume: false), at: began + 5, call: true), .apply)
            XCTAssertTrue(r.held)
        }
    }

    func testCallThatStartsWhileDeferredAppliesTheBeganAtOnce() {
        var r = Rig()
        let a = r.start(called: 0.018, returned: 0.849)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.888), .deferSelfStart)
        r.callAppears()
        XCTAssertTrue(r.held)
        XCTAssertEqual(r.paused, 1)
        XCTAssertFalse(r.gate.startConfirmed(a), "nothing left to discard")
    }

    // MARK: Never deferred

    func testSameTimingDuringABreakStillSuspends() {
        var r = Rig()
        _ = r.start(called: 0.018, returned: 0.849)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.888, breakActive: true), .apply)
        XCTAssertTrue(r.held)
        XCTAssertEqual(r.paused, 1)
    }

    func testBeganBeforePlayReturnsIsDeferred() {
        var r = Rig()
        _ = r.start(called: 0.018, returned: nil)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.400), .deferSelfStart)
        XCTAssertFalse(r.held)
    }

    func testBeganBeforePlayIsCalledIsApplied() {
        var r = Rig()
        r.session.userPlay()
        r.gate.startBegan(r.attempts.beginStart())
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.010), .apply)
        XCTAssertTrue(r.held)
    }

    func testBeganPastTheWindowIsApplied() {
        var r = Rig()
        _ = r.start(called: 0.018, returned: 0.849)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.849 + 0.501), .apply)
        XCTAssertTrue(r.held)
        XCTAssertEqual(r.paused, 1)
    }

    func testBeganAfterTheStartConfirmedIsApplied() {
        var r = Rig()
        let a = r.start(called: 0.018, returned: 0.849)
        XCTAssertFalse(r.gate.startConfirmed(a))
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.888), .apply)
        XCTAssertTrue(r.held)
    }

    func testBeganForAStaleAttemptIsApplied() {
        var r = Rig()
        _ = r.start(called: 0.018, returned: 0.849)
        _ = r.attempts.beginStart()  // a newer start the gate never saw begin
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.888), .apply)
        XCTAssertTrue(r.held)
    }

    func testSecondBeganWhileOneIsDeferredIsApplied() {
        var r = Rig()
        _ = r.start(called: 0.018, returned: 0.849)
        r.deliver(.interruptionBegan, at: 0.888)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.950), .apply)
        XCTAssertTrue(r.held)
    }

    func testRouteLossIsNeverDeferred() {
        var r = Rig()
        _ = r.start(called: 0.018, returned: 0.849)
        XCTAssertEqual(r.deliver(.routeChanged(.oldDeviceUnavailable), at: 0.888), .apply)
        XCTAssertEqual(r.paused, 1)
    }

    /// A user tap while a `.began` is deferred: the tap clears system holds anyway, so the
    /// deferred one is dropped and its end is ignored once.
    func testNewUserStartDropsTheDeferredBegan() {
        var r = Rig()
        _ = r.start(called: 0.018, returned: 0.849)
        r.deliver(.interruptionBegan, at: 0.888)
        _ = r.start(called: 2.0, returned: 2.5)
        XCTAssertFalse(r.held)
        XCTAssertEqual(r.deliver(.interruptionEnded(shouldResume: false), at: 3.0), .ignorePairedEnd)
        XCTAssertFalse(r.held)
    }
}
