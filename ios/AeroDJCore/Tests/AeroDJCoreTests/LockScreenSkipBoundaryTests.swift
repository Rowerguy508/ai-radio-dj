import XCTest
@testable import AeroDJCore

/// P0 (owner, latest TestFlight): lock-screen Next pauses instead of skipping.
///
/// `ApplicationMusicPlayer` handles lock-screen commands itself, and the app's MusicKit queue holds
/// one song (`MusicKitService.startTrack`), so MusicKit's own Next is "at the last entry: playback
/// ends". These tests feed the boundary interpreter the two shapes that end can take mid-song.
/// Expected: a remote skip (`takeRemoteSkip()`), never a natural end (no DJ break about the cut
/// song) and never a silent pause. A real pause, route loss, interruption, app-made change or a
/// natural end (also one that happened while the app was suspended) is never a remote skip.
final class LockScreenSkipBoundaryTests: XCTestCase {
    private let song: TimeInterval = 200

    /// Plays song-0 from 0:00 to `until`, one sample a second, starting at uptime 100.
    @discardableResult
    private func play(_ b: inout BoundaryInterpreter, until: TimeInterval = 60,
                      duration: TimeInterval? = 200) -> TimeInterval {
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: until, by: 1.0) {
            XCTAssertNil(b.interpret(PlaybackObservation(entryID: "song-0", isPlaying: true, position: position,
                                                         duration: duration, uptime: t),
                                     queueIndex: 0, queueCount: 3))
            t += 1
        }
        return t
    }

    private func cleared(at t: TimeInterval) -> PlaybackObservation {
        PlaybackObservation(entryID: nil, isPlaying: false, position: nil, duration: nil, uptime: t)
    }

    private func rewound(at t: TimeInterval, duration: TimeInterval? = 200) -> PlaybackObservation {
        PlaybackObservation(entryID: "song-0", isPlaying: false, position: 0, duration: duration, uptime: t)
    }

    // MARK: The two remote-skip shapes

    /// MusicKit ends playback and clears the one-entry queue at 0:60 of 3:20.
    func testQueueClearedMidSongIsARemoteSkipNotANaturalEnd() {
        var b = BoundaryInterpreter()
        let t = play(&b)
        XCTAssertNil(b.interpret(cleared(at: t), queueIndex: 0, queueCount: 3),
                     "a lock-screen skip must not run the DJ break for the cut song")
        XCTAssertTrue(b.takeRemoteSkip())
        XCTAssertFalse(b.takeRemoteSkip(), "reported once")
        XCTAssertFalse(b.takeNoProgressEnd())
    }

    /// MusicKit ends playback but keeps the entry, rewound to 0:00 and stopped.
    func testEntryRewoundMidSongIsARemoteSkipNotAPause() {
        var b = BoundaryInterpreter()
        let t = play(&b)
        XCTAssertNil(b.interpret(rewound(at: t), queueIndex: 0, queueCount: 3))
        XCTAssertTrue(b.takeRemoteSkip())
        XCTAssertNil(b.interpret(rewound(at: t + 1), queueIndex: 0, queueCount: 3))
        XCTAssertFalse(b.takeRemoteSkip(), "sitting at 0:00 afterwards is not a second skip")
    }

    /// The last song of the station: still a skip, the app's skip path stops the queue.
    func testRemoteSkipOnTheLastSongIsStillASkip() {
        var b = BoundaryInterpreter()
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: 30.0, by: 1.0) {
            _ = b.interpret(PlaybackObservation(entryID: "song-2", isPlaying: true, position: position,
                                                duration: song, uptime: t), queueIndex: 2, queueCount: 3)
            t += 1
        }
        XCTAssertNil(b.interpret(cleared(at: t), queueIndex: 2, queueCount: 3))
        XCTAssertTrue(b.takeRemoteSkip())
    }

    // MARK: Never a skip

    /// A lock-screen Pause keeps the playhead. It stays a pause.
    func testRemotePauseKeepsThePlayheadAndStaysAPause() {
        var b = BoundaryInterpreter()
        let t = play(&b)
        XCTAssertNil(b.interpret(PlaybackObservation(entryID: "song-0", isPlaying: false, position: 60,
                                                     duration: song, uptime: t),
                                 queueIndex: 0, queueCount: 3))
        XCTAssertFalse(b.takeRemoteSkip())
    }

    func testAppPauseThenClearIsNotASkip() {
        for shape in [cleared(at: 161), rewound(at: 161)] {
            var b = BoundaryInterpreter()
            play(&b)
            b.pausedByApp(.userPause)
            XCTAssertNil(b.interpret(shape, queueIndex: 0, queueCount: 3))
            XCTAssertFalse(b.takeRemoteSkip(), "\(shape)")
        }
    }

    func testRouteLossIsNotASkip() {
        for shape in [cleared(at: 161), rewound(at: 161)] {
            var b = BoundaryInterpreter()
            play(&b)
            b.pausedByApp(.routeLoss)
            XCTAssertNil(b.interpret(shape, queueIndex: 0, queueCount: 3))
            XCTAssertFalse(b.takeRemoteSkip(), "\(shape)")
        }
    }

    func testInterruptionIsNotASkip() {
        for shape in [cleared(at: 161), rewound(at: 161)] {
            var b = BoundaryInterpreter()
            play(&b)
            b.pausedByApp(.systemInterruption)
            _ = b.interpret(shape, queueIndex: 0, queueCount: 3)
            XCTAssertFalse(b.takeRemoteSkip(), "\(shape)")
        }
    }

    /// #377 checking #373: Siri ducking our music (the song keeps playing) or pausing it (the
    /// entry stays loaded and the playhead holds) is not a lock-screen Skip. A skip is only a
    /// mid-song clear or a rewind below the minimum. A duck does not record a system
    /// interruption, so a later real clear is still a skip.
    func testSiriDuckOrPauseIsNotALockScreenSkip() {
        var ducked = BoundaryInterpreter()
        let t = play(&ducked)
        for i in 0..<4 {
            XCTAssertNil(ducked.interpret(PlaybackObservation(entryID: "song-0", isPlaying: true,
                                                              position: 61 + Double(i), duration: song,
                                                              uptime: t + Double(i)),
                                          queueIndex: 0, queueCount: 3))
        }
        XCTAssertFalse(ducked.takeRemoteSkip(), "a duck keeps the song playing")
        XCTAssertNil(ducked.interpret(cleared(at: t + 4), queueIndex: 0, queueCount: 3))
        XCTAssertTrue(ducked.takeRemoteSkip(), "the duck did not consume a later mid-song clear")

        var paused = BoundaryInterpreter()
        let p = play(&paused)
        XCTAssertNil(paused.interpret(PlaybackObservation(entryID: "song-0", isPlaying: false, position: 60,
                                                          duration: song, uptime: p),
                                      queueIndex: 0, queueCount: 3))
        XCTAssertFalse(paused.takeRemoteSkip(), "a pause holds the playhead: not a clear and not a rewind")

        var held = BoundaryInterpreter()
        let h = play(&held)
        held.pausedByApp(.systemInterruption)
        XCTAssertNil(held.interpret(PlaybackObservation(entryID: "song-0", isPlaying: false, position: 60,
                                                        duration: song, uptime: h),
                                    queueIndex: 0, queueCount: 3))
        XCTAssertFalse(held.takeRemoteSkip(), "a system pause with the playhead held is not a skip")
    }

    func testAppRequestedChangeIsNotASkip() {
        for shape in [cleared(at: 161), rewound(at: 161)] {
            var b = BoundaryInterpreter()
            play(&b)
            b.userRequestedChange()
            XCTAssertNil(b.interpret(shape, queueIndex: 0, queueCount: 3))
            XCTAssertFalse(b.takeRemoteSkip(), "\(shape)")
        }
    }

    /// A natural end keeps its break: cleared near the end.
    func testNaturalEndNearTheEndIsStillAHandoff() {
        var b = BoundaryInterpreter()
        let t = play(&b, until: 198)
        XCTAssertEqual(b.interpret(cleared(at: t), queueIndex: 0, queueCount: 3),
                       .plannedHandoff(finishedIndex: 0, nextIndex: 1, boundary: .naturalEnd(finishedEntryID: "song-0")))
        XCTAssertFalse(b.takeRemoteSkip())
    }

    /// The app was suspended mid-song and the song ended on its own meanwhile: the first sample
    /// after waking shows the clear long after the last one. The time between counts as play.
    func testNaturalEndWhileSuspendedIsStillAHandoff() {
        var b = BoundaryInterpreter()
        let t = play(&b)
        XCTAssertEqual(b.interpret(cleared(at: t + 300), queueIndex: 0, queueCount: 3),
                       .plannedHandoff(finishedIndex: 0, nextIndex: 1, boundary: .naturalEnd(finishedEntryID: "song-0")))
        XCTAssertFalse(b.takeRemoteSkip())
    }

    func testRewoundAfterASuspensionLongerThanTheSongIsStillAnEnd() {
        var b = BoundaryInterpreter()
        let t = play(&b)
        XCTAssertEqual(b.interpret(rewound(at: t + 300), queueIndex: 0, queueCount: 3),
                       .plannedHandoff(finishedIndex: 0, nextIndex: 1, boundary: .naturalEnd(finishedEntryID: "song-0")))
        XCTAssertFalse(b.takeRemoteSkip())
    }

    /// Without a catalog duration the end cannot be placed: never a skip, behavior unchanged.
    func testUnknownDurationIsNeverASkip() {
        var b = BoundaryInterpreter()
        let t = play(&b, duration: nil)
        XCTAssertEqual(b.interpret(cleared(at: t), queueIndex: 0, queueCount: 3),
                       .plannedHandoff(finishedIndex: 0, nextIndex: 1, boundary: .naturalEnd(finishedEntryID: "song-0")))
        XCTAssertFalse(b.takeRemoteSkip())
    }

    /// A start that never progressed keeps the build 9 failed-start report, not a skip.
    func testNoProgressClearIsAFailedStartNotASkip() {
        var b = BoundaryInterpreter()
        let t = play(&b, until: 1)
        XCTAssertNil(b.interpret(cleared(at: t), queueIndex: 0, queueCount: 3))
        XCTAssertTrue(b.takeNoProgressEnd())
        XCTAssertFalse(b.takeRemoteSkip())
    }

    /// Next pressed after 90% of the song: the song counts as played through (the build 18 rule),
    /// so the clear stays a natural end and its break airs.
    func testClearAfterThePlayedThroughMarkIsStillAHandoff() {
        var b = BoundaryInterpreter()
        let t = play(&b, until: 185)
        XCTAssertEqual(b.interpret(cleared(at: t), queueIndex: 0, queueCount: 3),
                       .plannedHandoff(finishedIndex: 0, nextIndex: 1, boundary: .naturalEnd(finishedEntryID: "song-0")))
        XCTAssertFalse(b.takeRemoteSkip())
    }

    /// A stop at 0:00 straight after the start (furthest 1 s) is not a skip: nothing played yet.
    func testStopAtTheStartRightAfterStartingIsNotASkip() {
        var b = BoundaryInterpreter()
        let t = play(&b, until: 1)
        XCTAssertNil(b.interpret(rewound(at: t), queueIndex: 0, queueCount: 3))
        XCTAssertFalse(b.takeRemoteSkip())
    }

    // MARK: nextTrackCommand

    func testRemoteNextSkipsOnlyWhenANextSongIsQueued() {
        XCTAssertEqual(RemoteNextCommand.decide(queueIndex: 0, queueCount: 3), .skip)
        XCTAssertEqual(RemoteNextCommand.decide(queueIndex: 1, queueCount: 3), .skip)
        XCTAssertEqual(RemoteNextCommand.decide(queueIndex: 2, queueCount: 3), .noNextSong)
        XCTAssertEqual(RemoteNextCommand.decide(queueIndex: 0, queueCount: 0), .noNextSong)
        XCTAssertEqual(RemoteNextCommand.decide(queueIndex: 0, queueCount: 1), .noNextSong)
        XCTAssertTrue(RemoteNextCommand.isEnabled(queueIndex: 0, queueCount: 2))
        XCTAssertFalse(RemoteNextCommand.isEnabled(queueIndex: 1, queueCount: 2))
    }
}
