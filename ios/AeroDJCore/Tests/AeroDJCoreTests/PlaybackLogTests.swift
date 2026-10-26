import XCTest
@testable import AeroDJCore

/// The Duo script matches these strings. They carry indices, bools, and fixed tokens only.
final class PlaybackLogTests: XCTestCase {
    func testPlaybackLogLinesMatchTheDuoScript() {
        XCTAssertEqual(PlaybackLog.breakStart(after: 2), "break start after=2")
        XCTAssertEqual(PlaybackLog.breakEnd(after: 2, result: .finished), "break end after=2 result=finished")
        XCTAssertEqual(PlaybackLog.breakEnd(after: 2, result: .cancelled), "break end after=2 result=cancelled")
        XCTAssertEqual(PlaybackLog.breakEnd(after: 2, result: .failed), "break end after=2 result=failed")
        XCTAssertEqual(
            PlaybackLog.breakSkipped(after: 1, reason: .notPlanned),
            "break skipped after=1 reason=notPlanned"
        )
        XCTAssertEqual(
            PlaybackLog.breakSkipped(after: 0, reason: .renderFailed),
            "break skipped after=0 reason=renderFailed"
        )
        XCTAssertEqual(
            PlaybackLog.queueEnd(finished: 3, signal: .entryCleared),
            "boundary queueEnd finished=3 signal=entryCleared"
        )
        XCTAssertEqual(
            PlaybackLog.queueEnd(finished: 3, signal: .position),
            "boundary queueEnd finished=3 signal=position"
        )
        XCTAssertEqual(PlaybackLog.stationFinished(finished: 4), "boundary stationFinished finished=4")
        XCTAssertEqual(PlaybackLog.userPause(index: 1, nearEnd: true), "user pause index=1 nearEnd=true")
        XCTAssertEqual(PlaybackLog.userPause(index: 1, nearEnd: false), "user pause index=1 nearEnd=false")
        XCTAssertEqual(PlaybackLog.interruptionBegan(), "session interruption began")
        XCTAssertEqual(
            PlaybackLog.interruptionEnded(shouldResume: true, breakActive: false),
            "session interruption ended shouldResume=true breakActive=false"
        )
        XCTAssertEqual(
            PlaybackLog.interruptionEnded(shouldResume: false, breakActive: true),
            "session interruption ended shouldResume=false breakActive=true"
        )
        XCTAssertEqual(PlaybackLog.routeRemoved(), "session route removed")
        XCTAssertEqual(PlaybackLog.interludeStop(reason: .sourceRevoked), "interlude stop reason=sourceRevoked")
        XCTAssertEqual(PlaybackLog.interludeStop(reason: .interruption), "interlude stop reason=interruption")
        XCTAssertEqual(PlaybackLog.interludeStop(reason: .routeRemoved), "interlude stop reason=routeRemoved")
        XCTAssertEqual(PlaybackLog.songDeferred(index: 2), "song deferred index=2")
    }
}
