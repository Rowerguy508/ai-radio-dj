import XCTest
@testable import AeroDJCore

/// Owner-reported (build 16): music plays, the bar stays at 0:00 and the duration is the
/// same for every song. At 2abafc3 the bar chose its period from `time.isPlaying()` when
/// first built and had no value inputs, so a bar first drawn while paused/preparing kept a
/// 3600 s period after Play (and Reduce Motion forced 3600 s even while playing).
final class PlaybackProgressClockTests: XCTestCase {
    private let songA = "song-a"
    private let songB = "song-b"

    func testPausedThenPlayingTicksEverySecond() {
        var timeline = PlaybackProgressTimeline(key: .init(transport: .paused, trackID: songA))
        XCTAssertFalse(timeline.redrawsWithin(1), "paused bar should not tick")

        timeline.render(.init(transport: .playing, trackID: songA))

        XCTAssertEqual(timeline.interval, 1)
        XCTAssertTrue(timeline.redrawsWithin(1), "bar must tick once transport is .playing")
    }

    func testPreparingThenPlayingTicks() {
        var timeline = PlaybackProgressTimeline(key: .init(transport: .preparing, trackID: nil))
        XCTAssertFalse(timeline.redrawsWithin(1), ".preparing must not move the bar")
        timeline.render(.init(transport: .playing, trackID: songA))
        XCTAssertTrue(timeline.redrawsWithin(1))
    }

    /// Paused on song A, then Play lands on song B: the timeline must be rebuilt for B so
    /// the duration label is read for the new track, not kept from the first render.
    func testPausedThenPlayingNewTrackRebuildsForThatTrack() {
        var timeline = PlaybackProgressTimeline(key: .init(transport: .paused, trackID: songA))
        timeline.render(.init(transport: .playing, trackID: songB))
        XCTAssertEqual(timeline.key.trackID, songB)
        XCTAssertTrue(timeline.redrawsWithin(1))
    }

    func testTrackChangeWhilePlayingRebuildsTimeline() {
        var timeline = PlaybackProgressTimeline(key: .init(transport: .playing, trackID: songA))
        let first = timeline
        timeline.render(.init(transport: .playing, trackID: songB))
        XCTAssertNotEqual(timeline, first)
        XCTAssertEqual(timeline.key.trackID, songB)
        XCTAssertTrue(timeline.redrawsWithin(1))
    }

    /// Reduce Motion drops the fill animation only; the clock still updates every second.
    func testReduceMotionKeepsOneSecondTickButNoAnimation() {
        var timeline = PlaybackProgressTimeline(key: .init(transport: .paused, trackID: songA), reduceMotion: true)
        timeline.render(.init(transport: .playing, trackID: songA))
        XCTAssertTrue(timeline.redrawsWithin(1), "Reduce Motion must not freeze the clock")
        XCTAssertEqual(PlaybackProgressClock.interval(for: .init(transport: .playing, trackID: songA), reduceMotion: true), 1)
        XCTAssertFalse(PlaybackProgressClock.animatesFill(reduceMotion: true))
        XCTAssertTrue(PlaybackProgressClock.animatesFill(reduceMotion: false))
    }

    func testSameInputsKeepSchedule() {
        var timeline = PlaybackProgressTimeline(key: .init(transport: .playing, trackID: songA))
        let first = timeline
        timeline.render(.init(transport: .playing, trackID: songA))
        XCTAssertEqual(timeline, first)
    }
}
