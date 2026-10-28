import XCTest
@testable import AeroDJCore

/// #125, Echo's review: a timed-out (or decode-failed) break must stop its clip before the
/// session is released, so the clip can't mix over the next song. -Atlas
final class BreakEndSequenceTests: XCTestCase {
    func testTimedOutBreakStopsTheClipBeforeTheSessionIsReleased() {
        let steps = BreakEndSequence.steps(for: .timeout)
        XCTAssertEqual(steps, [.stopClip, .finishBreak, .releaseSession])
    }

    func testDecodeErrorStopsTheClipBeforeTheSessionIsReleased() {
        XCTAssertEqual(BreakEndSequence.steps(for: .decodeError), [.stopClip, .finishBreak, .releaseSession])
    }

    func testEveryEndWithAClipThatMayStillPlayStopsItFirstAndReleasesLast() {
        for trigger in BreakEndTrigger.allCases {
            let steps = BreakEndSequence.steps(for: trigger)
            XCTAssertEqual(steps.last, .releaseSession, "\(trigger)")
            XCTAssertEqual(steps.filter { $0 == .releaseSession }.count, 1, "\(trigger)")
            guard BreakEndSequence.clipMayStillPlay(trigger) else { continue }
            let stop = steps.firstIndex(of: .stopClip)
            let finish = steps.firstIndex(of: .finishBreak)
            let release = steps.firstIndex(of: .releaseSession)
            XCTAssertNotNil(stop, "\(trigger): clip must be stopped")
            XCTAssertLessThan(stop!, finish!, "\(trigger)")
            XCTAssertLessThan(stop!, release!, "\(trigger)")
        }
    }

    func testNaturalFinishDoesNotNeedAStop() {
        XCTAssertFalse(BreakEndSequence.clipMayStillPlay(.naturalFinish))
        XCTAssertEqual(BreakEndSequence.steps(for: .naturalFinish), [.finishBreak, .releaseSession])
    }
}
