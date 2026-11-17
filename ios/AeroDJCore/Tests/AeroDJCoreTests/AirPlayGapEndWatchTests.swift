import Foundation
import XCTest
@testable import AeroDJCore

/// #526 PR A (-Echo): the tight AirPlay gap break. The only dead air the app added itself on the
/// AirPlay gap path was the 1 s boundary poll before the break. These tests pin the end watch that
/// narrows it on AirPlay only, on an injected clock (the observations' `uptime`), through the real
/// `BoundaryInterpreter`. NOT device evidence: AirPlay timing and naturalness need the owner's check.
final class AirPlayGapEndWatchTests: XCTestCase {
    private static let duration: TimeInterval = 180

    /// How MusicKit shows the end of a one-song queue.
    private enum EndShape: CaseIterable {
        case clear          // the queue emptied
        case rewind         // the entry stays, playhead back at 0
        case stoppedAtEnd   // the entry stays, stopped in the end window (ambiguous: also a stall)
    }

    /// The player at uptime `t` for a song that started at 0 and ends at `duration`.
    private static func player(at t: TimeInterval, end: EndShape, endsAt: TimeInterval = duration) -> PlaybackObservation {
        if t < endsAt {
            return PlaybackObservation(entryID: "a", isPlaying: true, position: t, duration: duration, uptime: t)
        }
        switch end {
        case .clear:
            return PlaybackObservation(entryID: nil, isPlaying: false, position: nil, duration: duration, uptime: t)
        case .rewind:
            return PlaybackObservation(entryID: "a", isPlaying: false, position: 0, duration: duration, uptime: t)
        case .stoppedAtEnd:
            return PlaybackObservation(entryID: "a", isPlaying: false, position: endsAt - 0.2, duration: duration, uptime: t)
        }
    }

    /// Runs the app's two read streams on the injected clock: the regular 1 s poll (phase `phase`)
    /// and, when `airPlayGapRoute`, the watch's 0.1 s reads. Every regular poll and every `.pollNow`
    /// feeds the real interpreter, as `MusicKitService.pollPlaybackPosition` does. Returns the
    /// uptime of the reported boundary and how many reads the watch made.
    private static func simulate(end: EndShape, phase: TimeInterval, airPlayGapRoute: Bool,
                                 endsAt: TimeInterval = duration) -> (boundaryAt: TimeInterval?, watchReads: Int, step: BoundaryStep?) {
        var interpreter = BoundaryInterpreter()
        var watch = AirPlayGapEndWatch()
        var watchNext: TimeInterval?
        var watchReads = 0
        var regular = phase
        func read(_ t: TimeInterval) -> PlaybackObservation { player(at: t, end: end, endsAt: endsAt) }
        func poll(_ t: TimeInterval) -> BoundaryStep? {
            let sample = read(t)
            if watch.regularSample(sample, airPlayGapRoute: airPlayGapRoute) {
                if watchNext == nil { watchNext = t + AirPlayGapEndWatch.watchPollSeconds }
            } else {
                watchNext = nil
            }
            return interpreter.interpret(sample, queueIndex: 0, queueCount: 2)
        }
        let horizon = duration + 10
        while regular < horizon || (watchNext.map { $0 < horizon } ?? false) {
            if let w = watchNext, w < regular {
                watchReads += 1
                switch watch.step(read(w)) {
                case .keepWatching:
                    watchNext = w + AirPlayGapEndWatch.watchPollSeconds
                case .stop:
                    watch.disarm(); watchNext = nil
                case .pollNow:
                    watch.disarm(); watchNext = nil
                    if let step = poll(w) { return (w, watchReads, step) }
                }
            } else {
                if let step = poll(regular) { return (regular, watchReads, step) }
                regular += AirPlayGapEndWatch.regularPollSeconds
            }
        }
        return (nil, watchReads, nil)
    }

    private static let phases: [TimeInterval] = stride(from: 0.0, to: 1.0, by: 0.05).map { $0 }

    // MARK: Timings

