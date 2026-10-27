import XCTest
@testable import AeroDJCore

final class PlaybackEngineTests: XCTestCase {
    private func track(_ n: Int) -> TrackInfo {
        TrackInfo(id: "t\(n)", title: "Song \(n)", artistName: "Artist \(n)")
    }
    private var queue: [TrackInfo] { (1...3).map(track) }
    private let station = StationRef(id: "morning-calm", name: "Morning Calm")

    private func started() -> PlaybackEngine {
        var e = PlaybackEngine()
        e.apply(.queueStarted(tracks: queue, startIndex: 0, station: station))
        e.apply(.playbackConfirmed)
        return e
    }

    func testQueueStartShowsPreparingUntilMusicKitConfirms() {
        var e = PlaybackEngine()
        e.apply(.queueStarted(tracks: queue, startIndex: 0, station: station))
        XCTAssertEqual(e.snapshot.nowPlaying, track(1))
        XCTAssertEqual(e.snapshot.upNext, [track(2), track(3)])
        XCTAssertEqual(e.snapshot.transport, .preparing)
        e.apply(.playbackConfirmed)
        XCTAssertEqual(e.snapshot.transport, .playing)
        XCTAssertEqual(e.snapshot.dj, .idle)
    }

    func testQueueStartShowsFirstTrackAndUpNext() {
        let e = started()
        XCTAssertEqual(e.snapshot.nowPlaying, track(1))
        XCTAssertEqual(e.snapshot.upNext, [track(2), track(3)])
        XCTAssertEqual(e.snapshot.transport, .playing)
        XCTAssertEqual(e.snapshot.dj, .idle)
    }

    func testNaturalBoundaryAdvancesWithoutTouchingDJ() {
        var e = started()
        e.apply(.naturalBoundary(nextIndex: 1))
        XCTAssertEqual(e.snapshot.nowPlaying, track(2))
        XCTAssertEqual(e.snapshot.upNext, [track(3)])
        XCTAssertEqual(e.snapshot.transport, .playing)
    }

