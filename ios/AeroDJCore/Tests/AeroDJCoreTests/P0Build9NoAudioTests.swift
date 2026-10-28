import XCTest
@testable import AeroDJCore

/// Build 9 no-audio P0 (-Atlas). Logic only: these do not prove Apple Music audio.
final class P0Build9NoAudioTests: XCTestCase {
    // MARK: #109 confirm: a slow start is not a failure

    func testPausedReadBeforeTheDeadlineKeepsWaiting() {
        for poll in 1..<PlaybackConfirmPolicy.maxPolls {
            XCTAssertEqual(PlaybackConfirmPolicy.step(status: .paused, transportIsPreparing: true, poll: poll), .keepWaiting)
            XCTAssertEqual(PlaybackConfirmPolicy.step(status: .stopped, transportIsPreparing: true, poll: poll), .keepWaiting)
        }
    }

    func testPlayingConfirmsAtAnyPoll() {
        XCTAssertEqual(PlaybackConfirmPolicy.step(status: .playing, transportIsPreparing: true, poll: 1), .confirmed)
        XCTAssertEqual(PlaybackConfirmPolicy.step(status: .playing, transportIsPreparing: true, poll: 16), .confirmed)
        XCTAssertEqual(PlaybackConfirmPolicy.step(status: .playing, transportIsPreparing: true, poll: 40), .confirmed)
    }

    /// Fry's review: the deadline reports and keeps the player; it no longer fails-and-pauses.
    func testDeadlineReportsWithoutPausing() {
        XCTAssertEqual(PlaybackConfirmPolicy.maxPolls, 16, "16 x 0.5 s is #109's 8 s deadline")
        let step = PlaybackConfirmPolicy.step(status: .paused, transportIsPreparing: true, poll: 16)
        XCTAssertEqual(step, .reportTimeoutKeepPlayer)
        XCTAssertFalse(PlaybackConfirmPolicy.pausesPlayer(step))
    }

    func testInterruptedReportsAtOnceWithoutPausing() {
        let step = PlaybackConfirmPolicy.step(status: .interrupted, transportIsPreparing: true, poll: 1)
        XCTAssertEqual(step, .failInterrupted)
        XCTAssertFalse(PlaybackConfirmPolicy.pausesPlayer(step))
    }

    func testLeavingPreparingStopsTheConfirm() {
        XCTAssertEqual(PlaybackConfirmPolicy.step(status: .paused, transportIsPreparing: false, poll: 1), .stopWaiting)
    }

    // MARK: Sentinel's lead: a tap records user intent, so the poll gate admits it

    /// `MusicKitService.play` (the tap path) calls `sessionPolicy.userPlay()` first, the same
    /// call `resume()` makes. With that, the poll's `RemotePlayGate` keeps the tapped song.
    func testTappedSongIsNotPausedByThePollGate() {
        var policy = AudioSessionPolicy()
        policy.userPlay()
        XCTAssertEqual(RemotePlayGate.admit(mayAutoResume: policy.mayAutoResume,
                                            userWantsPlayback: policy.userWantsPlayback), .keepPlaying)
        XCTAssertEqual(PlaybackStartGuard.afterPlay(mayAutoResume: policy.mayAutoResume,
                                                    userWantsPlayback: policy.userWantsPlayback), .keepPlaying)
    }

    /// A tap during a held state clears the hold, as an explicit user play must.
    func testTapAfterAnInterruptionStillPlays() {
        var policy = AudioSessionPolicy()
        policy.userPlay()
        policy.handle(.interruptionBegan, breakIsActive: false)
        policy.userPlay()
        XCTAssertEqual(RemotePlayGate.admit(mayAutoResume: policy.mayAutoResume,
                                            userWantsPlayback: policy.userWantsPlayback), .keepPlaying)
    }

    /// Without a user play (remote or system start while held), the gate still pauses.
    func testHeldOrRemoteStartIsStillGated() {
        var policy = AudioSessionPolicy()
        XCTAssertEqual(RemotePlayGate.admit(mayAutoResume: policy.mayAutoResume,
                                            userWantsPlayback: policy.userWantsPlayback), .pauseBecauseHeld)
        policy.userPlay()
        policy.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertEqual(RemotePlayGate.admit(mayAutoResume: policy.mayAutoResume,
                                            userWantsPlayback: policy.userWantsPlayback), .pauseBecauseHeld)
        policy.handle(.routeChanged(.oldDeviceUnavailable), breakIsActive: false)
        policy.handle(.interruptionEnded(shouldResume: true), breakIsActive: false)
        XCTAssertEqual(RemotePlayGate.admit(mayAutoResume: policy.mayAutoResume,
                                            userWantsPlayback: policy.userWantsPlayback), .pauseBecauseHeld)
        XCTAssertEqual(HeldStartPolicy.action(userInitiated: false), .deferSilently)
    }

