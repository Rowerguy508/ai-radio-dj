import XCTest
@testable import AeroDJCore

/// Song scrubbing (-Atlas): when the transport offers a seek (`PlaybackSnapshot.canSeek`) and
/// what one committed seek does (`SongSeekPolicy`). Pure: the same events `MusicKitService` sends.
final class SongSeekTransportTests: XCTestCase {
    private let tracks = [TrackInfo(id: "a", title: "A", artistName: "X"),
                          TrackInfo(id: "b", title: "B", artistName: "Y"),
                          TrackInfo(id: "c", title: "C", artistName: "Z")]

    /// `play` -> `startTrack` -> `noteSongStarted` -> confirm: the app's order.
    private func onAir(duration: TimeInterval? = 200, seekable: Bool = true) -> PlaybackEngine {
        var e = PlaybackEngine()
        e.apply(.queueStarted(tracks: tracks, startIndex: 0, station: nil))
        e.apply(.songStarted(duration: duration, seekable: seekable))
        e.apply(.playbackConfirmed)
        return e
    }

    func testCanSeekOnlyOnceTheSongStartedAndPlaybackIsConfirmed() {
        var e = PlaybackEngine()
        XCTAssertFalse(e.snapshot.canSeek, "nothing queued")
        e.apply(.queueStarted(tracks: tracks, startIndex: 0, station: nil))
        XCTAssertFalse(e.snapshot.canSeek, "loading")
        e.apply(.songStarted(duration: 200, seekable: true))
        XCTAssertFalse(e.snapshot.canSeek, "still .preparing until MusicKit confirms")
        e.apply(.playbackConfirmed)
        XCTAssertTrue(e.snapshot.canSeek)
    }

    func testConfirmedWithoutASongStartIsNotSeekable() {
        var e = PlaybackEngine()
        e.apply(.queueStarted(tracks: tracks, startIndex: 0, station: nil))
        e.apply(.playbackConfirmed)
        XCTAssertFalse(e.snapshot.canSeek)
    }

    func testPausedSongIsSeekableAndAResumeInFlightIsNot() {
        var e = onAir()
        e.apply(.userPaused)
        XCTAssertTrue(e.snapshot.canSeek, "seeking while paused is allowed")
        e.apply(.userResumed)
        XCTAssertFalse(e.snapshot.canSeek, ".preparing: a resume is in flight")
        e.apply(.playbackConfirmed)
        XCTAssertTrue(e.snapshot.canSeek)
    }

    func testBreakBlocksSeekingFromTheBoundaryUntilTheNextSongStarts() {
        var e = onAir()
        e.apply(.naturalBoundary(nextIndex: 1))
        XCTAssertFalse(e.snapshot.canSeek, "break preparing or handed out")
        e.apply(.djStarted(line: "That was A."))
        XCTAssertFalse(e.snapshot.canSeek, "break on air")
        e.apply(.djFinished)
        XCTAssertFalse(e.snapshot.canSeek, "next song not started yet")
        e.apply(.songStarted(duration: 180, seekable: true))
        XCTAssertTrue(e.snapshot.canSeek)
    }

    func testSpeakingDJBlocksSeekingEvenWithoutABoundaryEvent() {
        var e = onAir()
        e.apply(.djStarted(line: "Hello"))
        XCTAssertFalse(e.snapshot.canSeek)
        e.apply(.djCancelled)
        XCTAssertFalse(e.snapshot.canSeek, "only a new song start reopens seeking")
    }

