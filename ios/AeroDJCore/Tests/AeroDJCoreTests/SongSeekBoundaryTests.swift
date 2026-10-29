import XCTest
@testable import AeroDJCore

/// Song scrubbing (-Atlas): a committed user seek is the only thing that re-baselines the
/// detector's per-entry facts. Deterministic: polls carry an explicit uptime, no sleeps.
///
/// Fed in `MusicKitService`'s order: `seek(to:)` calls `userSeeked` before it sets the playhead;
/// the 1 s poll calls `interpret`; a user pause calls `pausedByApp(.userPause)`.
final class SongSeekBoundaryTests: XCTestCase {
    private static let duration: TimeInterval = 200

    private struct Rig {
        var interpreter = BoundaryInterpreter()
        var uptime: TimeInterval = 1_000
        var steps: [BoundaryStep] = []

        init() {
            // The user tapped song 1 of a 3-song station queue.
            interpreter.userRequestedChange()
        }

        /// One poll at the current uptime; the clock then moves `advance` seconds.
        mutating func poll(_ playing: Bool, at position: TimeInterval?, id: String? = "s1",
                           advance: TimeInterval = 1) {
            let o = PlaybackObservation(entryID: id, isPlaying: playing, position: position,
                                        duration: id == nil ? nil : SongSeekBoundaryTests.duration,
                                        uptime: uptime)
            if let step = interpreter.interpret(o, queueIndex: 0, queueCount: 3) { steps.append(step) }
            uptime += advance
        }

        /// 1 s polls, playing, from `first` through `last`.
        mutating func play(from first: TimeInterval, through last: TimeInterval) {
            var t = first
            while t <= last {
                poll(true, at: t)
                t += 1
            }
        }

        mutating func seek(to target: TimeInterval) {
            interpreter.userSeeked(to: target, uptime: uptime)
        }

        mutating func userPause() {
            interpreter.pausedByApp(.userPause)
        }

        var ends: Int { steps.count }
    }

