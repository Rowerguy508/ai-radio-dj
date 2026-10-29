import XCTest
@testable import AeroDJCore

final class ScrubberStateTests: XCTestCase {
    private let duration: TimeInterval = 225

    func testIdleFollowsSnapshot() {
        let state = ScrubberState(trackID: "a")
        XCTAssertEqual(state.displayedPosition(snapshotPosition: 72, duration: duration, now: 0), 72)
        XCTAssertFalse(state.pausesClock)
    }

    func testDraggingShowsTargetAndPausesClock() {
        var state = ScrubberState(trackID: "a")
        XCTAssertTrue(state.drag(to: 100, duration: duration, canSeek: true), "first move begins a drag")
        XCTAssertFalse(state.drag(to: 120, duration: duration, canSeek: true), "later moves are not a new drag")
        XCTAssertEqual(state.phase, .dragging(target: 120))
        XCTAssertTrue(state.pausesClock)
        XCTAssertEqual(state.displayedPosition(snapshotPosition: 72, duration: duration, now: 0), 120)
    }

    func testDragClampsToDuration() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: -30, duration: duration, canSeek: true)
        XCTAssertEqual(state.phase, .dragging(target: 0))
        state.drag(to: 9_999, duration: duration, canSeek: true)
        XCTAssertEqual(state.phase, .dragging(target: duration))
        XCTAssertEqual(ScrubberState.clamp(.nan, duration: duration), 0)
    }

    func testReleaseCommitsOnceAndHoldsTarget() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: 150, duration: duration, canSeek: true)
        XCTAssertEqual(state.endDrag(now: 10), 150)
        XCTAssertEqual(state.phase, .committing(target: 150, startedAt: 10))
        XCTAssertNil(state.endDrag(now: 10.1), "release with no drag sends no second seek")
        XCTAssertFalse(state.pausesClock)
        // Snapshot has not caught up yet: still showing the target.
        XCTAssertEqual(state.displayedPosition(snapshotPosition: 72, duration: duration, now: 11), 150)
    }

    func testHoldEndsWhenSnapshotWithinTolerance() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: 150, duration: duration, canSeek: true)
        _ = state.endDrag(now: 10)
        XCTAssertEqual(state.displayedPosition(snapshotPosition: 148.6, duration: duration, now: 10.5), 148.6)
        state.settle(snapshotPosition: 148.6, now: 10.5)
        XCTAssertEqual(state.phase, .idle)
    }

    func testHoldEndsAfterTimeout() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: 150, duration: duration, canSeek: true)
        _ = state.endDrag(now: 10)
        state.settle(snapshotPosition: 72, now: 11.9)
        XCTAssertNotEqual(state.phase, .idle, "before 2 s the hold stays")
        XCTAssertEqual(state.displayedPosition(snapshotPosition: 72, duration: duration, now: 12), 72)
        state.settle(snapshotPosition: 72, now: 12)
        XCTAssertEqual(state.phase, .idle)
    }

    func testFailedSeekReturnsToSnapshotImmediately() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: 150, duration: duration, canSeek: true)
        _ = state.endDrag(now: 10)
        state.seekFinished(commitID: state.commitID, succeeded: false)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.displayedPosition(snapshotPosition: 72, duration: duration, now: 10.1), 72)
    }

    func testSuccessfulSeekKeepsHolding() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: 150, duration: duration, canSeek: true)
        _ = state.endDrag(now: 10)
        state.seekFinished(commitID: state.commitID, succeeded: true)
        XCTAssertEqual(state.phase, .committing(target: 150, startedAt: 10))
    }

    func testLateResultForOlderCommitIsIgnored() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: 150, duration: duration, canSeek: true)
        _ = state.endDrag(now: 10)
        let first = state.commitID
        state.drag(to: 30, duration: duration, canSeek: true)
        _ = state.endDrag(now: 10.5)
        state.seekFinished(commitID: first, succeeded: false)
        XCTAssertEqual(state.phase, .committing(target: 30, startedAt: 10.5))
    }

    func testTrackChangeResetsToIdle() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: 150, duration: duration, canSeek: true)
        state.trackChanged(to: "b")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.trackID, "b")

        state.drag(to: 150, duration: duration, canSeek: true)
        _ = state.endDrag(now: 1)
        state.trackChanged(to: "c")
        XCTAssertEqual(state.phase, .idle, "a hold does not carry into the next song")
    }

    func testSameTrackIDKeepsState() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: 150, duration: duration, canSeek: true)
        state.trackChanged(to: "a")
        XCTAssertTrue(state.isDragging)
    }

    func testCanSeekFalseCancelsDrag() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: 150, duration: duration, canSeek: true)
        state.canSeekChanged(false)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.endDrag(now: 1), "a cancelled drag never seeks")
    }

    func testDragIgnoredWhenCannotSeekOrUnknownDuration() {
        var state = ScrubberState(trackID: "a")
        XCTAssertFalse(state.drag(to: 50, duration: duration, canSeek: false))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.drag(to: 50, duration: nil, canSeek: true))
        XCTAssertFalse(state.drag(to: 50, duration: 0, canSeek: true))
        XCTAssertEqual(state.phase, .idle)
    }

    func testCanSeekFalseMidDragMoveCancels() {
        var state = ScrubberState(trackID: "a")
        state.drag(to: 150, duration: duration, canSeek: true)
        state.drag(to: 160, duration: duration, canSeek: false)
        XCTAssertEqual(state.phase, .idle)
    }

    func testAccessibilityCommitClamps() {
        var state = ScrubberState(trackID: "a")
        XCTAssertEqual(state.commit(220 + ScrubberState.accessibilityStep, duration: duration, now: 0), duration)
        XCTAssertEqual(state.commit(5 - ScrubberState.accessibilityStep, duration: duration, now: 0), 0)
    }

    func testPositionFromTouch() {
        XCTAssertEqual(ScrubberState.position(atX: 50, width: 200, duration: 200), 50)
        XCTAssertEqual(ScrubberState.position(atX: -10, width: 200, duration: 200), 0)
        XCTAssertEqual(ScrubberState.position(atX: 250, width: 200, duration: 200), 200)
        XCTAssertEqual(ScrubberState.position(atX: 50, width: 0, duration: 200), 0)
        XCTAssertEqual(ScrubberState.fraction(position: 50, duration: 200), 0.25)
        XCTAssertEqual(ScrubberState.fraction(position: 50, duration: nil), 0)
    }
}

