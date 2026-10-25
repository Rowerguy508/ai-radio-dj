import XCTest
@testable import AeroDJCore

final class TrackAdvanceDetectorTests: XCTestCase {
    func testNaturalEndFiresOnce() {
        var d = TrackAdvanceDetector()
        // Playing track A.
        XCTAssertFalse(d.consume(.init(isPlaying: true, reachedEnd: false, itemChanged: false)))
        // Reaches the end while playing -> natural end fires.
        XCTAssertTrue(d.consume(.init(isPlaying: true, reachedEnd: true, itemChanged: false)))
        // Subsequent end sample does NOT re-fire (already reported).
        XCTAssertFalse(d.consume(.init(isPlaying: false, reachedEnd: true, itemChanged: false)))
    }

    func testItemChangeResetsState() {
        var d = TrackAdvanceDetector()
        _ = d.consume(.init(isPlaying: true, reachedEnd: true, itemChanged: false)) // ended A
        // MusicKit auto-advanced to track B -> itemChanged resets.
        XCTAssertFalse(d.consume(.init(isPlaying: true, reachedEnd: false, itemChanged: true)))
        XCTAssertFalse(d.consume(.init(isPlaying: true, reachedEnd: false, itemChanged: false)))
        // B reaches end -> fires again.
        XCTAssertTrue(d.consume(.init(isPlaying: true, reachedEnd: true, itemChanged: false)))
    }

    func testNeverStartedNoEnd() {
        var d = TrackAdvanceDetector()
        // Eternal idle samples produce no end.
        for _ in 0..<5 {
            XCTAssertFalse(d.consume(.init(isPlaying: false, reachedEnd: false, itemChanged: false)))
        }
    }

    func testPauseInMiddleNotEnd() {
        var d = TrackAdvanceDetector()
        _ = d.consume(.init(isPlaying: true, reachedEnd: false, itemChanged: false))
        // Paused mid-track (not at end) -> no end.
        XCTAssertFalse(d.consume(.init(isPlaying: false, reachedEnd: false, itemChanged: false)))
    }

    func testMidTrackPauseThenResumeStillFiresAtActualEnd() {
        var d = TrackAdvanceDetector()
        _ = d.consume(.init(isPlaying: true, reachedEnd: false, itemChanged: false))
        _ = d.consume(.init(isPlaying: false, reachedEnd: false, itemChanged: false))
        _ = d.consume(.init(isPlaying: true, reachedEnd: false, itemChanged: false))
        XCTAssertTrue(d.consume(.init(isPlaying: true, reachedEnd: true, itemChanged: false)))
    }
}