#if DEBUG || AERODJ_P0_DIAG
import XCTest
@testable import AeroDJCore

/// P0 Experiment B (-Atlas): the cumulative layer selector and each wired layer. Time is passed in.
final class DirectModeLayersTests: XCTestCase {

    private func stack(_ level: Int) -> DirectModeLayerStack {
        DirectModeLayerStack(level: DirectModeLayerLevel(stored: level), songCount: 2)
    }

    private func lines(_ s: DirectModeLayerStack) -> [String] { s.trace.map(\.description) }

    // MARK: - Selector

    func testStoredLevelDefaultsToOffAndClampsToWiredLayers() {
        XCTAssertEqual(DirectModeLayerLevel(stored: 0), .off)
        XCTAssertTrue(DirectModeLayerLevel.off.isOff)
        XCTAssertEqual(DirectModeLayerLevel(stored: -3).value, 0)
        XCTAssertEqual(DirectModeLayerLevel(stored: 4).value, 4)
        XCTAssertEqual(DirectModeLayerLevel(stored: 5).value, 4, "an unwired level never turns on")
        XCTAssertEqual(DirectModeLayerLevel(stored: 99).value, 4)
        XCTAssertEqual(DirectModeLayerLevel.maxDefined, 7)
    }

    func testLevelsAreCumulative() {
        for n in 0...DirectModeLayerLevel.maxWired {
            let level = DirectModeLayerLevel(stored: n)
            XCTAssertEqual(level.enabledLayers.map(\.rawValue), Array(stride(from: 1, through: n, by: 1)))
        }
        XCTAssertTrue(DirectModeLayerLevel(stored: 3).enables(.coordinator))
        XCTAssertFalse(DirectModeLayerLevel(stored: 3).enables(.interruption))
    }

    func testOnlyB1ToB4AreWiredAndIdsMatchTheDoc() {
        XCTAssertEqual(DirectModeLayer.allCases.map(\.id), ["B1", "B2", "B3", "B4", "B5", "B6", "B7"])
        XCTAssertEqual(DirectModeLayer.allCases.filter(\.isWired), [.coordinator, .queueBoundary, .confirm, .interruption])
    }

    // MARK: - Level 0 is build 13

    func testLevelZeroDoesNothingButLogTheLevel() {
        var s = stack(0)
        s.userCommand(.load, at: 0.1)
        s.userCommand(.play, at: 1)
        var actions = s.observe(status: .playing, position: 5, duration: 6, entryIndex: 0, at: 2)
        actions += s.observe(status: .stopped, position: 6, duration: 6, entryIndex: nil, at: 3)
        actions += s.handle(.interruptionBegan, at: 4)
        actions += s.handle(.routeChange(deviceRemoved: true), at: 5)
        XCTAssertEqual(actions, [])
        XCTAssertEqual(lines(s), ["+0.00s layers.level=0"])
        XCTAssertFalse(s.usesOneSongQueue)
        XCTAssertFalse(s.observesSessionNotifications)
    }

    // MARK: - B1 coordinator

    func testB1RoutesEveryCommandThroughTheEngineAndNeverIssuesOne() {
        var s = stack(1)
        s.userCommand(.load, at: 0.1)
        s.userCommand(.play, at: 1)
        XCTAssertEqual(s.transport, .preparing)
        XCTAssertEqual(s.observe(status: .playing, position: 0.2, duration: 6, entryIndex: 0, at: 1.5), [])
        XCTAssertEqual(s.transport, .playing)
        s.userCommand(.pause, at: 2)
        s.userCommand(.resume, at: 3)
        s.userCommand(.next, at: 4)
        XCTAssertEqual(lines(s), [
            "+0.00s layers.level=1",
            "+0.10s layer.B1 routed.load transport=stopped",
            "+1.00s layer.B1 routed.play transport=preparing",
            "+1.50s layer.B1 transport=playing",
            "+2.00s layer.B1 routed.pause transport=paused",
            "+3.00s layer.B1 routed.resume transport=preparing",
            "+4.00s layer.B1 routed.next transport=preparing",
        ])
        XCTAssertFalse(s.usesOneSongQueue)
    }

    // MARK: - B2 queue / boundary

