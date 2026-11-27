import XCTest
@testable import AeroDJCore

/// #146 (-Fry): song 1's last playing poll lands outside the 1.5 s end window (197.9 s of a 200 s
/// song), then MusicKit keeps the entry, stops it and rewinds it to 0. That is still the end of
/// song 1: exactly one `queueFinished`, and through the interpreter exactly one handoff to song 2.
/// The end window is not widened for this: the rewind is judged by the sticky played-through fact
/// (furthest position past 90%), so a pause or stop outside the window is still never an end.
/// Linux unit tests only; NOT device evidence.
final class LatePollQueueEndTests: XCTestCase {
    private let duration: TimeInterval = 200
    private let lastPoll: TimeInterval = 197.9

    private func playing(_ position: TimeInterval, uptime: TimeInterval? = nil) -> PlaybackObservation {
        PlaybackObservation(entryID: "a", isPlaying: true, position: position, duration: duration,
                            uptime: uptime ?? position)
    }

    private func stopped(_ position: TimeInterval, uptime: TimeInterval) -> PlaybackObservation {
        PlaybackObservation(entryID: "a", isPlaying: false, position: position, duration: duration, uptime: uptime)
    }

    /// Plays "a" from 0 on 1 s polls up to 197 s, then one last playing poll at `last`.
    private func playedTo(_ last: TimeInterval) -> PlaybackBoundaryDetector {
        var d = PlaybackBoundaryDetector()
        d.userRequestedChange()
        for t in stride(from: 0.0, through: 197.0, by: 1.0) where t < last {
            XCTAssertNil(d.consume(playing(t)))
        }
        XCTAssertNil(d.consume(playing(last)))
        return d
    }

    // MARK: - The end, from outside the window

    func testLastPollIsOutsideTheEndWindow() {
        XCTAssertFalse(playing(lastPoll).isNearEnd(), "the premise of #146: 197.9 is outside the window")
    }

    func testRewoundAfterLastPollOutsideWindowFinishesOnce() {
        var d = playedTo(lastPoll)
        XCTAssertEqual(d.consume(stopped(0, uptime: 199)), .queueFinished(lastEntryID: "a"))
        XCTAssertNil(d.consume(stopped(0, uptime: 200)), "advance once")
        XCTAssertNil(d.consume(stopped(0, uptime: 201)))
        XCTAssertFalse(d.takeRemoteSkip(), "the end of song 1 is not a lock-screen skip")
        XCTAssertFalse(d.takeNoProgressEnd())
    }

    /// The stopped sample arrives late (the app was busy or suspended): still one end.
    func testDelayedRewoundPollFinishesOnce() {
        var d = playedTo(lastPoll)
        XCTAssertEqual(d.consume(stopped(0, uptime: 206.5)), .queueFinished(lastEntryID: "a"))
        XCTAssertNil(d.consume(stopped(0, uptime: 207.5)))
        XCTAssertFalse(d.takeRemoteSkip())
    }

    /// No uptimes from the caller at all: the furthest position alone carries it.
    func testRewoundWithoutUptimesFinishesOnce() {
        var d = PlaybackBoundaryDetector()
        d.userRequestedChange()
        for t in stride(from: 0.0, through: 197.0, by: 1.0) {
            XCTAssertNil(d.consume(.init(entryID: "a", isPlaying: true, position: t, duration: duration)))
        }
        XCTAssertNil(d.consume(.init(entryID: "a", isPlaying: true, position: lastPoll, duration: duration)))
        XCTAssertEqual(d.consume(.init(entryID: "a", isPlaying: false, position: 0, duration: duration)),
                       .queueFinished(lastEntryID: "a"))
    }

    /// Through the real interpreter: one planned handoff from song 1 to song 2.
    func testInterpreterHandsOffToSong2Once() {
        var interpreter = BoundaryInterpreter()
        interpreter.userRequestedChange()
        var steps: [BoundaryStep] = []
        var samples = stride(from: 0.0, through: 197.0, by: 1.0).map { playing($0) }
        samples += [playing(lastPoll), stopped(0, uptime: 199), stopped(0, uptime: 200)]
        for s in samples {
            if let step = interpreter.interpret(s, queueIndex: 0, queueCount: 3) { steps.append(step) }
        }
        // The interpreter reports a planned handoff as a natural end of song 1 (as SongEndAdvanceTests).
        XCTAssertEqual(steps, [.plannedHandoff(finishedIndex: 0, nextIndex: 1,
                                               boundary: .naturalEnd(finishedEntryID: "a"))])
    }

