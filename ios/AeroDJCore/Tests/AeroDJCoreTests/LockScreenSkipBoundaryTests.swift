import XCTest
@testable import AeroDJCore

/// P0 (owner, latest TestFlight): lock-screen Next pauses instead of skipping.
///
/// `ApplicationMusicPlayer` handles lock-screen commands itself (the app's MPRemoteCommandCenter
/// targets are not consulted for it, and no nextTrackCommand target is registered anyway). The
/// app's MusicKit queue holds one song (`MusicKitService.startTrack`), so MusicKit's own
/// `skipToNextEntry` is "at the last entry: playback ends". These tests feed the boundary
/// interpreter the two shapes that end can take mid-song, with no app-requested change.
///
/// Today: the cleared-queue shape is reported as a natural end (a DJ break would run after a song
/// the listener cut, then the next song); the kept-entry-rewound shape is reported as nothing (a
/// pause: the queue never advances). The expected behavior is "the listener skipped": no
/// natural end, no break, and the app advances through its own skip path. Expected to FAIL until
/// the fix adds a remote-skip classification.
final class LockScreenSkipBoundaryTests: XCTestCase {
    private let song: TimeInterval = 200

    private func playedMidSong(_ b: inout BoundaryInterpreter) {
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: 60.0, by: 1.0) {
            XCTAssertNil(b.interpret(PlaybackObservation(entryID: "song-0", isPlaying: true, position: position,
                                                         duration: song, uptime: t),
                                     queueIndex: 0, queueCount: 3))
            t += 1
        }
    }

    /// Shape B: MusicKit ends playback and clears the one-entry queue at 0:60 of 3:20.
    func testRemoteSkipThatClearsTheQueueMidSongIsNotANaturalEnd() {
        var b = BoundaryInterpreter()
        playedMidSong(&b)
        let step = b.interpret(PlaybackObservation(entryID: nil, isPlaying: false, position: nil,
                                                   duration: nil, uptime: 162),
                               queueIndex: 0, queueCount: 3)
        XCTAssertNotEqual(step, .plannedHandoff(finishedIndex: 0, nextIndex: 1,
                                                boundary: .naturalEnd(finishedEntryID: "song-0")),
                          "a lock-screen skip at 0:60 of 3:20 must not run the DJ break for the cut song")
    }

    /// Shape A: MusicKit ends playback but keeps the entry, rewound to 0:00 and stopped.
    func testRemoteSkipThatRewindsTheEntryMidSongIsNotSilentlyAPause() {
        var b = BoundaryInterpreter()
        playedMidSong(&b)
        let step = b.interpret(PlaybackObservation(entryID: "song-0", isPlaying: false, position: 0,
                                                   duration: song, uptime: 162),
                               queueIndex: 0, queueCount: 3)
        XCTAssertNotNil(step, "a stop rewound to 0:00 mid-song with no app pause is MusicKit ending the queue, not a pause")
    }

    /// Control: a lock-screen Pause keeps the playhead. That must stay a pause.
    func testRemotePauseMidSongStaysAPause() {
        var b = BoundaryInterpreter()
        playedMidSong(&b)
        XCTAssertNil(b.interpret(PlaybackObservation(entryID: "song-0", isPlaying: false, position: 60,
                                                     duration: song, uptime: 162),
                                 queueIndex: 0, queueCount: 3))
    }
}
