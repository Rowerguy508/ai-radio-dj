#if DEBUG || AERODJ_P0_DIAG
import Foundation
import XCTest
@testable import AeroDJCore

/// TEMPORARY P0 diagnostics (-Fry): the on-screen event trace. Ring buffer, change-only
/// sampling, and sanitization (no track, catalog, library, entry or route string reaches a row).
final class P0EventTraceTests: XCTestCase {
    private let gates = P0EventTrace.Gates(mayAutoResume: true, pausedBySystem: false, userWantsPlayback: true)

    private func obs(_ entry: String?, playing: Bool, pos: TimeInterval?, dur: TimeInterval? = 214) -> PlaybackObservation {
        PlaybackObservation(entryID: entry, isPlaying: playing, position: pos, duration: dur)
    }

    /// One poll as `MusicKitService.pollPlaybackPosition` runs it: state before, interpret, state after.
    @discardableResult
    private func feed(_ trace: inout P0EventTrace, _ interpreter: inout BoundaryInterpreter,
                      _ o: PlaybackObservation, q: Int = 0, n: Int = 3, at t: Double) -> [P0TraceRow] {
        let before = P0DetectorState(interpreter)
        let step = interpreter.interpret(o, queueIndex: q, queueCount: n)
        return trace.poll(o, before: before, step: step, after: P0DetectorState(interpreter),
                          queueIndex: q, queueCount: n, at: t)
    }

    // MARK: Ring buffer

    func testKeepsOnlyTheLast30RowsOldestFirst() {
        var trace = P0EventTrace()
        for i in 0..<45 { trace.scenePhase(i.isMultiple(of: 2) ? .active : .inactive, at: Double(i)) }
        XCTAssertEqual(P0EventTrace.capacity, 30)
        XCTAssertEqual(trace.rows.count, 30)
        XCTAssertEqual(trace.rows.first?.id, 15)
        XCTAssertEqual(trace.rows.last?.id, 44)
        XCTAssertEqual(trace.rows.map(\.id), Array(15..<45))
    }

    func testClearEmptiesButIDsKeepIncreasing() {
        var trace = P0EventTrace()
        trace.scenePhase(.active, at: 1)
        trace.scenePhase(.background, at: 2)
        trace.clear()
        XCTAssertTrue(trace.rows.isEmpty)
        trace.scenePhase(.active, at: 3)
        XCTAssertEqual(trace.rows.map(\.id), [2])
    }

    func testTimestampIsRoundedToOneDecimal() {
        var trace = P0EventTrace()
        let row = trace.appLifecycle(.didEnterBackground, at: 12.3456)
        XCTAssertEqual(row.t, 12.3, accuracy: 1e-9)
        XCTAssertEqual(row.rendered, "   12.3 appLifecycle q=-/- phase=didEnterBackground")
    }

    // MARK: Change-only sampling

    func testSteadyPlaybackLogsOnlyTheFirstSample() {
        var trace = P0EventTrace()
        var interpreter = BoundaryInterpreter()
        for sec in 0..<100 {
            feed(&trace, &interpreter, obs("e1", playing: true, pos: Double(sec) + 10), n: 5, at: Double(sec))
        }
        XCTAssertEqual(trace.rows.map(\.rendered), [
            "    0.0 sample q=0/5 playing=1 entry=1 entryChanged=0 pos=10.0 dur=214.0 furthest=10.0 wasPlaying=0 userChangePending=0 reachedEnd=0 result=none",
        ])
    }

