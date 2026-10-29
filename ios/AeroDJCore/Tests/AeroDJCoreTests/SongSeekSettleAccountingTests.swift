import XCTest
@testable import AeroDJCore

/// Seek follow-up (-Atlas): a stop or user pause inside a seek's 1.5 s settle window stops play
/// time. The stopped samples there are ignored, so the first sample after the window must not
/// count the stopped time as play. Deterministic: explicit uptimes, no sleeps.
final class SongSeekSettleAccountingTests: XCTestCase {
    private func o(_ playing: Bool, _ position: TimeInterval, _ uptime: TimeInterval) -> PlaybackObservation {
        PlaybackObservation(entryID: "s1", isPlaying: playing, position: position, duration: 200, uptime: uptime)
    }

    /// Plays 0...last at 1 s polls, uptime == position.
    private func played(through last: Int) -> PlaybackBoundaryDetector {
        var d = PlaybackBoundaryDetector()
        for t in 0...last { XCTAssertNil(d.consume(o(true, TimeInterval(t), TimeInterval(t)))) }
        return d
    }

    func testStopInsideTheSettleWindowDoesNotCountTheStoppedTimeAsPlay() {
        var d = played(through: 60)
        d.userSeeked(to: 10, uptime: 60.2)                      // seek back: play restarts at 0
        XCTAssertNil(d.consume(o(true, 10.3, 60.7)))           // 0.5 s of play
        XCTAssertNil(d.consume(o(false, 10.6, 61.0)))          // stop inside the window: +0.3
        XCTAssertNil(d.consume(o(false, 10.6, 120.0)))         // first sample after the window
        XCTAssertEqual(d.testElapsedPlay, 0.8, accuracy: 0.001)
    }

    func testRawStopInsideTheSettleWindowThenALongGapIsNotARewoundEnd() {
        // Seek back to the start, a raw stop inside the window (no pause notice), then the app
        // is suspended. Counting the gap as play would read as played through, rewound to 0.
        var d = played(through: 100)
        d.userSeeked(to: 0.5, uptime: 100.2)
        XCTAssertNil(d.consume(o(true, 0.8, 100.7)))
        XCTAssertNil(d.consume(o(false, 0.9, 101.0)))
        XCTAssertNil(d.consume(o(false, 0.9, 400.0)), "stopped near the start is not an end")
        XCTAssertFalse(d.playedThrough)
        XCTAssertEqual(d.testElapsedPlay, 0.8, accuracy: 0.001)
    }

    func testUserPauseInsideTheSettleWindowStopsPlayTime() {
        var d = played(through: 60)
        d.userSeeked(to: 100, uptime: 60.2)                     // forward seek keeps 60 s of play
        XCTAssertNil(d.consume(o(true, 100.3, 60.7)))          // +0.5
        d.pausedByApp(.userPause)
        XCTAssertNil(d.consume(o(false, 100.3, 61.0)))
        XCTAssertNil(d.consume(o(false, 100.3, 260.0)))        // after the window, long pause
        XCTAssertEqual(d.testElapsedPlay, 60.5, accuracy: 0.001)
        XCTAssertNil(d.consume(o(true, 100.3, 300.0)))         // user resumes
        XCTAssertNil(d.consume(o(true, 101.3, 301.0)))         // +1 s of real play
        XCTAssertEqual(d.testElapsedPlay, 61.5, accuracy: 0.001)
    }

    func testPlayAfterATransientStopInsideTheWindowStillCounts() {
        var d = played(through: 60)
        d.userSeeked(to: 120, uptime: 60.2)
        XCTAssertNil(d.consume(o(false, 60, 60.5)))            // transient stop while seeking
        XCTAssertNil(d.consume(o(true, 120.2, 61.0)))          // playing again, still settling
        XCTAssertNil(d.consume(o(true, 121.2, 62.0)))          // +1 s
        XCTAssertNil(d.consume(o(true, 122.2, 63.0)))          // +1 s, after the window
        XCTAssertEqual(d.testElapsedPlay, 60.3 + 2, accuracy: 0.001,
                       "60 before the seek, 0.3 up to the stop, none while stopped, 2 after")
    }

    func testPauseWithoutASeekKeepsTheExistingAccounting() {
        var d = played(through: 10)
        d.pausedByApp(.userPause)
        XCTAssertNil(d.consume(o(false, 10.5, 11.0)))
        XCTAssertEqual(d.testElapsedPlay, 11, accuracy: 0.001)
    }
}
