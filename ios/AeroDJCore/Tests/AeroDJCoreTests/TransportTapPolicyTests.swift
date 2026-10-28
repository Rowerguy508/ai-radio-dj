import XCTest
@testable import AeroDJCore

/// Build 9 P0 double-tap rule for #120 (-Atlas; Orion approved, Nova UI, Sentinel consent).
/// A second in-app transport tap while a start is `.preparing` does nothing until the current
/// attempt's 8 s deadline is reported. After it, the button is Stop: a tap is a user pause that
/// ends the attempt, so a late `.playing` cannot start audio the user turned down.
/// Deterministic: events, status sequences and generations; no sleeps, no clocks.
final class TransportTapPolicyTests: XCTestCase {
    private let songs = [
        TrackInfo(id: "s0", title: "A", artistName: "X"),
        TrackInfo(id: "s1", title: "B", artistName: "Y"),
    ]

    private func preparingEngine() -> PlaybackEngine {
        var engine = PlaybackEngine()
        engine.apply(.queueStarted(tracks: songs, startIndex: 0, station: nil))
        return engine
    }

    /// Applies what the app applies at the 8 s deadline for `attempt`.
    private func reportDeadline(_ engine: inout PlaybackEngine, attempt: PlaybackAttemptID,
                                current: PlaybackAttemptID?) {
        for event in StartFailurePolicy.effect(.confirmDeadline(last: .paused), attempt: attempt, current: current).events {
            engine.apply(event)
        }
    }

    // MARK: Decision table

    func testDecisionTable() {
        XCTAssertEqual(TransportTapPolicy.decide(transport: .preparing, startTimedOut: false), .ignore)
        XCTAssertEqual(TransportTapPolicy.decide(transport: .preparing, startTimedOut: true), .cancelStart)
        XCTAssertEqual(TransportTapPolicy.decide(transport: .playing, startTimedOut: false), .pause)
        XCTAssertEqual(TransportTapPolicy.decide(transport: .paused, startTimedOut: false), .play)
        XCTAssertEqual(TransportTapPolicy.decide(transport: .stopped, startTimedOut: false), .play)
    }

    /// Nova: spinner only and "Starting playback" with no action until the deadline; then Stop.
    func testButtonFaceIsSpinnerUntilTheDeadlineThenStop() {
        let starting = TransportTapPolicy.face(transport: .preparing, startTimedOut: false)
        XCTAssertEqual(starting, .starting)
        XCTAssertNil(starting.systemImage, "spinner only, no stop glyph")
        XCTAssertEqual(starting.accessibilityLabel, "Starting playback")
        XCTAssertFalse(starting.isActionable)

        let stop = TransportTapPolicy.face(transport: .preparing, startTimedOut: true)
        XCTAssertEqual(stop.systemImage, "stop.fill")
        XCTAssertEqual(stop.accessibilityLabel, "Stop")
        XCTAssertTrue(stop.isActionable)

        XCTAssertEqual(TransportTapPolicy.face(transport: .playing, startTimedOut: false).accessibilityLabel, "Pause")
        XCTAssertEqual(TransportTapPolicy.face(transport: .paused, startTimedOut: false).systemImage, "play.fill")
    }

    // MARK: (a) Before the deadline: ignored, attempt untouched

    func testSecondTapWhilePreparingIsIgnoredAndTheAttemptAndWatchdogAreUntouched() {
        var attempts = PlaybackAttempts()
        let tap = attempts.beginStart()
        let generation = attempts.queueGeneration
        var engine = preparingEngine()
        var watchdog = PlaybackConfirmWatchdog(attempt: tap)
        for _ in 0..<5 {
            XCTAssertEqual(watchdog.observe(status: .paused, transportIsPreparing: true, currentAttempt: attempts.current), .keepWaiting)
        }
        XCTAssertFalse(engine.snapshot.startTimedOut)

        // The second tap: the policy says ignore, and the app does nothing else.
        XCTAssertEqual(TransportTapPolicy.decide(transport: engine.snapshot.transport,
                                                 startTimedOut: engine.snapshot.startTimedOut), .ignore)
        XCTAssertEqual(attempts.current, tap, "no new attempt")
        XCTAssertEqual(attempts.queueGeneration, generation)
        XCTAssertEqual(engine.snapshot.transport, .preparing, "no pause")

        // The same watchdog keeps its own count: 10 more reads to its deadline, then a late .playing confirms.
        var steps: [ConfirmStep] = []
        for _ in 0..<11 {
            steps.append(watchdog.observe(status: .paused, transportIsPreparing: true, currentAttempt: attempts.current))
        }
        XCTAssertEqual(Array(steps.prefix(10)), Array(repeating: .keepWaiting, count: 10))
        XCTAssertEqual(steps[10], .reportTimeoutKeepPlayer, "deadline still at the 16th read of the first tap")
        XCTAssertEqual(watchdog.observe(status: .playing, transportIsPreparing: true, currentAttempt: attempts.current), .confirmed)
        engine.apply(.playbackConfirmed)
        XCTAssertEqual(engine.snapshot.transport, .playing)
    }

