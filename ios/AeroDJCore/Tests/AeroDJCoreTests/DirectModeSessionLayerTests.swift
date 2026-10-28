// TEMPORARY P0 Experiment B "S" toggle tests (remove with #121 / #133). -Fry
#if DEBUG || AERODJ_P0_DIAG
import XCTest
@testable import AeroDJCore

final class DirectModeSessionLayerTests: XCTestCase {
    func testOffAsksForNothingAndRecordsNothing() {
        var s = DirectModeSessionLayer(enabled: false)
        XCTAssertFalse(s.beforePlay(at: 1))
        XCTAssertFalse(s.needsCategory)
        XCTAssertFalse(s.afterPlay(at: 1))
        XCTAssertFalse(s.handle(.interruptionBegan, at: 2))
        XCTAssertFalse(s.observePlaying(at: 3))
        s.userPause(at: 4)
        XCTAssertTrue(s.trace.isEmpty)
    }

    func testOnSetsCategoryOnceAndActivatesEveryPlay() {
        var s = DirectModeSessionLayer(enabled: true, at: 0)
        XCTAssertTrue(s.beforePlay(at: 1))
        XCTAssertTrue(s.needsCategory)
        s.categoryResult(ok: true, at: 1)
        s.activationResult(ok: true, at: 1)
        XCTAssertFalse(s.afterPlay(at: 1.2))
        XCTAssertTrue(s.beforePlay(at: 5))
        XCTAssertFalse(s.needsCategory)
        XCTAssertEqual(s.trace.map(\.event), [
            .enabled, .setCategory(ok: true), .setActive(ok: true), .guardAfterPlay(keepPlaying: true),
        ])
    }

    /// Suspect 1: an interruption that lands right after play() holds and pauses, and the poll
    /// keeps the player paused, like build 14.
    func testSelfInterruptionAfterPlayPausesAndPollKeepsItPaused() {
        var s = DirectModeSessionLayer(enabled: true)
        _ = s.beforePlay(at: 1)
        XCTAssertFalse(s.afterPlay(at: 1.1))
        XCTAssertTrue(s.handle(.interruptionBegan, at: 1.3))
        XCTAssertTrue(s.observePlaying(at: 1.5))
        XCTAssertTrue(s.observePlaying(at: 1.75))
        XCTAssertEqual(s.trace.filter { $0.event == .remoteGatePause }.count, 1, "latched per held episode")
        XCTAssertTrue(s.trace.contains { $0.event == .notice(.interruptionBegan, .suspendPlayback) })
    }

    /// An interruption that lands while play() is still in flight is caught by the start guard.
    func testInterruptionBeforePlayReturnsPausesViaStartGuard() {
        var s = DirectModeSessionLayer(enabled: true)
        _ = s.beforePlay(at: 1)
        _ = s.handle(.interruptionBegan, at: 1.05)
        XCTAssertTrue(s.afterPlay(at: 1.1))
        XCTAssertEqual(s.trace.last?.event, .guardAfterPlay(keepPlaying: false))
    }

    func testUserPlayClearsTheHold() {
        var s = DirectModeSessionLayer(enabled: true)
        _ = s.beforePlay(at: 1)
        _ = s.handle(.interruptionBegan, at: 1.3)
        _ = s.beforePlay(at: 4)
        XCTAssertFalse(s.afterPlay(at: 4.1))
        XCTAssertFalse(s.observePlaying(at: 4.3))
    }

    func testUserPauseMakesPollPause() {
        var s = DirectModeSessionLayer(enabled: true)
        _ = s.beforePlay(at: 1)
        s.userPause(at: 2)
        XCTAssertTrue(s.observePlaying(at: 2.25))
    }

    func testTraceIsSanitized() {
        var s = DirectModeSessionLayer(enabled: true, at: 0)
        _ = s.beforePlay(at: 1)
        s.categoryResult(ok: true, at: 1)
        s.activationResult(ok: false, at: 1)
        _ = s.handle(.routeChanged(.oldDeviceUnavailable), at: 2)
        let lines = s.trace.map(\.description)
        XCTAssertEqual(lines[2], "   1.00 S setActive.true ok=false")
        XCTAssertEqual(lines[3], "   2.00 S session.routeDeviceRemoved -> suspendPlayback")
    }

    func testMergedLogWithEmptySessionMatchesLayerMerge() {
        var s = DirectModeSessionLayer(enabled: true, at: 0.5)
        _ = s.beforePlay(at: 1)
        s.activationResult(ok: true, at: 1)
        let merged = DirectModeSessionLayer.mergedLog([], [], s.trace)
        XCTAssertEqual(merged, s.trace.map(\.description))
        XCTAssertEqual(DirectModeSessionLayer.mergedLog([], [], []), DirectModeLayerStack.mergedLog([], []))
    }
}
#endif
