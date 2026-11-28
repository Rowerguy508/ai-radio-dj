import XCTest
@testable import AeroDJCore

/// #444 (-Atlas): the skip's song playing past the failed-start window is the detector's one signal
/// that the load stuck. It reports progress once (the app resets its recovery budget on it) and
/// closes the open skip load, so a later stop is an ordinary remote skip, not a cut of the load.
final class SkipLoadProgressSignalTests: XCTestCase {
    private func playing(_ entry: String, _ position: TimeInterval, _ t: TimeInterval) -> PlaybackObservation {
        PlaybackObservation(entryID: entry, isPlaying: true, position: position, duration: 200, uptime: t)
    }

    func testPlayingPastTheFailedStartWindowReportsProgressOnceAndClosesTheLoad() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: 30.0, by: 1.0) {
            _ = d.consume(playing("song-0", position, t))
            t += 1
        }
        d.setSkipLoadInFlight(true)
        d.userRequestedChange()
        d.noteOwnPlayReturned()
        XCTAssertTrue(d.isSkipLoadInFlight)

        // Inside the failed-start window (under `minimumProgress`): playing, but not progress yet.
        XCTAssertNil(d.consume(playing("song-1", 0.5, t)))
        t += 1
        XCTAssertNil(d.consume(playing("song-1", 1.5, t)))
        XCTAssertFalse(d.takeSkipLoadProgress(), "1.5 s is still inside the failed-start window")
        XCTAssertTrue(d.isSkipLoadInFlight)

        // Past it: progress, once, and the load is no longer open.
        t += 1
        XCTAssertNil(d.consume(playing("song-1", 2.5, t)))
        XCTAssertFalse(d.isSkipLoadInFlight, "the load played past the window, so it is closed")
        XCTAssertTrue(d.takeSkipLoadProgress(), "the recovery budget resets on this signal")
        XCTAssertFalse(d.takeSkipLoadProgress(), "reported once")

        t += 1
        XCTAssertNil(d.consume(playing("song-1", 3.5, t)))
        XCTAssertFalse(d.takeSkipLoadProgress(), "later playing samples report nothing more")
        XCTAssertFalse(d.isSkipLoadInFlight)
    }
}