    private func assertOneHandoff(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rig.steps, [.plannedHandoff(finishedIndex: 0, nextIndex: 1,
                                                    boundary: .naturalEnd(finishedEntryID: "s1"))],
                       file: file, line: line)
    }

    // MARK: Forward seeks

    func testForwardSeekPastNinetyPercentThenNaturalEndIsOneEnd() {
        var r = Rig()
        r.play(from: 0, through: 30)
        r.seek(to: 190)                       // 95%
        r.play(from: 190, through: 199)
        r.poll(false, at: 199.6)              // stopped at the end
        r.poll(false, at: 199.6)
        r.poll(false, at: 0)
        assertOneHandoff(r)
    }

    func testForwardSeekPastNinetyPercentThenRewoundQueueEndIsOneEnd() {
        // MusicKit rewinds a finished one-song queue (build 16), with a stale .playing at 0.
        var r = Rig()
        r.play(from: 0, through: 30)
        r.seek(to: 190)
        r.play(from: 190, through: 199)
        r.poll(true, at: 0)                   // stale .playing at 0 at song end
        r.poll(false, at: 0)
        r.poll(false, at: 0)
        assertOneHandoff(r)
    }

    func testForwardSeekPastNinetyPercentIsNotPlayedThroughByItself() {
        // Only two real seconds after the seek: a stop rewound to 0 is not the rewound end shape.
        var r = Rig()
        r.play(from: 0, through: 30)
        r.seek(to: 190)
        r.play(from: 190, through: 191)
        r.poll(false, at: 0)
        r.poll(false, at: 0)
        XCTAssertEqual(r.ends, 0)
    }

    func testForwardSeekPastNinetyPercentThenUserPauseIsNotAnEnd() {
        var r = Rig()
        r.play(from: 0, through: 30)
        r.seek(to: 190)
        r.play(from: 190, through: 192)
        r.userPause()
        r.poll(false, at: 192)
        r.poll(false, at: 192)
        XCTAssertEqual(r.ends, 0)
        // Resumed, it still ends once at its real end.
        r.play(from: 193, through: 199)
        r.poll(false, at: 199.6)
        assertOneHandoff(r)
    }

    func testForwardSeekPastNinetyPercentThenStopWithoutPauseNoticeIsNotAnEnd() {
        var r = Rig()
        r.play(from: 0, through: 30)
        r.seek(to: 190)
        r.play(from: 190, through: 193)
        r.poll(false, at: 193)                // no pause notice reached the detector
        XCTAssertEqual(r.ends, 0)
    }

    func testSeekToTheLastSecondEndsOnceWhenTheStopLandsInsideTheSettleWindow() {
        var r = Rig()
        r.play(from: 0, through: 30)
        r.seek(to: SongSeekPolicy.clamp(500, duration: Self.duration)!)    // 199
        r.poll(true, at: 199, advance: 0.5)
        r.poll(false, at: 199.9, advance: 1)  // the real end, inside the window: ignored
        XCTAssertEqual(r.ends, 0)
        r.poll(false, at: 199.9)              // after the window: the first stop after playing
        r.poll(false, at: 0)
        assertOneHandoff(r)
    }

    // MARK: Seeks back

    func testSeekBackUnderTwoSecondsThenPauseInsideTheSettleWindowIsNotAnEnd() {
        // The parked post-P0 gap, through the explicit seek API: played through, seek to 1 s,
        // pause within 1.5 s. It used to read as the rewound end shape.
        var r = Rig()
        r.play(from: 0, through: 195)
        r.seek(to: 1)
        r.poll(true, at: 1, advance: 0.7)
        r.userPause()
        r.poll(false, at: 1.7, advance: 1)
        r.poll(false, at: 1.7)
        r.poll(false, at: 1.7)
        XCTAssertEqual(r.ends, 0)
    }

    func testSeekBackUnderTwoSecondsThenStopWithoutPauseNoticeIsNotAnEnd() {
        var r = Rig()
        r.play(from: 0, through: 195)
        r.seek(to: 1)
        r.poll(true, at: 1, advance: 0.7)
        r.poll(false, at: 1.7, advance: 1)    // inside the window: ignored
        r.poll(false, at: 1.7)                // after it: judged, not played through any more
        r.poll(false, at: 0)
        XCTAssertEqual(r.ends, 0)
    }

    func testSeekBackUnderTwoSecondsThenPauseAfterTheWindowIsNotAnEnd() {
        var r = Rig()
        r.play(from: 0, through: 195)
        r.seek(to: 0.5)
        r.play(from: 0.5, through: 3.5)
        r.poll(false, at: 4)
        r.poll(false, at: 0)
        XCTAssertEqual(r.ends, 0)
    }

    func testSeekBackStillEndsOnceAtTheRealEnd() {
        var r = Rig()
        r.play(from: 0, through: 195)
        r.seek(to: 1)
        r.play(from: 1, through: 199)
        r.poll(false, at: 199.6)
        r.poll(false, at: 0)
        assertOneHandoff(r)
    }

    func testSeekBackThenRewoundQueueEndAfterReplayingIsOneEnd() {
        var r = Rig()
        r.play(from: 0, through: 195)
        r.seek(to: 10)
        r.play(from: 10, through: 199)
        r.poll(true, at: 0)                   // stale .playing at 0
        r.poll(false, at: 0)
        assertOneHandoff(r)
    }

    // MARK: Settle window

    func testTransientStopAndStalePositionRightAfterASeekAreIgnored() {
        var r = Rig()
        r.play(from: 0, through: 60)
        r.seek(to: 120)
        r.poll(false, at: 60, advance: 0.5)   // transient stop with the pre-seek position
        r.poll(true, at: 60, advance: 0.5)    // stale position while the seek lands
        r.play(from: 121, through: 130)
        r.userPause()
        r.poll(false, at: 130)
        XCTAssertEqual(r.ends, 0)
    }

    func testStalePlayingSampleInsideTheWindowDoesNotReleaseAUserPause() {
        var r = Rig()
        r.play(from: 0, through: 195)
        r.userPause()
        r.poll(false, at: 195)
        r.seek(to: 199)                       // seeking while paused
        r.poll(true, at: 199, advance: 0.5)   // stale .playing while the seek lands
        r.poll(false, at: 199, advance: 1.5)
        r.poll(false, at: 199)
        r.poll(false, at: 0)
        XCTAssertEqual(r.ends, 0, "still the user's pause, not an end")
    }

    func testSettleWindowWithoutUptimeEndsAtTheFirstPlayingSample() {
        var d = PlaybackBoundaryDetector()
        for t in stride(from: 0.0, through: 60, by: 1) {
            XCTAssertNil(d.consume(.init(entryID: "s1", isPlaying: true, position: t, duration: 200)))
        }
        d.userSeeked(to: 198.8, uptime: nil)
        XCTAssertNil(d.consume(.init(entryID: "s1", isPlaying: false, position: 60, duration: 200)),
                     "transient stop before playing resumes")
        XCTAssertNil(d.consume(.init(entryID: "s1", isPlaying: true, position: 198.9, duration: 200)))
        XCTAssertEqual(d.consume(.init(entryID: "s1", isPlaying: false, position: 199.6, duration: 200)),
                       .queueFinished(lastEntryID: "s1"))
    }

    // MARK: No seek: unchanged

    func testStalePlayingAtZeroAtNaturalEndWithoutSeekIsStillAnEnd() {
        var r = Rig()
        r.play(from: 0, through: 199)
        r.poll(true, at: 0)                   // stale .playing at 0 (the build 18 shape)
        r.poll(false, at: 0)
        r.poll(false, at: 0)
        assertOneHandoff(r)
    }

    func testSeekWithNoEntryChangesNothing() {
        var r = Rig()
        r.seek(to: 100)
        r.play(from: 0, through: 199)
        r.poll(false, at: 199.6)
        assertOneHandoff(r)
    }

    func testNewEntryClearsTheSeekBaseline() {
        // A seek on song 1 does not leak into song 2: song 2's rewound end still counts.
        var d = PlaybackBoundaryDetector()
        var up: TimeInterval = 0
        func o(_ id: String, _ playing: Bool, _ pos: TimeInterval) -> PlaybackObservation {
            defer { up += 1 }
            return .init(entryID: id, isPlaying: playing, position: pos, duration: 200, uptime: up)
        }
        _ = d.consume(o("s1", true, 0))
        d.userSeeked(to: 150, uptime: up)
        d.userRequestedChange()
        _ = d.consume(o("s2", true, 0))
        var t: TimeInterval = 1
        while t <= 199 { XCTAssertNil(d.consume(o("s2", true, t))); t += 1 }
        XCTAssertNil(d.consume(o("s2", true, 0)))
        XCTAssertEqual(d.consume(o("s2", false, 0)), .queueFinished(lastEntryID: "s2"))
    }
}
