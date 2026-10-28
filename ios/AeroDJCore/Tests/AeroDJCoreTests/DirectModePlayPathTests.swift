#if DEBUG || AERODJ_P0_DIAG
import XCTest
@testable import AeroDJCore

/// P0 Experiment B level 8 (-Atlas): the selector reaching 8, the stack standing down there, and
/// the MusicKitService play-path trace (gating, format, sanitizing). Time is passed in.
final class DirectModePlayPathTests: XCTestCase {

    private let level8 = DirectModeLayerLevel(stored: 8)

    // MARK: - Selector

    func testLevelEightIsSelectableAndFiveToSevenStayUnreachable() {
        XCTAssertEqual(level8.value, 8)
        XCTAssertTrue(level8.routesThroughMusicKitService)
        for stored in [5, 6, 7, 9, 80] {
            XCTAssertEqual(DirectModeLayerLevel(stored: stored).value, 4, "stored \(stored)")
        }
        XCTAssertEqual(DirectModeLayerLevel.selectable, [0, 1, 2, 3, 4, 8])
        XCTAssertFalse((0...4).contains { DirectModeLayerLevel(stored: $0).routesThroughMusicKitService })
        XCTAssertEqual(level8.description, "8 (B1-B4 via MusicKitService)")
    }

    func testStepperGoesFourToEightAndBackAndStopsAtTheEnds() {
        XCTAssertEqual(DirectModeLayerLevel(stored: 3).next.value, 4)
        XCTAssertEqual(DirectModeLayerLevel(stored: 4).next.value, 8)
        XCTAssertEqual(level8.next.value, 8)
        XCTAssertEqual(level8.previous.value, 4)
        XCTAssertEqual(DirectModeLayerLevel.off.previous.value, 0)
    }

    func testLevelEightEnablesB1ToB4AndNeverAnUnwiredLayer() {
        XCTAssertEqual(level8.enabledLayers, [.coordinator, .queueBoundary, .confirm, .interruption])
        XCTAssertFalse(level8.enables(.djBreak))
        XCTAssertFalse(level8.enables(.speech))
        XCTAssertFalse(level8.enables(.narration))
    }

    func testAtLevelEightTheDirectModeStackDrivesNothing() {
        var s = DirectModeLayerStack(level: level8, songCount: 2)
        s.userCommand(.load, at: 0.1)
        s.userCommand(.play, at: 1)
        var actions = s.observe(status: .playing, position: 5, duration: 6, entryIndex: 0, at: 2)
        actions += s.observe(status: .stopped, position: 6, duration: 6, entryIndex: nil, at: 3)
        actions += s.handle(.interruptionBegan, at: 4)
        actions += s.handle(.routeChange(deviceRemoved: true), at: 5)
        XCTAssertEqual(actions, [], "MusicKitService is the only owner of the player at level 8")
        XCTAssertEqual(s.trace.map(\.description), ["+0.00s layers.level=8"])
        XCTAssertFalse(s.usesOneSongQueue)
        XCTAssertFalse(s.observesSessionNotifications)
    }

    // MARK: - Gating

    func testTraceRecordsNothingBelowLevelEight() {
        for n in 0...4 {
            var trace = DirectModePlayPathTrace(level: DirectModeLayerLevel(stored: n))
            trace.tapped(at: 1)
            trace.record(.setActiveStart, at: 1.1)
            trace.record(.interruptionBegan(reason: .default, wasSuspended: false), at: 1.2)
            XCTAssertFalse(trace.isEnabled)
            XCTAssertEqual(trace.entries, [], "level \(n)")
            XCTAssertNil(trace.lastTapAt)
        }
    }

    func testLevelEightLinesCarryClockAndSecondsSinceTheTap() {
        var trace = DirectModePlayPathTrace(level: level8)
        trace.record(.serviceEngaged, at: 2)
        trace.tapped(at: 10)
        trace.record(.setActiveSkipped, at: 10.01)
        trace.record(.prepareStart, at: 10.02)
        trace.record(.prepareOK, at: 10.5)
        trace.record(.playStart, at: 10.5)
        trace.record(.playOK, at: 11.33)
        trace.record(.afterPlay(.keepPlaying), at: 11.34)
        trace.record(.interruptionBegan(reason: .default, wasSuspended: false), at: 11.4)
        trace.record(.selfStartGate(.deferSelfStart), at: 11.41)
        trace.record(.sessionPolicy(.interruptionBegan, .suspendPlayback), at: 12)
        trace.record(.pausePlayerForBreak, at: 12)
        trace.record(.interruptionEnded(shouldResume: true), at: 13)
        trace.record(.remotePlayGatePause, at: 14)
        trace.record(.afterPlay(.pauseBecauseHeld), at: 15)
        // A line captured before the tap but delivered after it shows a negative offset.
        trace.record(.setActiveOK, at: 9.5)
        XCTAssertEqual(trace.entries.map(\.description), [
            "+2.00s path.L8 service.engaged tap=none",
            "+10.01s path.L8 setActive.skipped tap+0.01s",
            "+10.02s path.L8 prepareToPlay.start tap+0.02s",
            "+10.50s path.L8 prepareToPlay.ok tap+0.50s",
            "+10.50s path.L8 play.start tap+0.50s",
            "+11.33s path.L8 play.ok tap+1.33s",
            "+11.34s path.L8 afterPlay.keepPlaying tap+1.34s",
            "+11.40s path.L8 interruption.began reason=default wasSuspended=false tap+1.40s",
            "+11.41s path.L8 selfStartGate.deferSelfStart tap+1.41s",
            "+12.00s path.L8 sessionPolicy.interruptionBegan -> suspendPlayback tap+2.00s",
            "+12.00s path.L8 pausePlayerForBreak tap+2.00s",
            "+13.00s path.L8 interruption.ended shouldResume=true tap+3.00s",
            "+14.00s path.L8 remotePlayGate.pauseBecauseHeld tap+4.00s",
            "+15.00s path.L8 afterPlay.pauseBecauseHeld tap+5.00s",
            "+9.50s path.L8 setActive.ok tap-0.50s",
        ])
    }

