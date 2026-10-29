import XCTest
@testable import AeroDJCore

/// Build 21 P0 (-Atlas): owner trace on a 2.4 s catalog track. Polls are 1 s apart, so the
/// furthest playing sample was 1.6 s (end window, not 90%), then MusicKit rewound the finished
/// one-song queue to 0, paused. Nothing reported the end, so the station stalled at song 1.
final class ShortTrackEndTests: XCTestCase {
    private let handoff = BoundaryStep.plannedHandoff(finishedIndex: 0, nextIndex: 1,
                                                      boundary: .naturalEnd(finishedEntryID: "e0"))

    private func obs(_ entry: String? = "e0", playing: Bool, _ position: Double, _ duration: Double,
                     _ uptime: Double) -> PlaybackObservation {
        PlaybackObservation(entryID: entry, isPlaying: playing, position: position, duration: duration, uptime: uptime)
    }

    /// The tap, then the trace rows from 18.3 on.
    private func startedShortTrack(_ i: inout BoundaryInterpreter, duration: Double = 2.4) -> [BoundaryStep?] {
        i.userRequestedChange()
        return [i.interpret(obs(playing: true, 0.6, duration, 18.3), queueIndex: 0, queueCount: 20),
                i.interpret(obs(playing: true, 1.6, duration, 19.3), queueIndex: 0, queueCount: 20)]
    }

    func testOwnerTraceRewindAfterReachingEndWindowAdvancesOnce() {
        var i = BoundaryInterpreter()
        XCTAssertEqual(startedShortTrack(&i).compactMap { $0 }, [])
        XCTAssertEqual(i.interpret(obs(playing: false, 0, 2.4, 20.3), queueIndex: 0, queueCount: 20), handoff)
        // Reported once: the later paused-at-0 rows add nothing.
        XCTAssertNil(i.interpret(obs(playing: false, 0, 2.4, 21.3), queueIndex: 0, queueCount: 20))
        XCTAssertNil(i.interpret(obs(playing: false, 0, 2.4, 22.3), queueIndex: 0, queueCount: 20))
        XCTAssertFalse(i.takeNoProgressEnd())
    }

    /// Sentinel's #159 edge: under 1.5 s the rewind ceiling is 0, but a rewind to 0 is already
    /// inside the end window of a sub-1.5 s entry, so the stopped-at-end shape reports it.
    func testSubOneAndAHalfSecondTrackRewoundToZeroStillAdvances() {
        var i = BoundaryInterpreter()
        i.userRequestedChange()
        XCTAssertNil(i.interpret(obs(playing: true, 0.6, 1.0, 18.3), queueIndex: 0, queueCount: 20))
        XCTAssertEqual(i.interpret(obs(playing: false, 0, 1.0, 19.3), queueIndex: 0, queueCount: 20), handoff)
        XCTAssertFalse(i.takeNoProgressEnd())
    }

    func testShortTrackEntryChangeIsANaturalEndNotAFailedStart() {
        var i = BoundaryInterpreter()
        _ = startedShortTrack(&i)
        XCTAssertEqual(i.interpret(obs("e1", playing: true, 0.2, 180, 20.3), queueIndex: 0, queueCount: 20),
                       .advancedEntry(finishedIndex: 0, boundary: .naturalEnd(finishedEntryID: "e0")))
        XCTAssertFalse(i.takeNoProgressEnd())
    }

    func testShortTrackQueueClearedIsANaturalEndNotAFailedStart() {
        var i = BoundaryInterpreter()
        _ = startedShortTrack(&i)
        XCTAssertEqual(i.interpret(PlaybackObservation(entryID: nil, isPlaying: false, uptime: 20.3),
                                   queueIndex: 0, queueCount: 20), handoff)
        XCTAssertFalse(i.takeNoProgressEnd())
    }

    func testMinimumProgressScalesOnlyForEntriesShorterThanThreeAndAHalfSeconds() {
        XCTAssertEqual(PlaybackBoundaryDetector.minimumProgress(duration: 2.4), 0.9, accuracy: 1e-9)
        XCTAssertEqual(PlaybackBoundaryDetector.minimumProgress(duration: 1.0), 0)
        XCTAssertEqual(PlaybackBoundaryDetector.minimumProgress(duration: 3.5), 2.0)
        XCTAssertEqual(PlaybackBoundaryDetector.minimumProgress(duration: 200), 2.0)
        XCTAssertEqual(PlaybackBoundaryDetector.minimumProgress(duration: nil), 2.0)
        XCTAssertEqual(PlaybackBoundaryDetector.minimumProgress(duration: 0), 2.0)
        XCTAssertEqual(PlaybackBoundaryDetector.minimumProgress(duration: -1), 2.0)
        XCTAssertEqual(PlaybackBoundaryDetector.minimumProgress(duration: 0.4), 0)
    }

