import XCTest
@testable import AeroDJCore

/// Replays the build 10 Duo frame with an injected clock (seconds since the tap), through the
/// gate and `AudioSessionPolicy` the way `MusicKitService.applySession` does. -Atlas
final class SelfStartInterruptionGateTests: XCTestCase {
    private struct Rig {
        var gate = SelfStartInterruptionGate()
        var session = AudioSessionPolicy()
        var attempts = PlaybackAttempts()
        var paused = 0  // pause.forBreakOrSystem calls

        /// tap -> attempt.begin -> play() called -> play.returned
        mutating func start(begin: TimeInterval, called: TimeInterval, returned: TimeInterval) -> PlaybackAttemptID {
            session.userPlay()
            let a = attempts.beginStart()
            gate.startBegan(a)
            gate.playCalled(a, at: called)
            gate.playReturned(a, at: returned)
            return a
        }

        @discardableResult
        mutating func deliver(_ notice: AudioSessionNotice, at t: TimeInterval,
                              call: Bool = false, breakActive: Bool = false) -> SelfStartInterruptionGate.Decision {
            let d = gate.decide(notice, at: t, current: attempts.current, callActive: call, breakActive: breakActive)
            guard d == .apply else { return d }
            if session.handle(notice, breakIsActive: breakActive) == .suspendPlayback { paused += 1 }
            return d
        }

        var held: Bool { !session.mayAutoResume }
    }

    // a1: setActive +18, play.returned +849, .began +888 (39 ms after the return).
    func testA1BeganThirtyNineMsAfterPlayReturnsIsIgnoredWithNoCall() {
        var r = Rig()
        _ = r.start(begin: 0.000, called: 0.018, returned: 0.849)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.888), .ignoreSelfStart)
        XCTAssertFalse(r.held, "no hold")
        XCTAssertEqual(r.paused, 0, "no pause.forBreakOrSystem")
        XCTAssertEqual(PlaybackStartGuard.afterPlay(mayAutoResume: r.session.mayAutoResume,
                                                    userWantsPlayback: r.session.userWantsPlayback), .keepPlaying)
        XCTAssertEqual(RemotePlayGate.admit(mayAutoResume: r.session.mayAutoResume,
                                            userWantsPlayback: r.session.userWantsPlayback), .keepPlaying,
                       "no pause.pollRemoteGate.held")
    }

    // a2: play.returned +7214, .began +7345 (131 ms after the return).
    func testA2BeganOneHundredThirtyOneMsAfterPlayReturnsIsIgnoredWithNoCall() {
        var r = Rig()
        _ = r.start(begin: 7.148, called: 7.194, returned: 7.214)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 7.345), .ignoreSelfStart)
        XCTAssertFalse(r.held)
        XCTAssertEqual(r.paused, 0)
    }

    func testSameTimingWithACallStillHoldsAndPauses() {
        for (returned, began) in [(0.849, 0.888), (7.214, 7.345)] {
            var r = Rig()
            _ = r.start(begin: returned - 0.8, called: returned - 0.7, returned: returned)
            XCTAssertEqual(r.deliver(.interruptionBegan, at: began, call: true), .apply)
            XCTAssertTrue(r.held, "call-shaped interruption keeps the hold")
            XCTAssertEqual(r.paused, 1)
            XCTAssertEqual(r.deliver(.interruptionEnded(shouldResume: false), at: began + 5, call: true), .apply)
            XCTAssertTrue(r.held, "shouldResume=false after a call never auto-resumes")
        }
    }

    func testSameTimingDuringABreakStillSuspends() {
        var r = Rig()
        _ = r.start(begin: 0, called: 0.018, returned: 0.849)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.888, breakActive: true), .apply)
        XCTAssertTrue(r.held)
        XCTAssertEqual(r.paused, 1)
    }

    func testBeganBeforePlayReturnsIsIgnored() {
        var r = Rig()
        let a = r.attempts.beginStart()
        r.session.userPlay()
        r.gate.startBegan(a)
        r.gate.playCalled(a, at: 0.018)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.400), .ignoreSelfStart)
        XCTAssertFalse(r.held)
    }

    func testBeganBeforePlayIsCalledIsApplied() {
        var r = Rig()
        let a = r.attempts.beginStart()
        r.session.userPlay()
        r.gate.startBegan(a)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.010), .apply)
        XCTAssertTrue(r.held)
    }

    func testBeganPastTheWindowIsApplied() {
        var r = Rig()
        _ = r.start(begin: 0, called: 0.018, returned: 0.849)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.849 + 0.501), .apply)
        XCTAssertTrue(r.held)
        XCTAssertEqual(r.paused, 1)
    }

    func testBeganAfterTheStartSettledIsApplied() {
        var r = Rig()
        let a = r.start(begin: 0, called: 0.018, returned: 0.849)
        r.gate.startSettled(a)  // confirmed .playing (or the 8 s report)
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.888), .apply)
        XCTAssertTrue(r.held)
    }

    func testBeganForAStaleAttemptIsApplied() {
        var r = Rig()
        _ = r.start(begin: 0, called: 0.018, returned: 0.849)
        _ = r.attempts.beginStart()  // a newer start the gate never saw begin
        XCTAssertEqual(r.deliver(.interruptionBegan, at: 0.888), .apply)
        XCTAssertTrue(r.held)
    }

    func testEndedPairedWithAnIgnoredBeganIsIgnoredOnce() {
        var r = Rig()
        _ = r.start(begin: 0, called: 0.018, returned: 0.849)
        r.deliver(.interruptionBegan, at: 0.888)
        XCTAssertEqual(r.deliver(.interruptionEnded(shouldResume: false), at: 3.0), .ignoreSelfStart)
        XCTAssertFalse(r.held)
        XCTAssertEqual(r.deliver(.interruptionEnded(shouldResume: false), at: 4.0), .apply, "only the pair")
    }

    func testRouteLossIsNeverIgnored() {
        var r = Rig()
        _ = r.start(begin: 0, called: 0.018, returned: 0.849)
        XCTAssertEqual(r.deliver(.routeChanged(.oldDeviceUnavailable), at: 0.888), .apply)
        XCTAssertEqual(r.paused, 1)
    }
}
