import XCTest
@testable import AeroDJCore

/// Build 9 P0 (-Atlas): an entry that changes or clears before it plays is a failed
/// start, not a natural end, so the queue must not auto-advance.
final class NoProgressStartTests: XCTestCase {
    private func obs(_ id: String?, _ playing: Bool, _ pos: TimeInterval?) -> PlaybackObservation {
        PlaybackObservation(entryID: id, isPlaying: playing, position: pos, duration: 200)
    }

    func testEntryChangeAtZeroIsNotANaturalEnd() {
        var d = PlaybackBoundaryDetector()
        XCTAssertNil(d.consume(obs("a", true, 0)))
        XCTAssertNil(d.consume(obs("a", true, 0.3)))
        XCTAssertNil(d.consume(obs("b", true, 0)))
        XCTAssertTrue(d.takeNoProgressEnd())
        XCTAssertFalse(d.takeNoProgressEnd())
    }

    func testQueueClearAtZeroIsNotQueueFinished() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("a", true, 0))
        XCTAssertNil(d.consume(obs(nil, false, nil)))
        XCTAssertTrue(d.takeNoProgressEnd())
    }

    func testEntryChangeAfterRealPlaybackIsStillANaturalEnd() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("a", true, 0))
        _ = d.consume(obs("a", true, 150))
        XCTAssertEqual(d.consume(obs("b", true, 0)), .naturalEnd(finishedEntryID: "a"))
        XCTAssertFalse(d.takeNoProgressEnd())
    }
}