    // MARK: Auto-skip chain

    /// The video's shape: each song is loaded, MusicKit says `.playing` at 0:00, then the entry
    /// goes away. None of those is a natural end, so nothing advances.
    func testFailedStartsAtZeroNeverAdvanceTheQueue() {
        var boundaries = BoundaryInterpreter()
        boundaries.userRequestedChange()
        for index in 0..<5 {
            let id = "song-\(index)"
            XCTAssertNil(boundaries.interpret(
                PlaybackObservation(entryID: id, isPlaying: true, position: 0, duration: 200),
                queueIndex: 0, queueCount: 5))
            XCTAssertNil(boundaries.interpret(
                PlaybackObservation(entryID: nil, isPlaying: false, position: 0, duration: nil),
                queueIndex: 0, queueCount: 5), "a clear at 0:00 is not a handoff")
            XCTAssertTrue(boundaries.takeNoProgressEnd())
        }
    }

    /// The app's own queue load (`startTrack` marks it) is never a natural end, even while
    /// MusicKit still reports `.playing` from the previous entry.
    func testAppQueueLoadWhilePlayingIsNotANaturalEnd() {
        var boundaries = BoundaryInterpreter()
        _ = boundaries.interpret(PlaybackObservation(entryID: "a", isPlaying: true, position: 150, duration: 200),
                                 queueIndex: 0, queueCount: 3)
        boundaries.userRequestedChange()
        XCTAssertNil(boundaries.interpret(PlaybackObservation(entryID: "b", isPlaying: true, position: 0, duration: 200),
                                          queueIndex: 1, queueCount: 3))
        XCTAssertFalse(boundaries.takeNoProgressEnd())
    }

    /// A song that really played still ends naturally when its queue clears.
    func testRealSongEndIsStillAHandoff() {
        var boundaries = BoundaryInterpreter()
        _ = boundaries.interpret(PlaybackObservation(entryID: "a", isPlaying: true, position: 0, duration: 200),
                                 queueIndex: 0, queueCount: 2)
        _ = boundaries.interpret(PlaybackObservation(entryID: "a", isPlaying: true, position: 199, duration: 200),
                                 queueIndex: 0, queueCount: 2)
        XCTAssertEqual(
            boundaries.interpret(PlaybackObservation(entryID: nil, isPlaying: false), queueIndex: 0, queueCount: 2),
            .plannedHandoff(finishedIndex: 0, nextIndex: 1, boundary: .naturalEnd(finishedEntryID: "a")))
    }

    /// A playhead reset in the last poll before the clear does not hide a song that played.
    func testPlayheadResetAtTheEndStillCountsTheSong() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(PlaybackObservation(entryID: "a", isPlaying: true, position: 120, duration: 200))
        _ = d.consume(PlaybackObservation(entryID: "a", isPlaying: true, position: 0, duration: 200))
        XCTAssertEqual(d.consume(PlaybackObservation(entryID: nil, isPlaying: false)), .queueFinished(lastEntryID: "a"))
    }

    // MARK: TEMPORARY diagnostics ring

    func testRingKeepsTheLastTenWithOffsetsFromTheTap() {
        var log = TapDiagnosticsLog(capacity: 10)
        log.record("pre", at: 1)
        XCTAssertNil(log.entries.last?.offsetMs)
        log.markTap(at: 10)
        for i in 0..<12 {
            log.record("pause.user", detail: "n=\(i)", at: 10 + Double(i) / 10)
        }
        XCTAssertEqual(log.entries.count, 10)
        XCTAssertEqual(log.entries.first?.detail, "n=2")
        XCTAssertEqual(log.entries.last?.offsetMs, 1100)
        XCTAssertEqual(log.entries.last?.tag, "pause.user")
    }

    /// Orion/Sentinel: every record says which attempt it belongs to.
    func testRingRecordsCarryTheAttemptNumber() {
        var log = TapDiagnosticsLog(capacity: 4)
        log.record("pre", at: 0)
        log.record("queue.loaded", detail: "index=0 autoplay=true", attempt: 1, at: 1)
        log.record("tapPlay.superseded", attempt: 1, at: 2)
        log.record("queue.loaded", detail: "index=0 autoplay=true", attempt: 2, at: 2)
        XCTAssertEqual(log.entries.map(\.attempt), [nil, 1, 1, 2])
    }
}