    /// Orion: a stuck state never changes, so the last 3 polls are kept on every poll.
    func testLastThreePollsUpdateOnUnchangedPolls() {
        var trace = P0EventTrace()
        var interpreter = BoundaryInterpreter()
        // Status stuck at .playing with the position frozen short of the duration.
        for sec in 0..<10 {
            feed(&trace, &interpreter, obs("e1", playing: true, pos: 120), at: Double(sec))
        }
        XCTAssertEqual(trace.rows.count, 1, "nothing changed, so one sample row")
        XCTAssertEqual(trace.lastPolls.count, P0EventTrace.lastPollCount)
        XCTAssertEqual(trace.lastPolls.map(\.t), [7, 8, 9])
        XCTAssertEqual(trace.lastPolls.last?.rendered,
                       "    9.0 lastPoll q=0/3 wasPlaying=1 playing=1 pos=120.0 dur=214.0 furthest=120.0 reachedEnd=0 userChangePending=0 result=none intReason=- intAge=- sincePoll=1.0 played=9")
        trace.interruption(began: true, shouldResume: nil, reason: .appWasSuspended,
                           audio: .init(otherAudio: true, secondaryHint: false), at: 9.5)
        feed(&trace, &interpreter, obs("e1", playing: true, pos: 120), at: 13.2)
        XCTAssertEqual(trace.lastPolls.map(\.t), [8, 9, 13.2])
        XCTAssertEqual(trace.lastPolls.last?.detail,
                       "wasPlaying=1 playing=1 pos=120.0 dur=214.0 furthest=120.0 reachedEnd=0 userChangePending=0 result=none intReason=appWasSuspended intAge=4 sincePoll=4.2 played=13")
        // Played time restarts for a new entry.
        feed(&trace, &interpreter, obs("e2", playing: true, pos: 0.4), at: 14.2)
        XCTAssertTrue(trace.lastPolls.last?.detail.hasSuffix("sincePoll=1.0 played=0") ?? false)
        trace.clear()
        XCTAssertTrue(trace.lastPolls.isEmpty)
    }

    func testMissingDurationWhilePlayingIsLoggedOncePerEntry() {
        var sampler = P0PollSampler()
        _ = sampler.consume(obs("e1", playing: false, pos: 0, dur: nil), at: 0)
        XCTAssertTrue(sampler.consume(obs("e1", playing: true, pos: 1, dur: nil), at: 1).durationMissing)
        XCTAssertFalse(sampler.consume(obs("e1", playing: true, pos: 2, dur: nil), at: 2).isWorthARow)
        XCTAssertTrue(sampler.consume(obs("e2", playing: true, pos: 0, dur: nil), at: 3).durationMissing)
    }

    func testDetectorStateIsReadable() {
        var interpreter = BoundaryInterpreter()
        XCTAssertEqual(P0DetectorState(interpreter),
                       P0DetectorState(furthest: nil, wasPlaying: false, userChangePending: false, noProgressEndPending: false))
        _ = interpreter.interpret(obs("e1", playing: true, pos: 0.5), queueIndex: 0, queueCount: 3)
        interpreter.userRequestedChange()
        XCTAssertEqual(P0DetectorState(interpreter),
                       P0DetectorState(furthest: 0.5, wasPlaying: true, userChangePending: true, noProgressEndPending: false))
        // A clear before 2 s of progress, without an app change, leaves noProgressEnd pending.
        var fresh = BoundaryInterpreter()
        _ = fresh.interpret(obs("e1", playing: true, pos: 0.5), queueIndex: 0, queueCount: 3)
        _ = fresh.interpret(obs(nil, playing: false, pos: nil), queueIndex: 0, queueCount: 3)
        XCTAssertTrue(P0DetectorState(fresh).noProgressEndPending)
        var trace = P0EventTrace()
        var again = BoundaryInterpreter()
        feed(&trace, &again, obs("e1", playing: true, pos: 0.5), at: 0)
        let rows = feed(&trace, &again, obs(nil, playing: false, pos: nil), at: 1)
        XCTAssertEqual(rows.last?.detail,
                       "playing=0 entry=0 entryChanged=1 pos=- dur=214.0 furthest=- wasPlaying=1 userChangePending=0 reachedEnd=0 result=noProgressEnd")
    }

    func testLast5SecondsAreAlwaysLogged() {
        var sampler = P0PollSampler()
        _ = sampler.consume(obs("e1", playing: true, pos: 200), at: 0)
        XCTAssertFalse(sampler.consume(obs("e1", playing: true, pos: 208), at: 1).isWorthARow)
        XCTAssertTrue(sampler.consume(obs("e1", playing: true, pos: 209), at: 2).nearEnd)
        XCTAssertTrue(sampler.consume(obs("e1", playing: true, pos: 213), at: 3).nearEnd)
    }

