import XCTest
@testable import AeroDJCore

/// #585 (-Atlas): the rewind-before-playing watch (#444) and the capped-load watch (#586) each end,
/// without a report, on anything that is not the plain stall: a stop past the start, a playing
/// sample, a user pause, an interruption, a different entry, or the load closing. Each test arms
/// the watch, breaks one condition, and lets the stall outlast the start-confirm window.
final class RewindWatchGuardTests: XCTestCase {
    private let window = PlaybackBoundaryDetector.rewoundBeforePlayingStallSeconds

    private func sample(_ entry: String, playing: Bool = false, _ position: TimeInterval, _ t: TimeInterval) -> PlaybackObservation {
        PlaybackObservation(entryID: entry, isPlaying: playing, position: position, duration: 200, uptime: t)
    }

    /// song-0 plays 30 s, then a skip load opens, our `play()` returns: the rewind watch is armed.
    private func armedRewindWatch(_ d: inout PlaybackBoundaryDetector) -> TimeInterval {
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: 30.0, by: 1.0) {
            _ = d.consume(sample("song-0", playing: true, position, t))
            t += 1
        }
        d.setSkipLoadInFlight(true)
        d.userRequestedChange()
        d.noteOwnPlayReturned()
        return t
    }

    /// As above, then song-1 stalls past the window (the rewind cut, taken), then the app reloads:
    /// the cap is spent, so the next load is watched by the capped-load watch instead.
    private func armedCappedWatch(_ d: inout PlaybackBoundaryDetector) -> TimeInterval {
        var t = armedRewindWatch(&d)
        _ = d.consume(sample("song-1", 0, t))
        t += window
        _ = d.consume(sample("song-1", 0, t))
        XCTAssertEqual(d.pendingSkipLoadCut, SkipLoadCut(shape: .rewind, targetSeenPlaying: false))
        XCTAssertTrue(d.takeSkipLoadCut())
        d.userRequestedChange()
        d.setSkipLoadInFlight(true)
        d.noteOwnPlayReturned()
        return t + 1
    }

    // MARK: controls

    func testControlAPlainStallReportsTheRewindCut() {
        var d = PlaybackBoundaryDetector()
        var t = armedRewindWatch(&d)
        _ = d.consume(sample("song-1", 0, t))
        t += window
        _ = d.consume(sample("song-1", 0, t))
        XCTAssertEqual(d.pendingSkipLoadCut, SkipLoadCut(shape: .rewind, targetSeenPlaying: false))
    }

    func testControlAPlainStallReportsTheCappedStart() {
        var d = PlaybackBoundaryDetector()
        var t = armedCappedWatch(&d)
        _ = d.consume(sample("song-2", 0, t))
        t += window
        _ = d.consume(sample("song-2", 0, t))
        XCTAssertTrue(d.takeSkipStartStalled())
        XCTAssertNil(d.pendingSkipLoadCut)
    }

    // MARK: a stop past the start ends the watch

    func testAStoppedSamplePastTheStartEndsTheRewindWatch() {
        var d = PlaybackBoundaryDetector()
        var t = armedRewindWatch(&d)
        _ = d.consume(sample("song-1", 30, t))
        t += window
        _ = d.consume(sample("song-1", 30, t))
        XCTAssertNil(d.pendingSkipLoadCut, "paused at 0:30 is not the rewind shape, however long it lasts")
        XCTAssertFalse(d.takeSkipLoadCut())
    }

    func testAStoppedSamplePastTheStartEndsTheCappedWatch() {
        var d = PlaybackBoundaryDetector()
        var t = armedCappedWatch(&d)
        _ = d.consume(sample("song-2", 30, t))
        t += window
        _ = d.consume(sample("song-2", 30, t))
        XCTAssertFalse(d.takeSkipStartStalled(), "paused at 0:30 is not a start that never began")
    }

    // MARK: a playing sample ends the watch for good

    func testAPlayingSampleEndsTheRewindWatchForGood() {
        var d = PlaybackBoundaryDetector()
        var t = armedRewindWatch(&d)
        _ = d.consume(sample("song-1", playing: true, 0.5, t))
        t += 1
        _ = d.consume(sample("song-1", 0, t))
        XCTAssertTrue(d.takeSkipLoadCut(), "stopped right after it played: a cut of a song seen playing")
        t += window
        _ = d.consume(sample("song-1", 0, t))
        XCTAssertNil(d.pendingSkipLoadCut, "the song played, so the not-yet-played rewind watch is over")
        t += window
        _ = d.consume(sample("song-1", 0, t))
        XCTAssertNil(d.pendingSkipLoadCut)
    }

    func testAPlayingSampleEndsTheCappedWatchForGood() {
        var d = PlaybackBoundaryDetector()
        var t = armedCappedWatch(&d)
        _ = d.consume(sample("song-2", playing: true, 0.5, t))
        t += 1
        _ = d.consume(sample("song-2", 0, t))
        XCTAssertTrue(d.takeSkipLoadCut())
        t += window
        _ = d.consume(sample("song-2", 0, t))
        XCTAssertFalse(d.takeSkipStartStalled(), "the song played, so the capped start watch is over")
    }

    // MARK: a hold or an interruption ends the watch

    func testAUserPauseEndsTheRewindWatch() {
        var d = PlaybackBoundaryDetector()
        var t = armedRewindWatch(&d)
        _ = d.consume(sample("song-1", 0, t))
        d.pausedByApp(.userPause)
        t += window
        _ = d.consume(sample("song-1", 0, t))
        XCTAssertNil(d.pendingSkipLoadCut, "a paused song at 0:00 is the user's pause, not a rewound Next")
    }

    func testAnInterruptionEndsTheRewindWatch() {
        var d = PlaybackBoundaryDetector()
        var t = armedRewindWatch(&d)
        _ = d.consume(sample("song-1", 0, t))
        d.pausedByApp(.systemInterruption)
        t += window
        _ = d.consume(sample("song-1", 0, t))
        XCTAssertNil(d.pendingSkipLoadCut, "an interruption explains the stop")
    }

    // MARK: the stall must be one entry's

    func testTwoEntriesStoppedAtStartAreNotOneStallForTheRewindWatch() {
        var d = PlaybackBoundaryDetector()
        var t = armedRewindWatch(&d)
        _ = d.consume(sample("song-1", 0, t))
        t += 4
        _ = d.consume(sample("song-2", 0, t))
        t += 5
        _ = d.consume(sample("song-2", 0, t))
        XCTAssertNil(d.pendingSkipLoadCut, "song-2 has stalled for 5 s, not for the 9 s since song-1 was first seen")
    }

    func testTwoEntriesStoppedAtStartAreNotOneStallForTheCappedWatch() {
        var d = PlaybackBoundaryDetector()
        var t = armedCappedWatch(&d)
        _ = d.consume(sample("song-2", 0, t))
        t += 4
        _ = d.consume(sample("song-3", 0, t))
        t += 5
        _ = d.consume(sample("song-3", 0, t))
        XCTAssertFalse(d.takeSkipStartStalled(), "song-3 has stalled for 5 s, not for the 9 s since song-2 was first seen")
    }

    // MARK: the load closing ends the watch

    func testAClosedLoadEndsTheRewindWatch() {
        var d = PlaybackBoundaryDetector()
        var t = armedRewindWatch(&d)
        _ = d.consume(sample("song-1", 0, t))
        d.setSkipLoadInFlight(false)
        t += window
        _ = d.consume(sample("song-1", 0, t))
        XCTAssertNil(d.pendingSkipLoadCut, "the caller closed the load; a later stall is not a cut of it")
    }
}
