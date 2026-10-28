import XCTest
@testable import AeroDJCore

/// Build 16 P0 (-Fry): song 1 ends, song 2 must be handed off. One-song MusicKit queues can end
/// in several shapes; every one of them must produce exactly one handoff to song 2.
final class QueueEndShapeTests: XCTestCase {
    private let duration: TimeInterval = 200

    /// Plays entry "a" from 0 to `lastPlaying` (1 s polls), then feeds `end` and returns every step.
    private func run(lastPlaying: TimeInterval, end: [PlaybackObservation]) -> [BoundaryStep] {
        var interpreter = BoundaryInterpreter()
        interpreter.userRequestedChange()
        var steps: [BoundaryStep] = []
        var t: TimeInterval = 0
        while t <= lastPlaying {
            let obs = PlaybackObservation(entryID: "a", isPlaying: true, position: t, duration: duration)
            if let s = interpreter.interpret(obs, queueIndex: 0, queueCount: 3) { steps.append(s) }
            t += 1
        }
        for obs in end {
            if let s = interpreter.interpret(obs, queueIndex: 0, queueCount: 3) { steps.append(s) }
        }
        return steps
    }

    private func assertOneHandoff(_ steps: [BoundaryStep], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(steps.count, 1, "steps: \(steps)", file: file, line: line)
        guard case .plannedHandoff(0, 1, _)? = steps.first else {
            return XCTFail("expected handoff 0 -> 1, got \(steps)", file: file, line: line)
        }
    }

    func testEntryClearedHandsOff() {
        assertOneHandoff(run(lastPlaying: 199.4, end: [.init(entryID: nil, isPlaying: false, position: 0, duration: duration)]))
    }

    func testPausedAtEndHandsOff() {
        assertOneHandoff(run(lastPlaying: 199.4, end: [.init(entryID: "a", isPlaying: false, position: 200, duration: duration)]))
    }

    /// MusicKit keeps the entry, stops, and rewinds the playhead to 0.
    func testPausedWithPlayheadResetHandsOff() {
        assertOneHandoff(run(lastPlaying: 199.4, end: [
            .init(entryID: "a", isPlaying: false, position: 0, duration: duration),
            .init(entryID: "a", isPlaying: false, position: 0, duration: duration),
        ]))
    }

    /// The playhead rewinds one poll before the status drops from playing.
    func testPlayheadResetBeforeStatusChangeHandsOff() {
        assertOneHandoff(run(lastPlaying: 199.4, end: [
            .init(entryID: "a", isPlaying: true, position: 0, duration: duration),
            .init(entryID: "a", isPlaying: false, position: 0, duration: duration),
        ]))
    }

    /// A user pause mid-song is never a handoff, even after the playhead is read as 0.
    func testMidSongStopIsNotHandoff() {
        let steps = run(lastPlaying: 80, end: [.init(entryID: "a", isPlaying: false, position: 0, duration: duration)])
        XCTAssertTrue(steps.isEmpty, "\(steps)")
    }
}