    func testBuild9FailedStartOfANormalSongIsStillRefused() {
        var i = BoundaryInterpreter()
        i.userRequestedChange()
        XCTAssertNil(i.interpret(obs(playing: true, 0.5, 200, 10), queueIndex: 0, queueCount: 20))
        XCTAssertNil(i.interpret(obs("e1", playing: true, 0.1, 200, 11), queueIndex: 0, queueCount: 20))
        XCTAssertTrue(i.takeNoProgressEnd())
    }

    func testUserPauseInsideShortTrackEndWindowThenResumeIsNotAnEnd() {
        var i = BoundaryInterpreter()
        _ = startedShortTrack(&i)
        i.pausedByApp(.userPause)
        XCTAssertNil(i.interpret(obs(playing: false, 1.6, 2.4, 20.3), queueIndex: 0, queueCount: 20))
        XCTAssertNil(i.interpret(obs(playing: false, 0, 2.4, 21.3), queueIndex: 0, queueCount: 20))
        XCTAssertNil(i.interpret(obs(playing: false, 1.6, 2.4, 30.0), queueIndex: 0, queueCount: 20))
        // Resumed: still not an end while it plays.
        XCTAssertNil(i.interpret(obs(playing: true, 1.7, 2.4, 31.0), queueIndex: 0, queueCount: 20))
    }

    func testRouteLossInsideShortTrackEndWindowIsNotAnEnd() {
        var i = BoundaryInterpreter()
        _ = startedShortTrack(&i)
        i.pausedByApp(.routeLoss)
        XCTAssertNil(i.interpret(obs(playing: false, 0, 2.4, 20.3), queueIndex: 0, queueCount: 20))
    }

    func testUserSkipOfShortTrackIsNotAnEnd() {
        var i = BoundaryInterpreter()
        _ = startedShortTrack(&i)
        i.userRequestedChange()
        XCTAssertNil(i.interpret(obs(playing: false, 0, 2.4, 20.3), queueIndex: 0, queueCount: 20))
        XCTAssertNil(i.interpret(obs("e1", playing: true, 0.2, 180, 21.3), queueIndex: 0, queueCount: 20))
        XCTAssertFalse(i.takeNoProgressEnd())
    }

    func testNormalSongSameFinalPatternStillReportsEnd() {
        var i = BoundaryInterpreter()
        i.userRequestedChange()
        XCTAssertNil(i.interpret(obs(playing: true, 197.6, 200, 18.3), queueIndex: 0, queueCount: 20))
        XCTAssertNil(i.interpret(obs(playing: true, 198.6, 200, 19.3), queueIndex: 0, queueCount: 20))
        XCTAssertEqual(i.interpret(obs(playing: false, 0, 200, 20.3), queueIndex: 0, queueCount: 20), handoff)
    }

    func testNormalSongMidSongStopAtZeroIsStillNotAnEnd() {
        var i = BoundaryInterpreter()
        i.userRequestedChange()
        XCTAssertNil(i.interpret(obs(playing: true, 40, 200, 10), queueIndex: 0, queueCount: 20))
        XCTAssertNil(i.interpret(obs(playing: true, 41, 200, 11), queueIndex: 0, queueCount: 20))
        XCTAssertNil(i.interpret(obs(playing: false, 0, 200, 12), queueIndex: 0, queueCount: 20))
    }

    /// Short track: it reached its end window, the user seeked back to 0, and a stop came at
    /// once (inside the settle window), then the user paused. Neither is an end.
    func testSeekBackFromShortTrackEndWindowDoesNotFalseEnd() {
        var i = BoundaryInterpreter()
        _ = startedShortTrack(&i)
        i.userSeeked(to: 0, uptime: 19.4)
        XCTAssertNil(i.interpret(obs(playing: false, 0, 2.4, 19.6), queueIndex: 0, queueCount: 20))
        i.pausedByApp(.userPause)
        XCTAssertNil(i.interpret(obs(playing: false, 0.1, 2.4, 21.0), queueIndex: 0, queueCount: 20))
    }

    /// Normal song seeked back from its end window: a stop at 0 shortly after is not an end,
    /// because after a seek only real play counts (the furthest position is never trusted).
    func testSeekBackFromNormalSongEndWindowDoesNotFalseEnd() {
        var i = BoundaryInterpreter()
        i.userRequestedChange()
        XCTAssertNil(i.interpret(obs(playing: true, 197.6, 200, 1000), queueIndex: 0, queueCount: 20))
        XCTAssertNil(i.interpret(obs(playing: true, 198.6, 200, 1001), queueIndex: 0, queueCount: 20))
        i.userSeeked(to: 50, uptime: 1001.2)
        XCTAssertNil(i.interpret(obs(playing: true, 51.6, 200, 1003), queueIndex: 0, queueCount: 20))
        XCTAssertNil(i.interpret(obs(playing: false, 0, 200, 1004), queueIndex: 0, queueCount: 20))
    }
}
