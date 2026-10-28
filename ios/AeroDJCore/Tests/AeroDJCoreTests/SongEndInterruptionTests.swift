import XCTest
@testable import AeroDJCore

/// Build 18 P0 (-Fry). On the owner's iPhone, with AeroDJ in the foreground, song 1 ends, the bar
/// sits at 0:00 paused, Play restarts song 1, and song 2 never starts. Theory, unconfirmed on
/// device: as the one-song queue finishes, the shared session gets `interruptionBegan` with no
/// matching end. That cleared `wasPlaying`, so the detector dropped the end, and it set
/// `pausedBySystem`, so a boundary that did fire held song 2 with `.deferSilently`.
///
/// The harness feeds the same calls `MusicKitService` makes, in its order:
/// session notice -> `AudioSessionPolicy.handle` + `pausedByApp(cause)`; poll -> `interpret`;
/// boundary -> `naturalEndReached` (the one boundary hook) -> `armNext`; `startNextTrack` ->
/// `takeNext` -> `naturalEndReached` again -> `startTrack`'s hold gate.
final class SongEndInterruptionTests: XCTestCase {
    private static let duration: TimeInterval = 200

    /// What the session reads at the hook: `isOtherAudioPlaying`, the secondary hint, calls.
    struct World {
        var otherAudioPlaying = false
        var secondaryHint = false
        var callActive = false
    }

    enum NextStart: Equatable {
        case plays
        case held(HeldStartAction)
    }

    struct Harness {
        var interpreter = BoundaryInterpreter()
        var policy = AudioSessionPolicy()
        var attempts = PlaybackAttempts()
        var world = World()
        var steps: [BoundaryStep] = []
        var uptime: TimeInterval = 1_000

        init() {
            // The user tapped song 1 of a 3-song station queue.
            policy.userPlay()
            interpreter.userRequestedChange()
            _ = attempts.beginStart()
        }

        mutating func obs(_ id: String?, playing: Bool, at position: TimeInterval?) -> PlaybackObservation {
            PlaybackObservation(entryID: id, isPlaying: playing, position: position,
                                duration: id == nil ? nil : SongEndInterruptionTests.duration,
                                uptime: uptime)
        }

        /// 1 s polls of entry "s1", playing, from 0 through `last`.
        mutating func play(through last: TimeInterval) {
            var t: TimeInterval = 0
            while t <= last {
                poll("s1", playing: true, at: t)
                t += 1
                uptime += 1
            }
        }

        mutating func poll(_ id: String?, playing: Bool, at position: TimeInterval?) {
            let o = obs(id, playing: playing, at: position)
            guard let step = interpreter.interpret(o, queueIndex: 0, queueCount: 3) else { return }
            steps.append(step)
            if case .plannedHandoff = step {
                boundaryHook()
                attempts.armNext(after: step.finishedIndex)
            }
        }

        /// `MusicKitService.releaseSongEndHoldIfAllowed()`.
        mutating func boundaryHook() {
            policy.naturalEndReached(interruptionBeganNearEnd: interpreter.interruptionBeganNearEnd,
                                     otherAudioPlaying: world.otherAudioPlaying,
                                     secondaryHint: world.secondaryHint,
                                     callActive: world.callActive)
        }

        /// `performSessionStep`'s detector bookkeeping, after the policy handled the notice.
        mutating func notice(_ n: AudioSessionNotice) {
            _ = policy.handle(n, breakIsActive: false)
            switch n {
            case .interruptionBegan: interpreter.pausedByApp(.systemInterruption)
            case .routeChanged(.oldDeviceUnavailable): interpreter.pausedByApp(.routeLoss)
            case .interruptionEnded, .routeChanged(.other): break
            }
        }

        mutating func userPause() {
            _ = policy.userPause()
            interpreter.pausedByApp(.userPause)
        }