    func testTraceIsBounded() {
        var trace = DirectModePlayPathTrace(level: level8)
        for i in 0..<(DirectModePlayPathTrace.capacity + 25) { trace.record(.playStart, at: Double(i)) }
        XCTAssertEqual(trace.entries.count, DirectModePlayPathTrace.capacity)
        XCTAssertEqual(trace.entries.first?.t, 25)
    }

    // MARK: - Sanitizing

    func testErrorTagKeepsOnlyASafeDomainAndTheCode() {
        XCTAssertEqual(DirectModeErrorTag(domain: "NSOSStatusErrorDomain", code: 560557684).description,
                       "domain=NSOSStatusErrorDomain code=560557684")
        let hostile = DirectModeErrorTag(domain: "My Song \"Hello\" by someone@example.com/token=abc", code: -1)
        XCTAssertEqual(hostile.domain, "MySongHellobysomeoneexample.comtokenabc")
        XCTAssertEqual(DirectModeErrorTag(domain: "  \n", code: 3).domain, "unknown")
        XCTAssertEqual(DirectModeErrorTag(domain: String(repeating: "a", count: 500), code: 0).domain.count,
                       DirectModeErrorTag.maxDomainLength)
        let ns = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                         userInfo: [NSLocalizedDescriptionKey: "Private Title"])
        XCTAssertEqual(DirectModeErrorTag(ns).description, "domain=AVFoundationErrorDomain code=-11800")
    }

    func testInterruptionReasonMapsRawValuesOnly() {
        XCTAssertEqual(DirectModeInterruptionReason(rawReason: nil), .absent)
        XCTAssertEqual(DirectModeInterruptionReason(rawReason: 0), .default)
        XCTAssertEqual(DirectModeInterruptionReason(rawReason: 1), .appWasSuspended)
        XCTAssertEqual(DirectModeInterruptionReason(rawReason: 2), .builtInMicMuted)
        XCTAssertEqual(DirectModeInterruptionReason(rawReason: 3), .sceneWasBackgrounded)
        XCTAssertEqual(DirectModeInterruptionReason(rawReason: 4), .routeDisconnected)
        XCTAssertEqual(DirectModeInterruptionReason(rawReason: 77), .other)
    }

    func testEveryLineIsLayerIdEnumsAndTimeOnly() {
        var trace = DirectModePlayPathTrace(level: level8)
        trace.tapped(at: 0)
        let tag = DirectModeErrorTag(domain: "Some \"Title\" here", code: 7)
        let events: [DirectModePlayPathEvent] = [
            .serviceEngaged, .setActiveSkipped, .setActiveStart, .setActiveOK, .setActiveThrew(tag),
            .prepareStart, .prepareOK, .prepareThrew(tag), .playStart, .playOK, .playThrew(tag),
            .interruptionBegan(reason: .routeDisconnected, wasSuspended: true),
            .interruptionEnded(shouldResume: false), .selfStartGate(.apply), .selfStartGate(.ignorePairedEnd),
            .sessionPolicy(.routeDeviceRemoved, .suspendPlayback), .sessionPolicy(.interruptionEndedShouldResume, .resumeIfPermitted),
            .afterPlay(.keepPlaying), .remotePlayGatePause, .pausePlayerForBreak,
        ]
        for (i, e) in events.enumerated() { trace.record(e, at: Double(i)) }
        let pattern = #"^\+\d+\.\d\ds path\.L8 [A-Za-z.=0-9_ >-]+ tap[+-]\d+\.\d\ds$"#
        for line in trace.entries.map(\.description) {
            XCTAssertNotNil(line.range(of: pattern, options: .regularExpression), line)
            XCTAssertFalse(line.contains("\""), line)  // free text cannot survive the domain filter intact
        }
    }

    // MARK: - Copy log

    func testMergedLogWithNoPathLinesIsTheSessionMergeAndPathLinesSortByTime() {
        var m = DirectModeMachine(songCount: 2)
        XCTAssertTrue(m.request(.load, at: 0.5))
        m.finished(.load, error: nil, at: 1)
        var s = DirectModeLayerStack(level: level8, songCount: 2)
        s.userCommand(.load, at: 0.5)
        let session = DirectModeSessionLayer(enabled: false)
        XCTAssertEqual(DirectModePlayPathTrace.mergedLog(m.log, s.trace, session.trace, []),
                       DirectModeSessionLayer.mergedLog(m.log, s.trace, session.trace))
        var path = DirectModePlayPathTrace(level: level8)
        path.record(.playOK, at: 1)
        path.record(.serviceEngaged, at: 0.75)
        XCTAssertEqual(DirectModePlayPathTrace.mergedLog(m.log, s.trace, session.trace, path.entries), [
            "+0.00s layers.level=8",
            "+0.50s pos=0.0 stopped cmd.load.requested",
            "+0.75s path.L8 service.engaged tap=none",
            "+1.00s pos=0.0 stopped cmd.load.ok",
            "+1.00s path.L8 play.ok tap=none",
        ])
    }
}
#endif