    func testB2NaturalEndLoadsTheNextSongOnceWithNoReplay() {
        var s = stack(2)
        XCTAssertTrue(s.usesOneSongQueue)
        s.userCommand(.load, at: 0)
        s.userCommand(.play, at: 1)
        var actions: [DirectModeLayerAction] = []
        for (i, pos) in [1.0, 3.0, 5.0].enumerated() {
            actions += s.observe(status: .playing, position: pos, duration: 6, entryIndex: 0, at: 2 + Double(i))
        }
        // The one-song queue ends: MusicKit clears the entry.
        actions += s.observe(status: .stopped, position: 6, duration: 6, entryIndex: nil, at: 6)
        XCTAssertEqual(actions, [.loadAndPlay(index: 1)])
        XCTAssertEqual(s.queueIndex, 1)
        // The controller loads song 1 (our own change) and it plays: no second boundary.
        var later: [DirectModeLayerAction] = []
        later += s.observe(status: .playing, position: 0.1, duration: 6, entryIndex: 1, at: 7)
        later += s.observe(status: .playing, position: 2.5, duration: 6, entryIndex: 1, at: 9)
        XCTAssertEqual(later, [], "no replay, no second queue change")
        XCTAssertEqual(lines(s).filter { $0.contains("handoff") }, ["+6.00s layer.B2 handoff.loaded"])
    }

    func testB2LastSongEndStopsAndLoadsNothing() {
        var s = stack(2)
        s.userCommand(.play, at: 0)
        s.userCommand(.next, at: 1)
        XCTAssertEqual(s.queueIndex, 1)
        var actions = s.observe(status: .playing, position: 3, duration: 6, entryIndex: 1, at: 2)
        actions += s.observe(status: .playing, position: 5, duration: 6, entryIndex: 1, at: 4)
        actions += s.observe(status: .stopped, position: 6, duration: 6, entryIndex: nil, at: 5)
        XCTAssertEqual(actions, [])
        XCTAssertTrue(lines(s).contains("+5.00s layer.B2 boundary.stopped"))
        XCTAssertEqual(s.transport, .stopped)
    }

    func testB2UserPauseNearTheEndIsNotABoundary() {
        var s = stack(2)
        s.userCommand(.play, at: 0)
        _ = s.observe(status: .playing, position: 5.5, duration: 6, entryIndex: 0, at: 1)
        s.userCommand(.pause, at: 1.1)
        let actions = s.observe(status: .paused, position: 5.6, duration: 6, entryIndex: 0, at: 1.5)
        XCTAssertEqual(actions, [])
        XCTAssertFalse(lines(s).contains { $0.contains("boundary") })
    }

    // MARK: - B3 confirm / timeout

    func testB3ReportsTheEightSecondDeadlineAndNeverPausesOrSkips() {
        var s = stack(3)
        s.userCommand(.play, at: 0)
        var actions: [DirectModeLayerAction] = []
        var t = 0.0
        while t < 9 {
            t += 0.25
            actions += s.observe(status: .paused, position: 0, duration: 6, entryIndex: 0, at: t)
        }
        XCTAssertEqual(actions, [], "the deadline only reports")
        XCTAssertTrue(s.startTimedOut)
        XCTAssertEqual(lines(s).filter { $0.contains("confirm.") }.map { String($0.split(separator: " ").last!) },
                       ["confirm.armed", "confirm.timeoutReported"])
        // A late `.playing` still confirms the same attempt.
        _ = s.observe(status: .playing, position: 0.3, duration: 6, entryIndex: 0, at: t + 0.5)
        XCTAssertEqual(s.transport, .playing)
        XCTAssertTrue(lines(s).last!.hasSuffix("transport=playing"))
        XCTAssertTrue(lines(s).contains { $0.hasSuffix("confirm.confirmed") })
    }

    func testB3NormalPlayConfirmsWithNoTimeoutLine() {
        var s = stack(3)
        s.userCommand(.play, at: 0)
        _ = s.observe(status: .paused, position: 0, duration: 6, entryIndex: 0, at: 0.5)
        _ = s.observe(status: .playing, position: 0.4, duration: 6, entryIndex: 0, at: 1.0)
        XCTAssertEqual(s.transport, .playing)
        XCTAssertFalse(lines(s).contains { $0.contains("timeoutReported") })
    }