    // MARK: (b) After the deadline: Stop is a user pause and a late .playing does not start

    func testDeadlineReportFlagsTheStartAndTurnsTheButtonIntoStop() {
        var attempts = PlaybackAttempts()
        let tap = attempts.beginStart()
        var engine = preparingEngine()
        reportDeadline(&engine, attempt: tap, current: attempts.current)
        XCTAssertEqual(engine.snapshot.transport, .preparing)
        XCTAssertTrue(engine.snapshot.startTimedOut)
        XCTAssertEqual(TransportTapPolicy.decide(transport: .preparing, startTimedOut: engine.snapshot.startTimedOut), .cancelStart)

        // A stale attempt's deadline does not flag the newer start.
        let second = attempts.beginStart()
        var fresh = preparingEngine()
        reportDeadline(&fresh, attempt: tap, current: attempts.current)
        XCTAssertFalse(fresh.snapshot.startTimedOut)
        reportDeadline(&fresh, attempt: second, current: attempts.current)
        XCTAssertTrue(fresh.snapshot.startTimedOut)
    }

    func testStopAfterTheDeadlineIsAUserPauseAndALatePlayingDoesNotConfirm() {
        var session = AudioSessionPolicy()
        session.userPlay()
        var attempts = PlaybackAttempts()
        let tap = attempts.beginStart()
        var engine = preparingEngine()
        var watchdog = PlaybackConfirmWatchdog(attempt: tap)
        for _ in 0..<16 {
            _ = watchdog.observe(status: .paused, transportIsPreparing: true, currentAttempt: attempts.current)
        }
        reportDeadline(&engine, attempt: tap, current: attempts.current)
        XCTAssertEqual(TransportTapPolicy.decide(transport: engine.snapshot.transport,
                                                 startTimedOut: engine.snapshot.startTimedOut), .cancelStart)

        // What `cancelTimedOutStart` does: end the attempt, user pause, `.userPaused`.
        attempts.userCancelledCurrent()
        session.userPause()
        engine.apply(.userPaused)
        XCTAssertFalse(session.userWantsPlayback, "recorded as the user's own pause")
        XCTAssertEqual(engine.snapshot.transport, .paused)
        XCTAssertEqual(engine.snapshot.hold, .user)
        XCTAssertFalse(engine.snapshot.startTimedOut)

        // MusicKit reaches .playing anyway.
        XCTAssertEqual(watchdog.observe(status: .playing, transportIsPreparing: false, currentAttempt: attempts.current),
                       .superseded, "the cancelled attempt's watchdog cannot confirm")
        XCTAssertEqual(RemotePlayGate.admit(mayAutoResume: session.mayAutoResume,
                                            userWantsPlayback: session.userWantsPlayback),
                       .pauseBecauseHeld, "the poll pauses it: the user declined")
        XCTAssertEqual(PlaybackStartGuard.afterPlay(mayAutoResume: session.mayAutoResume,
                                                    userWantsPlayback: session.userWantsPlayback),
                       .pauseBecauseHeld, "a play() still in flight is paused when it returns")
        XCTAssertFalse(attempts.isCurrent(tap))
        XCTAssertEqual(StartFailurePolicy.effect(.refused(pausedBySystem: false), attempt: tap, current: attempts.current),
                       .none, "the in-flight start's refusal changes nothing")
        engine.apply(.playbackConfirmed)
        XCTAssertEqual(engine.snapshot.transport, .paused, "a late confirm cannot claim .playing")
    }

    func testPlayingTapStillPauses() {
        var session = AudioSessionPolicy()
        session.userPlay()
        var engine = preparingEngine()
        engine.apply(.playbackConfirmed)
        XCTAssertEqual(TransportTapPolicy.decide(transport: engine.snapshot.transport,
                                                 startTimedOut: engine.snapshot.startTimedOut), .pause)
        session.userPause()
        engine.apply(.userPaused)
        XCTAssertEqual(engine.snapshot.transport, .paused)
        XCTAssertFalse(session.userWantsPlayback)
    }

    func testTimedOutFlagNeverOutlivesItsStart() {
        var engine = preparingEngine()
        engine.apply(.startConfirmTimedOut)
        XCTAssertTrue(engine.snapshot.startTimedOut)
        engine.apply(.playbackConfirmed)
        XCTAssertFalse(engine.snapshot.startTimedOut, "a late .playing clears it")

        engine = preparingEngine()
        engine.apply(.startConfirmTimedOut)
        engine.apply(.queueStarted(tracks: songs, startIndex: 0, station: nil))
        XCTAssertEqual(engine.snapshot.transport, .preparing)
        XCTAssertFalse(engine.snapshot.startTimedOut, "a new tap is a new start, before its own deadline")

        engine.apply(.startConfirmTimedOut)
        engine.apply(.userSkipped(nextIndex: 1))
        XCTAssertFalse(engine.snapshot.startTimedOut, "a skip is a new start")

        engine = preparingEngine()
        engine.apply(.playbackConfirmed)
        engine.apply(.startConfirmTimedOut)
        XCTAssertFalse(engine.snapshot.startTimedOut, "only a .preparing start can time out")
    }
}