    func testTheGapTimingsArePinned() {
        XCTAssertEqual(AirPlayGapEndWatch.regularPollSeconds, 1.0, "today's boundary poll, unchanged")
        XCTAssertEqual(AirPlayGapEndWatch.watchPollSeconds, 0.1)
        XCTAssertEqual(AirPlayGapEndWatch.leadSeconds, 3.0)
        XCTAssertGreaterThan(AirPlayGapEndWatch.leadSeconds,
                             AirPlayGapEndWatch.regularPollSeconds + PlaybackBoundaryDetector.endWindowSeconds,
                             "the last regular sample before an end always arms the watch")
        XCTAssertEqual(AirPlayGapEndWatch.worstCaseDetectionBefore, 1.0)
        XCTAssertEqual(AirPlayGapEndWatch.worstCaseDetectionAfter, 0.1)
    }

    /// Before: on every route the end was seen 0 to 1 s after MusicKit showed it (mean ~0.5 s).
    /// After, on AirPlay, for the clear and rewind shapes: at most one watch read (0.1 s).
    func testOnAirPlayACleanEndIsSeenWithinOneWatchReadInsteadOfOneSecond() throws {
        for end in [EndShape.clear, .rewind] {
            var before: [TimeInterval] = [], after: [TimeInterval] = []
            for phase in Self.phases {
                let old = Self.simulate(end: end, phase: phase, airPlayGapRoute: false)
                let new = Self.simulate(end: end, phase: phase, airPlayGapRoute: true)
                let oldAt = try XCTUnwrap(old.boundaryAt, "\(end) phase \(phase)")
                let newAt = try XCTUnwrap(new.boundaryAt, "\(end) phase \(phase)")
                XCTAssertEqual(old.step, new.step, "same boundary, same detector decision")
                XCTAssertEqual(old.watchReads, 0, "off the AirPlay gap route the watch never reads")
                before.append(oldAt - Self.duration)
                after.append(newAt - Self.duration)
                XCTAssertGreaterThanOrEqual(newAt, Self.duration - 1e-9, "never before MusicKit shows the end")
            }
            XCTAssertLessThanOrEqual(before.max()!, AirPlayGapEndWatch.worstCaseDetectionBefore + 1e-9)
            XCTAssertGreaterThan(before.max()!, 0.9, "today's 1 s poll can wait almost a second")
            XCTAssertLessThanOrEqual(after.max()!, AirPlayGapEndWatch.worstCaseDetectionAfter + 1e-9, "\(end)")
            let meanBefore = before.reduce(0, +) / Double(before.count)
            let meanAfter = after.reduce(0, +) / Double(after.count)
            XCTAssertGreaterThan(meanBefore, 0.4)
            XCTAssertLessThan(meanAfter, 0.1)
        }
    }

    /// A stop in the end window with the entry kept may be an AirPlay stall: the watch never acts
    /// on it, so it is judged by the 1 s poll exactly as today (same time, same decision).
    func testAStopAtTheEndWithTheEntryKeptIsLeftToTodaysPoll() {
        for phase in Self.phases {
            let old = Self.simulate(end: .stoppedAtEnd, phase: phase, airPlayGapRoute: false)
            let new = Self.simulate(end: .stoppedAtEnd, phase: phase, airPlayGapRoute: true)
            XCTAssertEqual(old.boundaryAt, new.boundaryAt, "phase \(phase)")
            XCTAssertEqual(old.step, new.step, "phase \(phase)")
        }
    }

    /// A short stall near the end never makes the watch run the poll, so the watch adds no early
    /// pause of a playing song: a stall the 1 s poll does not land on is still never a boundary.
    func testAStallNearTheEndNeverTriggersThePoll() {
        var watch = AirPlayGapEndWatch()
        XCTAssertTrue(watch.regularSample(Self.player(at: 178.5, end: .clear), airPlayGapRoute: true))
        for t in stride(from: 178.6, to: 179.6, by: 0.1) {
            let stalled = PlaybackObservation(entryID: "a", isPlaying: false, position: 178.9, duration: Self.duration, uptime: t)
            XCTAssertEqual(watch.step(stalled), .keepWatching, "t=\(t)")
        }
        // The song plays on after the stall: nothing happened, and the next regular sample re-arms.
        XCTAssertEqual(watch.step(Self.player(at: 179.7, end: .clear)), .keepWatching)
    }

    // MARK: Off AirPlay, unchanged

    func testTheWatchNeverArmsOffTheAirPlayGapRoute() {
        for route in LongFormRouteKind.allCases {
            for flag in [false, true] {
                let state = DJLongFormRouteState(flag: { flag })
                state.record(route)
                var watch = AirPlayGapEndWatch()
                let armed = watch.regularSample(Self.player(at: 179, end: .clear), airPlayGapRoute: !state.talkoverAllowed)
                XCTAssertEqual(armed, flag && route == .airPlay, "route=\(route) flag=\(flag)")
            }
        }
    }