    func testB3NewAttemptSupersedesTheOldWatchdog() {
        var s = stack(3)
        s.userCommand(.play, at: 0)
        s.userCommand(.next, at: 0.2)
        _ = s.observe(status: .playing, position: 0.1, duration: 6, entryIndex: 1, at: 0.8)
        XCTAssertEqual(lines(s).filter { $0.hasSuffix("confirm.armed") }.count, 2)
        XCTAssertEqual(s.transport, .playing)
    }

    // MARK: - B4 interruption / route

    func testB4CallPausesAndResumesOnlyWithShouldResumeAfterUserPlay() {
        var s = stack(4)
        XCTAssertTrue(s.observesSessionNotifications)
        s.userCommand(.play, at: 0)
        _ = s.observe(status: .playing, position: 1, duration: 60, entryIndex: 0, at: 0.5)
        XCTAssertEqual(s.handle(.interruptionBegan, at: 10), [.pause])
        XCTAssertEqual(s.transport, .paused)
        XCTAssertEqual(s.handle(.interruptionEnded(shouldResume: true), at: 20), [.resume])
        XCTAssertTrue(lines(s).contains("+10.00s layer.B4 session.interruptionBegan -> suspendPlayback"))
        XCTAssertTrue(lines(s).contains("+20.00s layer.B4 action.resume"))
    }

    func testB4NoAutoResumeWithoutShouldResume() {
        var s = stack(4)
        s.userCommand(.play, at: 0)
        XCTAssertEqual(s.handle(.interruptionBegan, at: 1), [.pause])
        XCTAssertEqual(s.handle(.interruptionEnded(shouldResume: false), at: 2), [])
    }

    func testB4NoAutoResumeWhenTheUserHadPaused() {
        var s = stack(4)
        s.userCommand(.play, at: 0)
        s.userCommand(.pause, at: 1)
        _ = s.handle(.interruptionBegan, at: 2)
        XCTAssertEqual(s.handle(.interruptionEnded(shouldResume: true), at: 3), [])
    }

    func testB4RouteLossPausesAndNeverAutoPlays() {
        var s = stack(4)
        s.userCommand(.play, at: 0)
        XCTAssertEqual(s.handle(.routeChange(deviceRemoved: true), at: 1), [.pause])
        XCTAssertEqual(s.handle(.routeChange(deviceRemoved: false), at: 2), [])
        XCTAssertEqual(s.handle(.interruptionEnded(shouldResume: true), at: 3), [], "route loss is not resumed")
        XCTAssertTrue(lines(s).contains("+1.00s layer.B4 session.routeDeviceRemoved -> suspendPlayback"))
    }

    func testLevelsBelowFourIgnoreSessionNotices() {
        var s = stack(3)
        s.userCommand(.play, at: 0)
        XCTAssertEqual(s.handle(.interruptionBegan, at: 1), [])
        XCTAssertFalse(lines(s).contains { $0.contains("layer.B4") })
    }

    // MARK: - Copy log

    func testMergedLogInterleavesByTimeWithDirectModeLinesFirstOnATie() {
        var m = DirectModeMachine(songCount: 2)
        XCTAssertTrue(m.request(.load, at: 0.5))
        m.finished(.load, error: nil, at: 1)
        var s = DirectModeLayerStack(level: DirectModeLayerLevel(stored: 1), songCount: 2)
        s.userCommand(.load, at: 0.5)
        XCTAssertEqual(DirectModeLayerStack.mergedLog(m.log, s.trace), [
            "+0.00s layers.level=1",
            "+0.50s pos=0.0 stopped cmd.load.requested",
            "+0.50s layer.B1 routed.load transport=stopped",
            "+1.00s pos=0.0 stopped cmd.load.ok",
        ])
    }

    // MARK: - Sanitizing

    func testTraceLinesCarryOnlyLayerIdEnumsAndTime() {
        var s = stack(4)
        s.userCommand(.load, at: 0)
        s.userCommand(.play, at: 1)
        _ = s.observe(status: .playing, position: 5, duration: 6, entryIndex: 0, at: 2)
        _ = s.observe(status: .stopped, position: 6, duration: 6, entryIndex: nil, at: 3)
        _ = s.handle(.interruptionBegan, at: 4)
        s.actionFailed(.loadAndPlay(index: 1), at: 5)
        let pattern = #"^\+\d+\.\d\ds (layer\.B[1-7] )?[A-Za-z.=0-9 >-]+$"#
        for line in lines(s) {
            XCTAssertNotNil(line.range(of: pattern, options: .regularExpression), line)
        }
    }
}
#endif