final class PlaybackTimeFormatTests: XCTestCase {
    func testMinutesSeconds() {
        XCTAssertEqual(PlaybackTimeFormat.label(0), "0:00")
        XCTAssertEqual(PlaybackTimeFormat.label(72.9), "1:12")
        XCTAssertEqual(PlaybackTimeFormat.label(599), "9:59")
        XCTAssertEqual(PlaybackTimeFormat.label(3599), "59:59")
    }

    func testHoursMinutesSeconds() {
        XCTAssertEqual(PlaybackTimeFormat.label(3600), "1:00:00")
        XCTAssertEqual(PlaybackTimeFormat.label(3725), "1:02:05")
    }

    func testNegativeAndNonFiniteReadZero() {
        XCTAssertEqual(PlaybackTimeFormat.label(-5), "0:00")
        XCTAssertEqual(PlaybackTimeFormat.label(.infinity), "0:00")
    }

    func testRemainingNeverNegative() {
        XCTAssertEqual(PlaybackTimeFormat.remaining(position: 72, duration: 225), "-2:33")
        XCTAssertEqual(PlaybackTimeFormat.remaining(position: 300, duration: 225), "-0:00")
        // Owner's build 25 case: 4:32 in, 13 s left.
        XCTAssertEqual(PlaybackTimeFormat.label(272), "4:32")
        XCTAssertEqual(PlaybackTimeFormat.remaining(position: 272, duration: 285), "-0:13")
    }

    func testAccessibilityValue() {
        XCTAssertEqual(PlaybackTimeFormat.accessibilityValue(position: 72, duration: 225), "1:12 of 3:45")
    }
}