    func testPlayingFlipEntryChangesAndRewindAreLogged() {
        var sampler = P0PollSampler()
        _ = sampler.consume(obs("e1", playing: true, pos: 100), at: 0)
        XCTAssertTrue(sampler.consume(obs("e1", playing: false, pos: 101), at: 1).playingFlipped)
        let rewind = sampler.consume(obs("e1", playing: false, pos: 0), at: 2)
        XCTAssertTrue(rewind.positionBackwards)
        XCTAssertFalse(rewind.playingFlipped)
        let cleared = sampler.consume(obs(nil, playing: false, pos: nil), at: 3)
        XCTAssertTrue(cleared.entryPresenceChanged)
        XCTAssertFalse(cleared.entryIdentityChanged)
        XCTAssertTrue(sampler.consume(obs("e2", playing: false, pos: 0), at: 4).entryPresenceChanged)
        let swapped = sampler.consume(obs("e3", playing: false, pos: 0), at: 5)
        XCTAssertTrue(swapped.entryIdentityChanged)
        XCTAssertFalse(swapped.positionBackwards)
        XCTAssertFalse(sampler.consume(obs("e3", playing: false, pos: 0), at: 6).isWorthARow)
    }

    func testPollGapIsReportedWithOneDecimal() {
        var trace = P0EventTrace()
        var interpreter = BoundaryInterpreter()
        feed(&trace, &interpreter, obs("e1", playing: true, pos: 50, dur: 240), n: 2, at: 10)
        feed(&trace, &interpreter, obs("e1", playing: true, pos: 51, dur: 240), n: 2, at: 11)
        feed(&trace, &interpreter, obs("e1", playing: true, pos: 52, dur: 240), n: 2, at: 13.4)
        XCTAssertEqual(trace.rows.count, 1, "2.4 s is under the threshold")
        let rows = feed(&trace, &interpreter, obs("e1", playing: true, pos: 230, dur: 240), n: 2, at: 190.2)
        XCTAssertEqual(rows.map(\.event), [.pollGap, .sample])
        XCTAssertEqual(rows[0].detail, "gap=176.8")
        XCTAssertEqual(trace.rows.count, 3)
    }

    /// The owner's symptom, played through the real interpreter: song 1 ends, the entry is
    /// kept and rewound. Every step of the handoff gets a row.
    func testSongEndThroughTheInterpreterLogsTheHandoff() {
        var trace = P0EventTrace()
        var interpreter = BoundaryInterpreter()
        let samples: [PlaybackObservation] = [
            obs("e1", playing: true, pos: 205), obs("e1", playing: true, pos: 210),
            obs("e1", playing: true, pos: 213), obs("e1", playing: false, pos: 0),
        ]
        for (i, sample) in samples.enumerated() { feed(&trace, &interpreter, sample, at: Double(i)) }
        XCTAssertEqual(trace.rows.suffix(2).map(\.rendered), [
            "    3.0 sample q=0/3 playing=0 entry=1 entryChanged=0 pos=0.0 dur=214.0 furthest=213.0 wasPlaying=1 userChangePending=0 reachedEnd=1 result=plannedHandoff back=1",
            "    3.0 boundaryStep q=0/3 step=plannedHandoff finished=0 next=1",
        ])
    }

    func testStartPathRows() {
        var trace = P0EventTrace()
        let held = P0EventTrace.Gates(mayAutoResume: false, pausedBySystem: true, userWantsPlayback: true)
        XCTAssertEqual(trace.startNextTrack(.called, after: 0, queueCount: 3, gates: held, at: 1).rendered,
                       "    1.0 startNextTrack q=0/3 after=0 outcome=called mayAutoResume=0 pausedBySystem=1 userWantsPlayback=1")
        XCTAssertEqual(trace.startNextTrack(.takeNext(false), after: 0, queueCount: 3, gates: held, at: 1).detail,
                       "after=0 takeNext=0 mayAutoResume=0 pausedBySystem=1 userWantsPlayback=1")
        XCTAssertEqual(trace.startTrack(.deferredSilently, index: 1, queueCount: 3, userInitiated: false,
                                        gates: held, at: 2).detail,
                       "index=1 outcome=deferredSilently userInitiated=0 mayAutoResume=0 pausedBySystem=1 userWantsPlayback=1")
        XCTAssertEqual(trace.onBoundary(.naturalEnd(finishedEntryID: "e1"), finishedIndex: 0, at: 3).detail,
                       "result=naturalEnd finished=0")
        XCTAssertEqual(trace.naturalBoundary(.noBreak, afterTrack: 0, at: 3).detail, "result=noBreak after=0")
        let audio = P0EventTrace.SessionAudio(otherAudio: false, secondaryHint: true)
        XCTAssertEqual(trace.interruption(began: true, shouldResume: nil, reason: .default, audio: audio, at: 5).detail,
                       "began=1 shouldResume=- reason=default otherAudio=0 secondaryHint=1")
        XCTAssertEqual(trace.sessionNotice(.interruptionEnded(shouldResume: true), gate: .ignorePairedEnd, audio: audio, at: 6).detail,
                       "notice=interruptionEnded shouldResume=1 gate=ignorePairedEnd otherAudio=0 secondaryHint=1")
        XCTAssertEqual(trace.sessionNotice(.routeChanged(.oldDeviceUnavailable), gate: .apply, audio: audio, at: 6).detail,
                       "notice=routeChanged deviceRemoved=1 gate=apply otherAudio=0 secondaryHint=1")
        XCTAssertEqual(trace.sessionNotice(.interruptionBegan, gate: .deferSelfStart, audio: audio, at: 6).detail,
                       "notice=interruptionBegan gate=deferSelfStart otherAudio=0 secondaryHint=1")
    }