    func testTheWatchArmsOnlyInTheLastSecondsOfAPlayingSongWithAKnownDuration() {
        var watch = AirPlayGapEndWatch()
        XCTAssertFalse(watch.regularSample(Self.player(at: 176.9, end: .clear), airPlayGapRoute: true))
        XCTAssertTrue(watch.regularSample(Self.player(at: 177.0, end: .clear), airPlayGapRoute: true))
        XCTAssertFalse(watch.regularSample(PlaybackObservation(entryID: "a", isPlaying: false, position: 179, duration: 180, uptime: 179),
                                           airPlayGapRoute: true), "paused: not armed")
        XCTAssertFalse(watch.isArmed)
        XCTAssertFalse(watch.regularSample(PlaybackObservation(entryID: "a", isPlaying: true, position: 179, duration: nil, uptime: 179),
                                           airPlayGapRoute: true), "no duration: not armed")
        XCTAssertFalse(watch.regularSample(PlaybackObservation(entryID: "a", isPlaying: true, position: 179, duration: 180, uptime: nil),
                                           airPlayGapRoute: true), "no clock: not armed")
    }

    func testAnUnarmedOrExpiredWatchStops() {
        var watch = AirPlayGapEndWatch()
        XCTAssertEqual(watch.step(Self.player(at: 181, end: .clear)), .stop)
        watch.regularSample(Self.player(at: 178, end: .clear), airPlayGapRoute: true)
        XCTAssertEqual(watch.step(Self.player(at: 178 + AirPlayGapEndWatch.maxWatchSeconds + 0.1, end: .clear)), .stop)
        XCTAssertEqual(watch.step(PlaybackObservation(entryID: "a", isPlaying: true, position: 1, duration: 180, uptime: 177)),
                       .stop, "a read older than its anchor stops")
    }

    // MARK: Skip, route loss and remote skip are still the detector's

    /// A lock-screen Next well before the end: the watch leaves it to the 1 s poll, so the
    /// remote-skip judgement sees today's timing (no break about the cut song).
    func testAnEarlyClearIsLeftToTodaysPoll() {
        var watch = AirPlayGapEndWatch()
        watch.regularSample(Self.player(at: 177.0, end: .clear), airPlayGapRoute: true)
        let cleared = PlaybackObservation(entryID: nil, isPlaying: false, position: nil, duration: 180, uptime: 177.2)
        XCTAssertEqual(watch.step(cleared), .keepWatching)
        for phase in Self.phases {
            let old = Self.simulate(end: .clear, phase: phase, airPlayGapRoute: false, endsAt: 177.2)
            let new = Self.simulate(end: .clear, phase: phase, airPlayGapRoute: true, endsAt: 177.2)
            XCTAssertEqual(old.boundaryAt, new.boundaryAt, "phase \(phase)")
            XCTAssertEqual(old.step, new.step, "phase \(phase)")
        }
    }

    /// The watch only asks for the poll. A route loss (or user pause) the app recorded still
    /// keeps the detector from reporting an end, so no break starts on the speaker.
    func testARouteLossBeforeTheEndStillBlocksTheBoundaryWhenTheWatchFires() {
        var interpreter = BoundaryInterpreter()
        var watch = AirPlayGapEndWatch()
        for t in stride(from: 0.0, through: 179.0, by: 1.0) {
            let s = Self.player(at: t, end: .clear)
            watch.regularSample(s, airPlayGapRoute: true)
            XCTAssertNil(interpreter.interpret(s, queueIndex: 0, queueCount: 2))
        }
        interpreter.pausedByApp(.routeLoss)
        let cleared = PlaybackObservation(entryID: nil, isPlaying: false, position: nil, duration: 180, uptime: 180.05)
        XCTAssertEqual(watch.step(cleared), .pollNow)
        XCTAssertNil(interpreter.interpret(cleared, queueIndex: 0, queueCount: 2), "route loss: never a natural end")
    }

