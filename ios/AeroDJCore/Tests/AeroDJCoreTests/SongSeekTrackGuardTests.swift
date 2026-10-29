import XCTest
@testable import AeroDJCore

/// Seek follow-up (-Atlas): a seek names the track it was committed for, and is a no-op
/// (`.staleTrack`) once another song is on air (stale scrub, or a lock-screen scrub race).
final class SongSeekTrackGuardTests: XCTestCase {
    private let tracks = [TrackInfo(id: "a", title: "A", artistName: "X"),
                          TrackInfo(id: "b", title: "B", artistName: "Y"),
                          TrackInfo(id: "c", title: "C", artistName: "Z")]

    private func onAir() -> PlaybackEngine {
        var e = PlaybackEngine()
        e.apply(.queueStarted(tracks: tracks, startIndex: 0, station: nil))
        e.apply(.songStarted(duration: 200, seekable: true))
        e.apply(.playbackConfirmed)
        return e
    }

    // MARK: trackID guard

    func testSeekForTheCurrentTrackSeeks() {
        let e = onAir()
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 30, duration: 200, snapshot: e.snapshot, trackID: "a"),
                       .seek(target: 30, remaining: 170))
    }

    func testSeekForATrackThatEndedIsANoOpOnTheNextSong() {
        var e = onAir()
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.songStarted(duration: 200, seekable: true))
        e.apply(.playbackConfirmed)
        XCTAssertTrue(e.snapshot.canSeek, "song b is seekable")
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 30, duration: 200, snapshot: e.snapshot, trackID: "a"),
                       .blocked(.staleTrack))
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 30, duration: 200, snapshot: e.snapshot, trackID: "b"),
                       .seek(target: 30, remaining: 170))
    }

    func testSeekForATrackTheUserSkippedIsANoOp() {
        var e = onAir()
        e.apply(.userSkipped(nextIndex: 2))
        e.apply(.songStarted(duration: 200, seekable: true))
        e.apply(.playbackConfirmed)
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 30, duration: 200, snapshot: e.snapshot, trackID: "a"),
                       .blocked(.staleTrack))
    }

    func testUntargetedSeekKeepsTheExistingBehavior() {
        var e = onAir()
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.songStarted(duration: 200, seekable: true))
        e.apply(.playbackConfirmed)
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 30, duration: 200, snapshot: e.snapshot),
                       .seek(target: 30, remaining: 170))
    }

    func testNotSeekableNowWinsOverAStaleTrack() {
        var e = onAir()
        e.apply(.naturalBoundary(nextIndex: 1))   // loading song b: not seekable yet
        XCTAssertEqual(SongSeekPolicy.decide(seconds: 30, duration: 200, snapshot: e.snapshot, trackID: "a"),
                       .blocked(.notSeekableNow))
    }

    func testStaleTrackIsLoggedAsAnEnumToken() {
        XCTAssertEqual(PlaybackLog.songSeek(index: 1, decision: .blocked(.staleTrack)),
                       "song seek index=1 result=blocked reason=staleTrack")
    }
}