    // MARK: Sanitization

    /// Sentinel / Orion merge gate: real-looking track and route strings go through every
    /// entry point that can carry one, and none appears in any rendered row.
    func testNoTrackOrRouteStringReachesAnyRow() {
        let title = "Bohemian Rhapsody"
        let artist = "Queen"
        let catalogID = "1440857781"
        let libraryID = "i.abc123"
        let port = "AirPods Pro"
        let forbidden = [title, artist, catalogID, libraryID, port, "Rhapsody", "abc123", "AirPods"]
        var trace = P0EventTrace()
        var interpreter = BoundaryInterpreter()
        let feeds: [PlaybackObservation] = [
            obs(catalogID, playing: true, pos: 3), obs(catalogID, playing: true, pos: 212),
            obs(libraryID, playing: true, pos: 0.5), obs(libraryID, playing: true, pos: 213),
            obs(libraryID, playing: false, pos: 0), obs(nil, playing: false, pos: nil, dur: nil),
            obs("\(title) - \(artist)", playing: true, pos: 1),
        ]
        for (i, f) in feeds.enumerated() { feed(&trace, &interpreter, f, q: i % 3, at: Double(i)) }
        let state = P0DetectorState(interpreter)
        for boundary in [PlaybackBoundary.naturalEnd(finishedEntryID: libraryID), .queueFinished(lastEntryID: catalogID)] {
            for step in [BoundaryStep.advancedEntry(finishedIndex: 0, boundary: boundary),
                         .plannedHandoff(finishedIndex: 0, nextIndex: 1, boundary: boundary),
                         .stopped(finishedIndex: 2, boundary: boundary)] {
                trace.poll(obs(libraryID, playing: false, pos: 0), before: state, step: step, after: state,
                           queueIndex: 0, queueCount: 3, at: 10)
            }
            trace.onBoundary(boundary, finishedIndex: 0, at: 11)
        }
        trace.beginPoll(obs(catalogID, playing: true, pos: 5), before: state, queueIndex: 0, queueCount: 3, at: 11)
        trace.remoteGatePause(queueIndex: 0, queueCount: 3, gates: gates, at: 11)
        let audio = P0EventTrace.SessionAudio(otherAudio: true, secondaryHint: true)
        for notice in [AudioSessionNotice.interruptionBegan, .interruptionEnded(shouldResume: false),
                       .routeChange(deviceRemoved: true), .routeChange(deviceRemoved: false)] {
            trace.sessionNotice(notice, gate: .apply, audio: audio, at: 12)
        }
        let error = PlaybackErrorCode(typeName: title, domain: port, code: -7007)
        trace.startTrack(.error(error), index: 1, queueCount: 3, userInitiated: true, gates: gates, at: 12)
        let nsError = NSError(domain: "\(port) \(catalogID)", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "\(title) by \(artist)"])
        trace.startTrack(.error(PlaybackErrorCode(nsError)), index: 1, queueCount: 3, userInitiated: false, gates: gates, at: 12)
        trace.interruption(began: true, shouldResume: nil, reason: .routeDisconnected, audio: audio, at: 13)
        feed(&trace, &interpreter, obs(catalogID, playing: true, pos: 6), at: 14)
        let all = trace.rows + trace.lastPolls
        XCTAssertEqual(trace.lastPolls.count, 3)
        let rendered = all.map(\.rendered) + all.map(\.detail)
        XCTAssertGreaterThan(trace.rows.count, 10)
        for row in rendered {
            for needle in forbidden {
                XCTAssertFalse(row.contains(needle), "\(needle) leaked into: \(row)")
            }
        }
        XCTAssertTrue(trace.rows.contains { $0.detail == "index=1 outcome=error code=-7007 userInitiated=1 mayAutoResume=1 pausedBySystem=0 userWantsPlayback=1" })
    }

    /// Every row of every entry point has the closed shape: t, event, q, then enum keys with a
    /// bool, an integer, `-` or a reason-code enum. No free text can fit.
    func testEveryRowHasTheClosedShape() {
        var trace = P0EventTrace()
        var interpreter = BoundaryInterpreter()
        var shapes: [P0TraceRow] = []
        for (i, o) in [obs("x", playing: true, pos: 1), obs("x", playing: true, pos: 213, dur: nil),
                       obs("x", playing: false, pos: 213), obs(nil, playing: false, pos: nil)].enumerated() {
            shapes += feed(&trace, &interpreter, o, n: 1, at: Double(i) * 4)
        }
        shapes += trace.lastPolls
        trace.beginPoll(obs("x", playing: true, pos: 3), before: P0DetectorState(interpreter), queueIndex: 0, queueCount: 1, at: 20)
        trace.remoteGatePause(queueIndex: 0, queueCount: 1, gates: gates, at: 20)
        trace.onBoundary(.queueFinished(lastEntryID: "x"), finishedIndex: 0, at: 9)
        for r in [P0EventTrace.BreakResult.breakPrepared, .noBreak, .interludeSpeaking] {
            trace.naturalBoundary(r, afterTrack: 0, at: 9)
        }
        for s in [P0EventTrace.NextStage.called, .takeNext(true), .indexOK(false)] {
            trace.startNextTrack(s, after: 0, queueCount: 1, gates: gates, at: 9)
        }
        shapes += trace.rows
        trace.clear()
        let outcomes: [P0EventTrace.StartOutcome] = [.started, .deferredSilently, .deferAndReport, .refused,
                                                     .superseded, .notQueued, .autoplayOff, .songUnavailable,
                                                     .error(PlaybackErrorCode(typeName: "T", domain: "D", code: 1))]
        for o in outcomes { trace.startTrack(o, index: 0, queueCount: 1, userInitiated: false, gates: gates, at: 9) }
        let audio = P0EventTrace.SessionAudio(otherAudio: false, secondaryHint: false)
        for r in [P0EventTrace.InterruptionReason.default, .appWasSuspended, .builtInMicMuted, .routeDisconnected, .unknown] {
            trace.interruption(began: true, shouldResume: nil, reason: r, audio: audio, at: 9)
        }
        trace.interruption(began: false, shouldResume: true, reason: nil, audio: audio, at: 9)
        trace.sessionNotice(.routeChange(deviceRemoved: true), gate: .ignorePairedEnd, audio: audio, at: 9)
        trace.scenePhase(.background, at: 9)
        trace.appLifecycle(.willEnterForeground, at: 9)
        shapes += trace.rows
        XCTAssertEqual(Set(shapes.map(\.event)), Set(P0TraceEvent.allCases), "every event kind is checked")

        let keys = Set(P0TraceKey.allCases.map(\.rawValue))
        let codes = Set(P0TraceCode.allCases.map(\.rawValue))
        let events = Set(P0TraceEvent.allCases.map(\.rawValue))
        for row in shapes {
            let parts = row.rendered.split(separator: " ").map(String.init)
            XCTAssertNotNil(Double(parts[0]), row.rendered)
            XCTAssertTrue(events.contains(parts[1]), row.rendered)
            XCTAssertTrue(parts[2].hasPrefix("q="), row.rendered)
            for pair in parts.dropFirst(3) {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                XCTAssertEqual(kv.count, 2, row.rendered)
                XCTAssertTrue(keys.contains(kv[0]), "key \(kv[0]) in \(row.rendered)")
                let v = kv[1]
                let number = v.range(of: #"^-?[0-9]+(\.[0-9])?$"#, options: .regularExpression) != nil
                XCTAssertTrue(v == "-" || number || codes.contains(v), "value \(v) in \(row.rendered)")
            }
        }
    }
}
#endif
