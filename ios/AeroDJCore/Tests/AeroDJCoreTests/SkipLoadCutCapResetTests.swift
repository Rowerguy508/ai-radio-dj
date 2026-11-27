import XCTest
@testable import AeroDJCore

/// #585 (-Atlas): the one-rewind-cut cap is lifted by a clear of the skip's song, which is a real
/// Next (`takeSkipLoadCut()` resets it for a `.clear` cut). Without that reset, the next skip's
/// stall at 0:00 is reported as a stalled start instead of the rewound Next it is.
final class SkipLoadCutCapResetTests: XCTestCase {
    private let window = PlaybackBoundaryDetector.rewoundBeforePlayingStallSeconds

    /// Skip load, our `play()` returned, song-1 stalls at 0:00 for the whole start-confirm window:
    /// the rewind cut is reported once and the cap is spent.
    func testAClearCutOfTheNextLoadLiftsTheSpentRewindCutCap() {
        var b = BoundaryInterpreter()
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: 30.0, by: 1.0) {
            _ = b.interpret(PlaybackObservation(entryID: "song-0", isPlaying: true, position: position,
                                                duration: 200, uptime: t), queueIndex: 0, queueCount: 4)
            t += 1
        }
        b.setSkipLoadInFlight(true)
        b.userRequestedChange()
        b.noteOwnPlayReturned()
        XCTAssertNil(atStart(&b, "song-1", t))
        t += window
        XCTAssertNil(atStart(&b, "song-1", t))
        XCTAssertEqual(b.pendingSkipLoadCut, SkipLoadCut(shape: .rewind, targetSeenPlaying: false))
        XCTAssertTrue(b.takeSkipLoadCut(), "the first stall is the rewind cut")

        // The reloaded song is cleared before it plays: a real Next, so the cap starts over.
        t += 1
        XCTAssertNil(b.interpret(PlaybackObservation(entryID: nil, isPlaying: false, position: nil,
                                                     duration: nil, uptime: t), queueIndex: 1, queueCount: 4))
        XCTAssertEqual(b.pendingSkipLoadCut, SkipLoadCut(shape: .clear, targetSeenPlaying: false))
        XCTAssertTrue(b.takeSkipLoadCut())

        // The next skip's song stalls at 0:00 past the window: a rewound Next again, not a start report.
        b.userRequestedChange()
        b.setSkipLoadInFlight(true)
        b.noteOwnPlayReturned()
        t += 1
        XCTAssertNil(atStart(&b, "song-2", t))
        t += window
        XCTAssertNil(atStart(&b, "song-2", t))
        XCTAssertEqual(b.pendingSkipLoadCut, SkipLoadCut(shape: .rewind, targetSeenPlaying: false),
                       "a clear lifted the cap, so this stall is a rewind cut again")
        XCTAssertFalse(b.takeSkipStartStalled(), "the capped-load watch must not be armed once a clear lifted the cap")
        XCTAssertTrue(b.takeSkipLoadCut())
    }

    private func atStart(_ b: inout BoundaryInterpreter, _ entry: String, _ t: TimeInterval) -> BoundaryStep? {
        b.interpret(PlaybackObservation(entryID: entry, isPlaying: false, position: 0,
                                        duration: 200, uptime: t), queueIndex: 1, queueCount: 4)
    }
}