    func testSkipAndQueueEndAndNewQueueBlockSeeking() {
        var skipped = onAir()
        skipped.apply(.userSkipped(nextIndex: 1))
        XCTAssertFalse(skipped.snapshot.canSeek)

        var finished = onAir()
        finished.apply(.queueFinished)
        XCTAssertFalse(finished.snapshot.canSeek)

        var replaced = onAir()
        replaced.apply(.queueStarted(tracks: tracks, startIndex: 1, station: nil))
        XCTAssertFalse(replaced.snapshot.canSeek)

        var emptied = onAir()
        emptied.apply(.queueStarted(tracks: [], startIndex: 0, station: nil))
        XCTAssertFalse(emptied.snapshot.canSeek)
        emptied.apply(.playbackConfirmed)
        XCTAssertFalse(emptied.snapshot.canSeek)
    }

    func testUnknownZeroOrNonFiniteDurationAndUnseekableItemsAreNotSeekable() {
        XCTAssertFalse(onAir(duration: nil).snapshot.canSeek)
        XCTAssertFalse(onAir(duration: 0).snapshot.canSeek)
        XCTAssertFalse(onAir(duration: -3).snapshot.canSeek)
        XCTAssertFalse(onAir(duration: .infinity).snapshot.canSeek)
        XCTAssertFalse(onAir(duration: .nan).snapshot.canSeek)
        XCTAssertFalse(onAir(seekable: false).snapshot.canSeek)
    }

    func testExistingSnapshotsStayUnseekableByDefault() {
        XCTAssertFalse(PlaybackSnapshot().canSeek)
        XCTAssertFalse(PlaybackSnapshot(transport: .playing).canSeek)
    }

    // MARK: SongSeekPolicy

    func testSeekDuringABreakIsBlocked() {
        var e = onAir()
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.djStarted(line: "That was A."))
        let decision = SongSeekPolicy.decide(seconds: 30, duration: 200, snapshot: e.snapshot)
        XCTAssertEqual(decision, .blocked(.notSeekableNow))
        XCTAssertFalse(decision.didSeek, "PlaybackActions.seek(to:) returns false")
    }

    func testSeekWhileLoadingIsBlocked() {
        var e = PlaybackEngine()
        e.apply(.queueStarted(tracks: tracks, startIndex: 0, station: nil))
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 30, duration: 200, snapshot: e.snapshot),
                       .blocked(.notSeekableNow))
    }

    func testSeekWithoutADurationIsBlocked() {
        let e = onAir()
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 30, duration: nil, snapshot: e.snapshot),
                       .blocked(.unknownDuration))
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 30, duration: 0, snapshot: e.snapshot),
                       .blocked(.unknownDuration))
    }

    func testNonFiniteTargetIsBlocked() {
        let e = onAir()
        XCTAssertEqual(SongSeekPolicy.decide(seconds: .nan, duration: 200, snapshot: e.snapshot),
                       .blocked(.invalidTarget))
        XCTAssertEqual(SongSeekPolicy.decide(seconds: .infinity, duration: 200, snapshot: e.snapshot),
                       .blocked(.invalidTarget))
    }

    func testTargetIsClampedToZeroAndOneSecondBeforeTheEnd() {
        let e = onAir()
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 42.5, duration: 200, snapshot: e.snapshot),
                       .seek(target: 42.5, remaining: 157.5))
        XCTAssertEqual(SongSeekPolicy.decide(seconds: -5, duration: 200, snapshot: e.snapshot),
                       .seek(target: 0, remaining: 200))
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 250, duration: 200, snapshot: e.snapshot),
                       .seek(target: 199, remaining: 1))
        XCTAssertEqual(SongSeekPolicy.clamp(0.4, duration: 0.5), 0, "a sub-second song seeks to 0")
    }

    func testSeekLogLinesCarryOnlyNumbersAndTokens() {
        XCTAssertEqual(PlaybackLog.songSeek(index: 2, decision: .seek(target: 42.7, remaining: 157.3)),
                       "song seek index=2 result=seeked targetSeconds=42 remainingSeconds=157")
        XCTAssertEqual(PlaybackLog.songSeek(index: 0, decision: .blocked(.notSeekableNow)),
                       "song seek index=0 result=blocked reason=notSeekableNow")
    }
}
