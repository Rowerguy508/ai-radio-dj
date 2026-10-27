import XCTest
@testable import AeroDJCore

final class UpNextEditTests: XCTestCase {
    private func t(_ n: Int) -> TrackInfo { TrackInfo(id: "t\(n)", title: "Song \(n)", artistName: "A") }
    private var upNext: [TrackInfo] { [t(2), t(3), t(4)] }

    func testRemoveDropsOnlyThatSong() {
        XCTAssertEqual(UpNextEditor.apply(.remove(id: "t3"), to: upNext, nowPlaying: t(1)), .success([t(2), t(4)]))
    }

    func testRemoveUnknownSongIsOutOfRange() {
        XCTAssertEqual(UpNextEditor.apply(.remove(id: "nope"), to: upNext, nowPlaying: t(1)), .failure(.outOfRange))
    }

    func testMoveReordersUpNext() {
        XCTAssertEqual(UpNextEditor.apply(.move(from: 0, to: 2), to: upNext, nowPlaying: t(1)), .success([t(3), t(4), t(2)]))
    }

    func testMoveOutOfRangeIsRejected() {
        XCTAssertEqual(UpNextEditor.apply(.move(from: 5, to: 0), to: upNext, nowPlaying: t(1)), .failure(.outOfRange))
        XCTAssertEqual(UpNextEditor.apply(.move(from: 0, to: 9), to: upNext, nowPlaying: t(1)), .failure(.outOfRange))
    }

    func testAppendAddsToEnd() {
        XCTAssertEqual(UpNextEditor.apply(.append(t(5)), to: upNext, nowPlaying: t(1)), .success(upNext + [t(5)]))
    }

    func testAppendRejectsDuplicateAndPlayingSong() {
        XCTAssertEqual(UpNextEditor.apply(.append(t(3)), to: upNext, nowPlaying: t(1)), .failure(.alreadyQueued))
        XCTAssertEqual(UpNextEditor.apply(.append(t(1)), to: upNext, nowPlaying: t(1)), .failure(.isPlayingNow))
    }

    // MARK: engine

    private func started() -> PlaybackEngine {
        var e = PlaybackEngine()
        e.apply(.queueStarted(tracks: [t(1), t(2), t(3), t(4)], startIndex: 0, station: nil))
        e.apply(.playbackConfirmed)
        return e
    }

    func testEditingUpNextNeverChangesNowPlayingOrTransport() {
        var e = started()
        e.apply(.upNextEdited(.remove(id: "t3")))
        XCTAssertEqual(e.snapshot.nowPlaying, t(1))
        XCTAssertEqual(e.snapshot.transport, .playing)
        XCTAssertEqual(e.snapshot.upNext, [t(2), t(4)])
    }

    func testEditedUpNextIsKeptAcrossNaturalBoundary() {
        var e = started()
        e.apply(.upNextEdited(.move(from: 2, to: 0))) // [t4, t2, t3]
        e.apply(.naturalBoundary(nextIndex: 1))
        XCTAssertEqual(e.snapshot.nowPlaying, t(4), "the moved song plays next")
        XCTAssertEqual(e.snapshot.upNext, [t(2), t(3)])
    }

    func testRejectedEditIsReportedAndLeavesQueueAlone() {
        var e = started()
        e.apply(.upNextEdited(.append(t(1))))
        XCTAssertEqual(e.snapshot.upNext, [t(2), t(3), t(4)])
        XCTAssertEqual(e.snapshot.error?.isRecoverable, true)
        XCTAssertEqual(e.snapshot.error?.message, "That song is playing now.")
    }

    func testEditDuringDJBreakKeepsBreakAndSong() {
        var e = started()
        e.apply(.naturalBoundary(nextIndex: 1))
        e.apply(.djStarted(line: "Up next."))
        e.apply(.upNextEdited(.remove(id: "t4")))
        XCTAssertEqual(e.snapshot.dj, .speaking(line: "Up next."))
        XCTAssertEqual(e.snapshot.nowPlaying, t(2))
        XCTAssertEqual(e.snapshot.upNext, [t(3)])
    }
}