    /// The user's skip loads the next song (an app-requested change): the watch can run the poll,
    /// and the detector still reports no natural end, so no break plays for the skipped song.
    func testAUserSkipDuringTheWatchIsNeverABreak() {
        var interpreter = BoundaryInterpreter()
        var watch = AirPlayGapEndWatch()
        for t in stride(from: 0.0, through: 179.0, by: 1.0) {
            let s = Self.player(at: t, end: .clear)
            watch.regularSample(s, airPlayGapRoute: true)
            _ = interpreter.interpret(s, queueIndex: 0, queueCount: 2)
        }
        interpreter.userRequestedChange()
        let next = PlaybackObservation(entryID: "b", isPlaying: false, position: 0, duration: 200, uptime: 179.3)
        XCTAssertEqual(watch.step(next), .pollNow)
        XCTAssertNil(interpreter.interpret(next, queueIndex: 0, queueCount: 2))
    }

    // MARK: The break itself: no overlap, resume after speech, failures reported

    /// Unchanged by PR A, pinned here because the tighter gap leans on them: every end except a
    /// natural finish stops the clip before the break finishes, and the session is released last
    /// (before music loads), so the voice can never play over the next song.
    func testTheBreakEndOrderStillPreventsOverlap() {
        XCTAssertEqual(BreakEndSequence.steps(for: .naturalFinish), [.finishBreak, .releaseSession])
        for trigger in [BreakEndTrigger.timeout, .decodeError, .halt, .revoke] {
            XCTAssertEqual(BreakEndSequence.steps(for: trigger), [.stopClip, .finishBreak, .releaseSession], "\(trigger)")
            XCTAssertTrue(BreakEndSequence.clipMayStillPlay(trigger))
        }
    }

    /// After speech, the finished song never replays: the next song starts straight away when
    /// playback is allowed, and holds when it is not.
    func testMusicResumesWithTheNextSongRightAfterSpeech() {
        let finished = NarrationResumePolicy.decide(.finished, mayAutoResume: true, phase: .voice)
        XCTAssertTrue(finished.resumeMusic)
        XCTAssertEqual(finished.audioEvent, .interludeEnded)
        XCTAssertEqual(NarrationResumePolicy.musicAfterBreak(entryAlreadyFinished: true, mayAutoResume: true, queueHasEntry: true),
                       .startNextTrack)
        XCTAssertEqual(NarrationResumePolicy.musicAfterBreak(entryAlreadyFinished: true, mayAutoResume: false, queueHasEntry: true),
                       .hold)
    }

    /// A prepared break that cannot play (clips do not decode, empty) is skipped and reported as a
    /// failure for that boundary, never lost silently; music goes on from the boundary.
    func testAnUnplayableBreakIsReportedNotLost() {
        for reason in [HandedOutBreakSkip.decodeFailed, .notPlayable, .emptyLine] {
            let effect = HandedOutBreakReport.skipped(reason, afterTrack: 4, mayAutoResume: true)
            XCTAssertEqual(effect.event, .playbackFailed(afterTrack: 4), "\(reason)")
            XCTAssertEqual(effect.resume.audioEvent, .noInterlude)
            XCTAssertTrue(effect.resume.resumeMusic)
        }
    }

    // MARK: App wiring (source checks)

    private static var ios: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The watch only calls the existing poll; it adds no session call, no pause and no second
    /// scheduler, and it is gated on the AirPlay gap route.
    func testTheAppWatchOnlyRunsTheExistingPollOnTheAirPlayGapRoute() throws {
        let service = try String(contentsOf: Self.ios.appendingPathComponent("AeroDJ/MusicKitService.swift"), encoding: .utf8)
        let lines = service.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { $0.contains("private func updateGapEndWatch(") })
        let end = try XCTUnwrap(lines[start...].firstIndex { $0.contains("private func pollPlaybackPosition()") })
        let body = lines[start..<end].joined(separator: "\n")
        XCTAssertTrue(body.contains("airPlayGapRoute: !DJLongFormRouteState.shared.talkoverAllowed"))
        XCTAssertTrue(body.contains("self.pollPlaybackPosition()"))
        for forbidden in ["setActive", "setCategory", "pause()", "play()", "pausePlayerForBreak", "interlude", "skip("] {
            XCTAssertFalse(body.contains(forbidden), "the watch must not call \(forbidden)")
        }
        XCTAssertTrue(service.contains("withTimeInterval: 1.0, repeats: true"), "today's 1 s poll is unchanged")
    }
}