    func testDJBreakKeepsShowPlayingAndSpeakingState() {
        var e = started()
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.djStarted(line: "Up next, song two."))
        XCTAssertEqual(e.snapshot.dj, .speaking(line: "Up next, song two."))
        XCTAssertEqual(e.snapshot.transport, .playing, "a break is not a stop")
        e.apply(.djFinished)
        XCTAssertEqual(e.snapshot.dj, .idle)
        XCTAssertEqual(e.snapshot.nowPlaying, track(2))
    }

    func testCancelledBreakReturnsToIdleAndKeepsPlaying() {
        var e = started()
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.djStarted(line: "Up next."))
        e.apply(.djCancelled)
        XCTAssertEqual(e.snapshot.dj, .idle)
        XCTAssertEqual(e.snapshot.transport, .playing)
        XCTAssertNil(e.snapshot.error, "a cancelled break is not an error")
    }

    func testFailedSpeechIsRecoverableAndShowContinues() {
        var e = started()
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.djFailed(message: "Voice unavailable"))
        XCTAssertEqual(e.snapshot.dj, .idle)
        XCTAssertEqual(e.snapshot.transport, .playing)
        XCTAssertEqual(e.snapshot.error, PlaybackError(kind: .speechFailed, message: "Voice unavailable", isRecoverable: true))
        e.apply(.errorCleared)
        XCTAssertNil(e.snapshot.error)
    }

    func testBoundaryPastEndStopsCleanly() {
        var e = started()
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.naturalBoundary(nextIndex: 2))
        e.apply(.naturalBoundary(nextIndex: 3))
        XCTAssertNil(e.snapshot.nowPlaying)
        XCTAssertEqual(e.snapshot.upNext, [])
        XCTAssertEqual(e.snapshot.transport, .stopped)
    }

    func testUserSkipMovesPositionWithoutDJ() {
        var e = started()
        e.apply(.userSkipped(nextIndex: 1))
        XCTAssertEqual(e.snapshot.nowPlaying, track(2))
        XCTAssertEqual(e.snapshot.dj, .idle)
    }

    func testInterruptionIsNotLabeledAsAUserPause() {
        var engine = started()
        let snap = engine.apply(.interruptionPaused)
        XCTAssertEqual(snap.transport, .paused)
        XCTAssertEqual(snap.hold, .interruption)
        XCTAssertEqual(snap.hold?.caption, "Paused for an interruption")
    }

    func testRouteLossIsNotLabeledAsAUserPause() {
        var engine = started()
        let snap = engine.apply(.routePaused)
        XCTAssertEqual(snap.transport, .paused)
        XCTAssertEqual(snap.hold, .routeRemoved)
        XCTAssertEqual(snap.hold?.caption, "Paused because the audio route was removed")
    }

    func testPauseAndResumeKeepPosition() {
        var e = started()
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.userPaused)
        XCTAssertEqual(e.snapshot.transport, .paused)
        XCTAssertEqual(e.snapshot.hold, .user)
        XCTAssertNil(e.snapshot.hold?.caption, "a user pause has no extra caption")
        XCTAssertEqual(e.snapshot.nowPlaying, track(2))
        e.apply(.userResumed)
        XCTAssertEqual(e.snapshot.transport, .preparing)
        XCTAssertNil(e.snapshot.hold)
        XCTAssertEqual(e.snapshot.nowPlaying, track(2))
        e.apply(.playbackConfirmed)
        XCTAssertEqual(e.snapshot.transport, .playing)
    }

    func testPauseBeforeStartIsIgnored() {
        var e = PlaybackEngine()
        e.apply(.userPaused)
        XCTAssertEqual(e.snapshot.transport, .stopped)
    }

    func testStartIndexIsClamped() {
        var e = PlaybackEngine()
        e.apply(.queueStarted(tracks: queue, startIndex: 99, station: nil))
        XCTAssertEqual(e.snapshot.nowPlaying, track(3))
        XCTAssertEqual(e.snapshot.upNext, [])
    }

    func testEmptyQueueIsStopped() {
        var e = PlaybackEngine()
        e.apply(.queueStarted(tracks: [], startIndex: 0, station: nil))
        XCTAssertEqual(e.snapshot.transport, .stopped)
        XCTAssertNil(e.snapshot.nowPlaying)
    }

    func testErrorSurvivesQueueChanges() {
        var e = started()
        e.apply(.errorRaised(PlaybackError(kind: .resumeFailed, message: "Resume failed", isRecoverable: true)))
        e.apply(.naturalBoundary(nextIndex: 1))
        XCTAssertEqual(e.snapshot.error?.kind, .resumeFailed)
    }

    func testSameEventsGiveSameSnapshots() {
        let events: [PlaybackEvent] = [
            .queueStarted(tracks: queue, startIndex: 0, station: nil), .naturalBoundary(nextIndex: 1),
            .djStarted(line: "x"), .djCancelled, .userPaused, .userResumed, .userSkipped(nextIndex: 2),
        ]
        var a = PlaybackEngine(), b = PlaybackEngine()
        for event in events {
            XCTAssertEqual(a.apply(event), b.apply(event))
        }
    }

    func testStationSurvivesBreaksAndSkipsButClearsOnQueueEnd() {
        var e = started()
        XCTAssertEqual(e.snapshot.station, station)
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.djStarted(line: "x"))
        e.apply(.djFinished)
        e.apply(.userSkipped(nextIndex: 2))
        XCTAssertEqual(e.snapshot.station, station, "a break or skip never changes the station")
        e.apply(.queueFinished)
        XCTAssertEqual(e.snapshot.station, station, "the station stays selected after the queue ends")
        XCTAssertEqual(e.snapshot.transport, .stopped)
    }

    func testStartingAnotherStationReplacesTheQueueNotTheSession() {
        var e = started()
        let other = StationRef(id: "late-night", name: "Late Night")
        e.apply(.queueStarted(tracks: [track(9)], startIndex: 0, station: other))
        XCTAssertEqual(e.snapshot.station, other)
        XCTAssertEqual(e.snapshot.nowPlaying, track(9))
        XCTAssertEqual(e.snapshot.upNext, [])
    }

    /// An unreadable or unprepared line skips the break; the next song must still
    /// start and play, with no DJ state left behind.
    func testSkippedBreakDoesNotStopTheNextSong() {
        var e = started()
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.djFailed(message: "A DJ line was not prepared and was skipped."))
        XCTAssertEqual(e.snapshot.dj, .idle)
        XCTAssertEqual(e.snapshot.transport, .playing)

        e.apply(.naturalBoundary(nextIndex: 2))
        XCTAssertEqual(e.snapshot.nowPlaying, track(3))
        XCTAssertEqual(e.snapshot.transport, .playing)
        XCTAssertEqual(e.snapshot.dj, .idle)
    }
}