        /// `startNextTrack(after: 0)` up to `startTrack`'s hold gate. Nil when nothing loads.
        mutating func startNext() -> NextStart? {
            guard attempts.takeNext(after: 0) else { return nil }
            boundaryHook()
            _ = attempts.beginStart()
            guard policy.mayAutoResume else { return .held(HeldStartPolicy.action(userInitiated: false)) }
            return .plays
        }

        var handoffs: Int {
            steps.filter { if case .plannedHandoff(0, 1, _) = $0 { return true } else { return false } }.count
        }
    }

    private func assertOneHandoff(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(h.steps.count, 1, "steps: \(h.steps)", file: file, line: line)
        XCTAssertEqual(h.handoffs, 1, "steps: \(h.steps)", file: file, line: line)
    }

    // MARK: - Required matrix (a)-(h)

    /// (a) began before the stop poll; the entry is kept and paused at its end.
    func testA_BeganBeforeStopPollKeptAndPausedAtEnd() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 200)
        h.poll("s1", playing: false, at: 200)
        assertOneHandoff(h)
        XCTAssertTrue(h.policy.mayAutoResume, "the end-of-song interruption no longer holds song 2")
        XCTAssertEqual(h.startNext(), .plays)
        XCTAssertNil(h.startNext(), "song 2 loads once")
    }

    /// (b) began after the stop poll: the end was already reported; no second report.
    func testB_BeganAfterStopPollDoesNotDoubleReport() {
        var h = Harness()
        h.play(through: 199)
        h.poll("s1", playing: false, at: 200)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 200)
        h.poll("s1", playing: false, at: 0)
        h.poll(nil, playing: false, at: nil)
        assertOneHandoff(h)
        XCTAssertEqual(h.startNext(), .plays, "the startNextTrack hook releases a hold that began after the end")
    }

    /// (c) began, then the entry cleared.
    func testC_BeganThenEntryCleared() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll(nil, playing: false, at: nil)
        h.poll(nil, playing: false, at: nil)
        assertOneHandoff(h)
        XCTAssertEqual(h.startNext(), .plays)
    }

    /// (d) began, then the playhead rewinds to 0 (the owner's 0:00-and-paused shape).
    func testD_BeganThenPlayheadRewoundToZero() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        h.poll("s1", playing: false, at: 0)
        h.poll("s1", playing: false, at: 0)
        assertOneHandoff(h)
        XCTAssertEqual(h.startNext(), .plays)
    }

    /// (e) a mid-song interruption stays a pause: no boundary, and the hold stays.
    func testE_MidSongInterruptionIsAPause() {
        var h = Harness()
        h.play(through: 100)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 100)
        h.poll("s1", playing: false, at: 100)
        XCTAssertTrue(h.steps.isEmpty, "\(h.steps)")
        XCTAssertTrue(h.policy.pausedBySystem)
        XCTAssertFalse(h.policy.mayAutoResume)
        XCTAssertNil(h.startNext(), "nothing was armed")
    }

    /// (e') a mid-song interruption after which MusicKit reads 0 is still not an end.
    func testE2_MidSongInterruptionThenZeroIsNotAnEnd() {
        var h = Harness()
        h.play(through: 100)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        XCTAssertTrue(h.steps.isEmpty, "\(h.steps)")
        XCTAssertTrue(h.policy.pausedBySystem)
    }

    /// (f) a user pause in the last 1.5 s: no boundary, also when the playhead then reads 0.
    func testF_UserPauseInLastSecondsIsNoEnd() {
        var h = Harness()
        h.play(through: 199)
        h.userPause()
        h.poll("s1", playing: false, at: 199.2)
        h.poll("s1", playing: false, at: 0)
        h.poll(nil, playing: false, at: nil)
        XCTAssertTrue(h.steps.isEmpty, "\(h.steps)")
        XCTAssertNil(h.startNext())
    }

    /// (g) route loss near the end: no boundary.
    func testG_RouteLossNearEndIsNoEnd() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.routeChanged(.oldDeviceUnavailable))
        h.poll("s1", playing: false, at: 199.2)
        h.poll("s1", playing: false, at: 0)
        XCTAssertTrue(h.steps.isEmpty, "\(h.steps)")
        XCTAssertTrue(h.policy.pausedBySystem)
    }

    /// (h) a real call at the end: the boundary may fire, but song 2 stays held.
    func testH_CallAtEndHoldsSong2() {
        var h = Harness()
        h.world.callActive = true
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        assertOneHandoff(h)
        XCTAssertTrue(h.policy.pausedBySystem)
        XCTAssertEqual(h.startNext(), .held(.deferSilently))
    }

    // MARK: - Sentinel's hold gates (interruption began at the end and never ended)

    func testNeverEndedWithOtherAudioPlayingHoldsSong2() {
        var h = Harness()
        h.world.otherAudioPlaying = true
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        assertOneHandoff(h)
        XCTAssertEqual(h.startNext(), .held(.deferSilently))
    }

    func testNeverEndedWithNothingElsePlayingStartsSong2() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        XCTAssertEqual(h.startNext(), .plays)
    }

    func testNeverEndedWithSecondaryHintHoldsSong2() {
        var h = Harness()
        h.world.secondaryHint = true
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        XCTAssertEqual(h.startNext(), .held(.deferSilently))
    }

    func testEndedWithShouldResumeStartsSong2() {
        var h = Harness()
        h.world.otherAudioPlaying = true // irrelevant once the system gave the session back
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.notice(.interruptionEnded(shouldResume: true))
        h.poll("s1", playing: false, at: 0)
        assertOneHandoff(h)
        XCTAssertEqual(h.startNext(), .plays)
    }

    /// Orion: the OS said do not resume, so song 2 holds until the user presses play.
    func testEndedWithoutShouldResumeHoldsSong2UntilUserPlay() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.notice(.interruptionEnded(shouldResume: false))
        h.poll("s1", playing: false, at: 0)
        assertOneHandoff(h)
        XCTAssertEqual(h.startNext(), .held(.deferSilently))
        XCTAssertTrue(h.policy.pausedBySystem)
        h.policy.userPlay()
        XCTAssertTrue(h.policy.mayAutoResume, "the user's play is the only release")
    }

    /// Siri (or another system interruption) begins at the end, never ends, and other audio plays.
    func testSiriNeverEndsWithOtherAudioHoldsSong2() {
        var h = Harness()
        h.world.otherAudioPlaying = true
        h.world.secondaryHint = true
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 199.4)
        h.poll("s1", playing: false, at: 0)
        h.poll("s1", playing: false, at: 0)
        assertOneHandoff(h)
        XCTAssertEqual(h.startNext(), .held(.deferSilently))
        XCTAssertTrue(h.policy.interruptionOngoing)
    }

    /// Same, but only `isOtherAudioPlaying` is set (no secondary hint): still held.
    func testSystemInterruptionNeverEndsOtherAudioOnlyHoldsSong2() {
        var h = Harness()
        h.world.otherAudioPlaying = true
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll(nil, playing: false, at: nil)
        XCTAssertEqual(h.startNext(), .held(.deferSilently))
    }

    /// A new interruption after an end without shouldResume starts from a clean slate.
    func testNewInterruptionResetsShouldResume() {
        var p = AudioSessionPolicy()
        p.userPlay()
        _ = p.handle(.interruptionBegan, breakIsActive: false)
        _ = p.handle(.interruptionEnded(shouldResume: false), breakIsActive: false)
        XCTAssertFalse(p.lastEndShouldResume)
        _ = p.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertTrue(p.lastEndShouldResume)
        XCTAssertTrue(p.naturalEndReached(interruptionBeganNearEnd: true, otherAudioPlaying: false,
                                          secondaryHint: false, callActive: false),
                      "never ended + nothing else playing still releases (Sentinel's gate)")
    }

    func testDecisionTable() {
        func r(_ ended: Bool, _ other: Bool, _ hint: Bool, _ call: Bool, _ near: Bool,
               resume: Bool = true) -> Bool {
            SongEndHold.releases(interruptionEnded: ended, shouldResume: resume, otherAudioPlaying: other,
                                 secondaryHint: hint, callActive: call, beganNearEnd: near)
        }
        XCTAssertFalse(r(true, false, false, false, true, resume: false), "ended without shouldResume holds")
        XCTAssertTrue(r(false, false, false, false, true, resume: false), "shouldResume only matters once ended")
        XCTAssertTrue(r(false, false, false, false, true))
        XCTAssertFalse(r(false, true, false, false, true))
        XCTAssertFalse(r(false, false, true, false, true))
        XCTAssertFalse(r(false, false, false, true, true))
        XCTAssertTrue(r(true, true, true, false, true))
        XCTAssertFalse(r(true, false, false, true, true), "a call always holds")
        XCTAssertFalse(r(true, false, false, false, false), "never outside the end window")
        XCTAssertFalse(r(false, false, false, false, false))
    }

    /// The hook never releases a route hold or a user pause.
    func testHookNeverReleasesARouteHoldOrUserPause() {
        var route = AudioSessionPolicy()
        route.userPlay()
        _ = route.handle(.routeChanged(.oldDeviceUnavailable), breakIsActive: false)
        XCTAssertFalse(route.naturalEndReached(interruptionBeganNearEnd: true, otherAudioPlaying: false,
                                               secondaryHint: false, callActive: false))
        XCTAssertFalse(route.mayAutoResume)

        var paused = AudioSessionPolicy()
        paused.userPlay()
        _ = paused.handle(.interruptionBegan, breakIsActive: false)
        _ = paused.userPause()
        paused.naturalEndReached(interruptionBeganNearEnd: true, otherAudioPlaying: false,
                                 secondaryHint: false, callActive: false)
        XCTAssertFalse(paused.mayAutoResume, "the user's pause still wins")
    }

    // MARK: - Orion: sticky played-through facts, not wasPlaying

    /// Slow or late polls: the last playing sample is at 170 s, the next poll is 35 s later and
    /// reads 0:00 paused. Elapsed play time passed 90%, so this is the end.
    func testLatePollAfterRewindIsStillTheEnd() {
        var h = Harness()
        h.play(through: 170)
        h.uptime += 34
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        assertOneHandoff(h)
        XCTAssertEqual(h.startNext(), .plays)
    }

    /// Furthest position past 90% (no interruption, no uptime) and a rewind to 0 is the end.
    func testRewindAfterNinetyPercentIsTheEnd() {
        var d = PlaybackBoundaryDetector()
        for t in stride(from: 0.0, through: 185.0, by: 1.0) {
            _ = d.consume(PlaybackObservation(entryID: "s1", isPlaying: true, position: t, duration: 200))
        }
        XCTAssertEqual(d.consume(PlaybackObservation(entryID: "s1", isPlaying: false, position: 0, duration: 200)),
                       .queueFinished(lastEntryID: "s1"))
    }

    /// A long gap mid-song (suspension) is capped by what was left of the song, and a stop
    /// mid-song is not an end even if the elapsed time looks long.
    func testLongGapMidSongIsNotAnEnd() {
        var h = Harness()
        h.play(through: 100)
        h.uptime += 600
        h.poll("s1", playing: false, at: 100)
        XCTAssertTrue(h.steps.isEmpty, "\(h.steps)")
    }

    /// Orion: a mid-song user pause, then the user seeks to 0, is not an end.
    func testMidSongUserPauseThenSeekToZeroIsNotAnEnd() {
        var h = Harness()
        h.play(through: 100)
        h.userPause()
        h.poll("s1", playing: false, at: 100)
        h.poll("s1", playing: false, at: 0)
        h.poll("s1", playing: false, at: 0)
        XCTAssertTrue(h.steps.isEmpty, "\(h.steps)")
    }

    /// Sentinel: the user scrubs back from the end to under 2 s and pauses. Not an end.
    func testUserScrubBackUnderTwoSecondsThenPauseIsNotAnEnd() {
        var h = Harness()
        h.play(through: 199)
        h.poll("s1", playing: true, at: 1)
        h.userPause()
        h.poll("s1", playing: false, at: 1)
        XCTAssertTrue(h.steps.isEmpty, "\(h.steps)")
    }

    // MARK: - (i) with and without a break, and Echo's break gates

    /// Without a break: PlayerView calls `startNextTrack` straight away (SongEndAdvanceTests).
    func testWithoutBreakSong2Plays() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        XCTAssertEqual(BreakHandoffPolicy.decide(prepared: nil), .continueMusic)
        XCTAssertEqual(h.startNext(), .plays)
    }

    /// Echo: nothing else playing. The break airs once, then song 2 plays; neither is held.
    func testWithBreakAirsOnceThenSong2Plays() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        assertOneHandoff(h)

        // PlayerView.onBoundary: hand out, then InterludePlaybackAdapter.play's gates.
        var pending = PendingPlayStop()
        pending.handOut(afterTrack: 0)
        var started = 0
        let opened = pending.begin(afterTrack: 0, mayAutoResume: h.policy.mayAutoResume)
        let admission = BreakPlayAdmissionPolicy.decide(pausedBySystem: h.policy.pausedBySystem,
                                                        mayAutoResume: h.policy.mayAutoResume,
                                                        phase: .transition, afterTrack: 0)
        let admitted = pending.admit(mayAutoResume: h.policy.mayAutoResume)
        if opened.startAudio, admission.startAudio, admitted.startAudio { started += 1 }
        XCTAssertEqual(started, 1, "the break airs")
        XCTAssertNil(admission.skipReason)

        // runBreak's end: completeNarration, then musicAfterBreak (BreakEndSequence natural finish).
        XCTAssertEqual(BreakEndSequence.steps(for: .naturalFinish), [.finishBreak, .releaseSession])
        let decision = NarrationResumePolicy.decide(.finished, mayAutoResume: h.policy.mayAutoResume, phase: .voice)
        XCTAssertTrue(decision.resumeMusic)
        XCTAssertEqual(NarrationResumePolicy.musicAfterBreak(entryAlreadyFinished: true,
                                                             mayAutoResume: h.policy.mayAutoResume,
                                                             queueHasEntry: true), .startNextTrack)
        _ = h.attempts.beginStart() // a resume during the break must not cancel song 2
        XCTAssertEqual(h.startNext(), .plays)
        XCTAssertNil(h.startNext(), "song 2 loads once")
    }

    /// Echo: a call (or other audio) at the end. The break is skipped with `.interrupted`
    /// and song 2 is held.
    func testWithBreakAndCallSkipsBreakAndHoldsSong2() {
        for world in [World(callActive: true), World(otherAudioPlaying: true)] {
            var h = Harness()
            h.world = world
            h.play(through: 199)
            h.notice(.interruptionBegan)
            h.poll("s1", playing: false, at: 0)
            assertOneHandoff(h)
            let admission = BreakPlayAdmissionPolicy.decide(pausedBySystem: h.policy.pausedBySystem,
                                                            mayAutoResume: h.policy.mayAutoResume,
                                                            phase: .transition, afterTrack: 0)
            XCTAssertFalse(admission.startAudio)
            XCTAssertEqual(admission.skipReason, .interrupted)
            XCTAssertEqual(PlaybackLog.breakSkipped(after: 0, reason: admission.skipReason!),
                           "break skipped after=0 reason=interrupted")
            XCTAssertEqual(NarrationResumePolicy.musicAfterBreak(entryAlreadyFinished: true,
                                                                 mayAutoResume: h.policy.mayAutoResume,
                                                                 queueHasEntry: true), .hold)
            XCTAssertEqual(h.startNext(), .held(.deferSilently))
        }
    }

    /// Echo + Orion: the interruption ended with shouldResume=false at a break boundary. The break
    /// does not air, it is skipped with `.interrupted` (logged, not lost), song 2 is loaded held,
    /// and the user's next Play starts song 2 once, not a stale break.
    func testWithBreakAndEndedWithoutShouldResumeSkipsBreakAndHoldsSong2() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.notice(.interruptionEnded(shouldResume: false))
        h.poll("s1", playing: false, at: 0)
        assertOneHandoff(h)

        var pending = PendingPlayStop()
        pending.handOut(afterTrack: 0)
        let admission = BreakPlayAdmissionPolicy.decide(pausedBySystem: h.policy.pausedBySystem,
                                                        mayAutoResume: h.policy.mayAutoResume,
                                                        phase: .transition, afterTrack: 0)
        XCTAssertFalse(admission.startAudio, "the break must not air while held")
        XCTAssertEqual(admission.skipReason, .interrupted)
        XCTAssertEqual(PlaybackLog.breakSkipped(after: 0, reason: admission.skipReason!),
                       "break skipped after=0 reason=interrupted")
        pending.abandonHandOut()
        XCTAssertEqual(NarrationResumePolicy.musicAfterBreak(entryAlreadyFinished: true,
                                                             mayAutoResume: h.policy.mayAutoResume,
                                                             queueHasEntry: true), .hold)

        // startTrack's hold gate arms song 2 as the deferred start.
        XCTAssertEqual(h.startNext(), .held(.deferSilently))
        var deferred = DeferredSongStart()
        deferred.arm(1)

        // The user presses Play: the resume path reports song 2 (index 1), once.
        h.policy.userPlay()
        XCTAssertTrue(h.policy.mayAutoResume)
        XCTAssertEqual(deferred.take(), 1, "Play starts song 2")
        XCTAssertNil(deferred.take(), "song 2 is reported once")
        XCTAssertNil(h.startNext(), "song 2 is not loaded again, and no break is re-queued")
    }

    // MARK: - Atlas

    /// (b) the start was allowed and `play()` threw: the visible banner, not a silent stop.
    func testAllowedStartThatThrowsShowsTheBanner() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        XCTAssertEqual(h.startNext(), .plays, "the hold gate is passed, so play() is reached")
        let attempt = h.attempts.current!
        let code = PlaybackErrorCode(typeName: "MPError", domain: "MPErrorDomain", code: 5)
        let banner = NextSongStartFailure.banner(code: code, attempt: attempt.number,
                                                 attemptIsCurrent: h.attempts.isCurrent(attempt))
        XCTAssertEqual(banner, "Could not start the next song: MPError MPErrorDomain code 5. attempt=\(attempt.number)")
        XCTAssertNil(NextSongStartFailure.banner(code: code, attempt: 1, attemptIsCurrent: false))
    }

    /// (a) the interruption reason, as an enum token only.
    func testInterruptionReasonIsAnEnumToken() {
        XCTAssertEqual(AudioInterruptionReason(rawReason: 0), .default)
        XCTAssertEqual(AudioInterruptionReason(rawReason: 1), .appWasSuspended)
        XCTAssertEqual(AudioInterruptionReason(rawReason: 2), .builtInMicMuted)
        XCTAssertEqual(AudioInterruptionReason(rawReason: 4), .routeDisconnected)
        XCTAssertEqual(AudioInterruptionReason(rawReason: 3), .unknown)
        XCTAssertEqual(AudioInterruptionReason(rawReason: nil), .unknown)
        for reason in AudioInterruptionReason.allCases {
            let line = PlaybackLog.interruptionBegan(reason: reason)
            XCTAssertEqual(line, "session interruption began reason=\(reason.rawValue)")
            XCTAssertTrue(line.allSatisfy { $0.isASCII })
        }
    }
}