    // MARK: - Never an end

    func testUserPauseAtLastPollThenRewindIsNotAnEnd() {
        var d = playedTo(lastPoll)
        d.pausedByApp(.userPause)
        XCTAssertNil(d.consume(stopped(lastPoll, uptime: 198.5)))
        XCTAssertNil(d.consume(stopped(0, uptime: 199.5)))
        XCTAssertNil(d.consume(stopped(0, uptime: 200.5)))
    }

    func testRouteLossAtLastPollThenRewindIsNotAnEnd() {
        var d = playedTo(lastPoll)
        d.pausedByApp(.routeLoss)
        XCTAssertNil(d.consume(stopped(lastPoll, uptime: 198.5)))
        XCTAssertNil(d.consume(stopped(0, uptime: 199.5)))
    }

    /// A system interruption that pauses the song at 197.9 (playhead kept, outside the window).
    func testInterruptionPauseOutsideWindowIsNotAnEnd() {
        var d = playedTo(lastPoll)
        d.pausedByApp(.systemInterruption)
        XCTAssertNil(d.consume(stopped(lastPoll, uptime: 198.5)))
        XCTAssertNil(d.consume(stopped(lastPoll, uptime: 210)))
    }

    /// A mid-song interruption, even if the playhead later reads 0, is not an end.
    func testMidSongInterruptionThenRewindIsNotAnEnd() {
        var d = playedTo(100)
        d.pausedByApp(.systemInterruption)
        XCTAssertNil(d.consume(stopped(0, uptime: 101)))
    }

    /// A plain stop that keeps the playhead at 197.9 is ambiguous with a pause or stall: not an end.
    func testStopOutsideWindowWithoutRewindIsNotAnEnd() {
        var d = playedTo(lastPoll)
        XCTAssertNil(d.consume(stopped(lastPoll, uptime: 198.9)))
    }

    /// The user seeks back to 0 at 197.9 and replays: the replay is not an end, and a later
    /// mid-song stop is not one either.
    func testSeekReplayIsNotAnEnd() {
        var d = playedTo(lastPoll)
        d.userSeeked(to: 0, uptime: 198)
        XCTAssertNil(d.consume(stopped(lastPoll, uptime: 198.2)), "stale pre-seek stop in the settle window")
        for t in stride(from: 0.0, through: 20.0, by: 1.0) {
            XCTAssertNil(d.consume(playing(t, uptime: 199.6 + t)))
        }
        XCTAssertNil(d.consume(stopped(20, uptime: 221)))
        XCTAssertNil(d.consume(stopped(0, uptime: 222)))
    }

    /// The song restarts from 0 with no seek event (repeat-one style) and keeps playing: the
    /// restart resets the furthest position, so a later mid-song stop is not an end.
    func testReplayWithoutSeekIsNotAnEnd() {
        var d = playedTo(lastPoll)
        for t in stride(from: 0.0, through: 30.0, by: 1.0) {
            XCTAssertNil(d.consume(playing(t, uptime: 199 + t)))
        }
        XCTAssertNil(d.consume(stopped(30.4, uptime: 230.5)))
        XCTAssertNil(d.consume(stopped(30.4, uptime: 231.5)))
        // Atlas's #633 nit: MusicKit may also rewind the stopped replay to 0. The restart reset
        // the furthest position, so that rewind is not song 1's end either.
        XCTAssertNil(d.consume(stopped(0, uptime: 232.5)), "rewind to 0 after a restart is not an end")
        XCTAssertNil(d.consume(stopped(0, uptime: 233.5)))
    }

    /// Atlas's #674 case: after the replay to 30, MusicKit stops and rewinds in one poll, so
    /// `stopped(0)` is the first stopped sample. The restart reset the furthest position (no
    /// longer the pre-restart 197.9), so this rewind is not song 1's end.
    func testReplayThenStopAndRewindInOnePollIsNotAnEnd() {
        var d = playedTo(lastPoll)
        for t in stride(from: 0.0, through: 30.0, by: 1.0) {
            XCTAssertNil(d.consume(playing(t, uptime: 199 + t)))
        }
        XCTAssertNil(d.consume(stopped(0, uptime: 230.5)), "rewind to 0 after a restart is not an end")
        XCTAssertNil(d.consume(stopped(0, uptime: 231.5)))
    }
}
