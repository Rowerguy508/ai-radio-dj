import XCTest
@testable import AeroDJCore

/// #444 (-Echo): Skip twice quickly on the lock screen freezes playback.
///
/// One Next works (`skip()` plus the #373 remote-skip detection). A second Next while that
/// load is in flight used to start another `play()` and, once the new song was cleared before
/// it had played, report a failed start (`.userPaused`) with MusicKit's queue already empty.
///
/// These tests drive `SkipCoordinator` the way `MusicKitService.skip()` and its poll do, and
/// the real boundary detector, playback engine, `DJBreakPreparer` and `VoiceRenderer`. They
/// assert the show afterwards: transport playing, the queue advanced once per press up to one
/// stored follow-up, and no break left on air.
///
/// #444 build 43 (-Atlas): the fake player now models MusicKit. A load is `prepareToPlay` then
/// `play()` (with the real `SelfStartInterruptionGate` marking `play()` awaiting), either step can
/// throw, the "system" can clear or rewind the one-song queue while a load is suspended or after it
/// returns, and a lock-screen Next can arrive only as that observation (no `show.skip()`), which is
/// how it reaches the app on device.
@MainActor
final class LockScreenDoubleSkipTests: XCTestCase {
    func testSingleSkipWhileLoadingEndsPlayingOnTheNextSong() async {
        let show = Show()
        await show.finishSkips(extraPresses: 0)
        show.assertPlaying(index: 1)
    }

    func testTwoNextTrackCommandsWhileLoadingAdvanceTwiceAndStayPlaying() async {
        let show = Show()
        await show.finishSkips(extraPresses: 1)
        show.assertPlaying(index: 2)
    }

    func testThreeNextTrackCommandsWhileLoadingAdvanceTwice() async {
        let show = Show()
        await show.finishSkips(extraPresses: 2)
        show.assertPlaying(index: 2)
    }

    /// The first clear is a real remote skip. The second clears the song that skip is loading,
    /// before our own `play()` was called (B still in `prepareToPlay`). #444 build 43, owner-directed
    /// reversal: that clear is the owner's second lock-screen Next, so it lands on C. It used to
    /// expect B (index 1), which is the build 43 bug.
    func testMusicKitClearWhileLoadingRecoversTheSelectedSong() async {
        let show = Show()
        show.suspendAt = .prepare
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.feed(show.cleared())
        XCTAssertFalse(show.pausedByNoProgress)
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 2)
        XCTAssertEqual(show.reloads, 0, "the second Next is not a reload of B")
        XCTAssertFalse(show.pausedByNoProgress)
        XCTAssertNil(show.unexpectedBoundary)
    }

    /// The other MusicKit shape: rewind to 0:00, then the loaded song rewound again before it
    /// has played past the failed-start window. Recover it. Do not take the next song.
    func testMusicKitRewindWhileLoadingRecoversTheSelectedSong() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.rewound())
        await show.untilLoadSuspended()
        // The load has been seen playing, but not for 2 s, then Next rewinds it.
        show.feed(show.sample(playing: true, position: 1))
        show.feed(show.rewound())
        XCTAssertFalse(show.pausedByNoProgress)
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        XCTAssertFalse(show.pausedByNoProgress)
    }

    /// The command target and MusicKit's clear both report the same second press. One follow-up.
    func testCommandAndMusicKitClearForTheSameSecondPressAdvanceTwice() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        await show.skip()
        show.feed(show.cleared())
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 2)
    }

    /// The chain already finished, then the poll sees the clear of the song that never played 2 s.
    /// #444 build 43, owner-directed reversal: our `play()` returned, so the clear is MusicKit's own
    /// Next. It advances to C. It does not pause and does not reload B (it used to expect B).
    func testLoadCutAfterTheChainFinishesReloadsInsteadOfPausing() async {
        let show = Show()
        let running = Task { await show.skip() }
        await show.untilLoadSuspended()
        show.finishLoad()
        await running.value
        show.assertPlaying(index: 1)
        show.feed(show.cleared())
        await show.untilIdle()
        show.assertPlaying(index: 2)
        XCTAssertEqual(show.reloads, 0)
        XCTAssertFalse(show.pausedByNoProgress)
    }

    func testDoubleSkipWhileABreakIsPreparedDropsItAndStaysPlaying() async {
        let show = await Show.preparedBreak()
        XCTAssertTrue(show.breakIsReady)
        await show.finishSkips(extraPresses: 1)
        await show.assertBreakNotAiring(advancedTo: 2)
        let dropped = await show.preparer?.testResult(afterTrack: 0)
        XCTAssertEqual(dropped, .skipped(.notNaturalBoundary))
        let aired = await show.session?.naturalBoundary(afterTrack: 0)
        XCTAssertNil(aired, "the prepared break was dropped with the skip and is not played")
    }

    func testTripleSkipWhileABreakIsPreparedAdvancesTwiceAndDoesNotAirIt() async {
        let show = await Show.preparedBreak()
        await show.finishSkips(extraPresses: 2)
        await show.assertBreakNotAiring(advancedTo: 2)
        let aired = await show.session?.naturalBoundary(afterTrack: 0)
        XCTAssertNil(aired)
    }

    func testDoubleSkipWhileABreakIsAiringStopsItAndDoesNotReplay() async {
        let show = await Show.airingBreak()
        XCTAssertTrue(show.dj?.state.isLive == true)
        XCTAssertGreaterThan(show.dj?.speechLevel ?? 0, 0)
        await show.finishSkips(extraPresses: 1)
        await show.assertBreakNotAiring(advancedTo: 2)
        XCTAssertEqual(show.dj?.speechLevel, 0)
        XCTAssertFalse(show.speechOverlapped)
    }

    func testTripleSkipWhileABreakIsAiringStopsSpeechAndAdvancesTwice() async {
        let show = await Show.airingBreak()
        await show.finishSkips(extraPresses: 2)
        await show.assertBreakNotAiring(advancedTo: 2)
        XCTAssertEqual(show.dj?.speechLevel, 0)
        XCTAssertFalse(show.speechOverlapped)
        let aired = await show.session?.naturalBoundary(afterTrack: 0)
        XCTAssertNil(aired)
    }

    /// A clear with no skip in flight is still the build 9 failed start, not a skip.
    func testNoProgressClearWithoutASkipLoadIsStillAFailedStart() {
        var b = BoundaryInterpreter()
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: 1.0, by: 1.0) {
            XCTAssertNil(b.interpret(PlaybackObservation(entryID: "song-0", isPlaying: true, position: position,
                                                         duration: 200, uptime: t),
                                     queueIndex: 0, queueCount: 3))
            t += 1
        }
        XCTAssertNil(b.interpret(PlaybackObservation(entryID: nil, isPlaying: false, position: nil,
                                                     duration: nil, uptime: t),
                                 queueIndex: 0, queueCount: 3))
        XCTAssertTrue(b.takeNoProgressEnd())
        XCTAssertFalse(b.takeRemoteSkip())
        XCTAssertFalse(b.takeSkipLoadCut())
    }

    /// `MusicKitService` sends every Next through this chain, including the command target's `skip()`.
    func testMusicKitServiceUsesTheSkipChainForNextAndForALoadCut() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AeroDJCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AeroDJCore
            .deletingLastPathComponent() // ios
        let source = try String(contentsOf: root.appendingPathComponent("AeroDJ/MusicKitService.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("skipCoordinator.requestAdvance()"))
        XCTAssertTrue(source.contains("skipCoordinator.runChain"))
        XCTAssertTrue(source.contains("takeSkipLoadCut()"))
        XCTAssertTrue(source.contains("noteLoadCut(target:"))
        XCTAssertTrue(source.contains("invalidate(.userPause)"))
        XCTAssertTrue(source.contains("invalidate(.routeRemoved)"))
        XCTAssertTrue(source.contains("invalidate(.interruptionBegan)"))
        XCTAssertTrue(source.contains("noteInterruptionEnded"))
        XCTAssertFalse(source.contains("noteLoadCut()\n"), "a load cut must not use the old no-target call")
        XCTAssertTrue(source.contains("await self?.skip()") || source.contains("await self.skip()"),
                      "nextTrackCommand still targets skip()")
        XCTAssertTrue(source.contains("if skipCoordinator.isInFlight { return }"),
                      "a break resume does not start a second play while a skip owns the player")
        let oneSkip = source.split(separator: "private func oneSkip").dropFirst().first.map(String.init) ?? ""
        let advance = oneSkip.split(separator: "case .advance:").dropFirst().first
            .map(String.init)?
            .split(separator: "case .reload:").first
            .map(String.init) ?? ""
        let flagSet = try XCTUnwrap(advance.range(of: "boundaries.setSkipLoadInFlight(true)"),
                                    "a .beginWhenIdle Next sets the skip-load flag inside oneSkip's advance")
        let load = try XCTUnwrap(advance.range(of: "loadSkippedSong"))
        XCTAssertLessThan(flagSet.lowerBound, load.lowerBound)
        XCTAssertTrue(advance.contains("boundaries.setSkipLoadInFlight(false)"),
                      "the advance clears the flag on the exits that stop the load")
    }

    /// Pause during a load, then Next before it returns. That Next is `.beginWhenIdle`.
    /// A queue clear during its load is a load cut, not `noProgressEnd`, and the song reloads.
    func testBeginWhenIdleNextTreatsAQueueClearAsALoadCut() async {
        let show = Show()
        show.primePlaying()
        let running = Task { await show.skip() }
        await show.untilLoadSuspended()
        show.pause()
        await show.skip()
        show.releaseOne()
        await show.untilLoadSuspended()
        show.feed(show.sample(playing: true, position: 0.5))
        show.feed(show.cleared())
        XCTAssertEqual(show.noProgressEnds, 0, "the clear is not a failed start")
        XCTAssertGreaterThan(show.loadCuts, 0, "the fresh Next's load was cut")
        XCTAssertFalse(show.pausedByNoProgress)
        show.finishLoad()
        await running.value
        await show.untilIdle()
        XCTAssertEqual(show.noProgressEnds, 0)
        XCTAssertGreaterThanOrEqual(show.reloads, 1, "the cut song is recovered")
        XCTAssertFalse(show.queueEmpty, "playback is not left playing on an empty queue")
        show.assertPlaying(index: 2)
        XCTAssertNotNil(show.engine.snapshot.nowPlaying)
        XCTAssertFalse(show.pausedByNoProgress)
    }

    // MARK: - #444 build 43: a lock-screen Next reaches the app only as a clear or rewind

    /// The owner's sequence on build 43: A playing, lock-screen Next (clear), B loads and plays at
    /// 0.5 s, lock-screen Next again (clear only, no command target). Ends on C, playing.
    func testOwnerSequenceTwoLockScreenNextsAdvanceTwiceAndKeepPlaying() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        show.feed(show.sample(playing: true, position: 0.5))
        show.markHistory()
        show.feed(show.cleared())
        await show.untilIdle()
        show.assertOwnerOutcome(index: 2)
        XCTAssertEqual(show.lastCutAwaitingPlay, false, "the second Next was seen after B's play() returned")
    }

    /// The same sequence with MusicKit's other shape: the one-song queue is kept and rewound to 0.
    func testOwnerSequenceWithTheRewindShapeAdvancesTwice() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.rewound())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        show.feed(show.sample(playing: true, position: 0.5))
        show.markHistory()
        show.feed(show.rewound())
        await show.untilIdle()
        show.assertOwnerOutcome(index: 2)
        XCTAssertEqual(show.lastCutShape, .rewind)
    }

    /// Echo's gate (#446): a real MusicKit cut while our own `play()` for B is awaiting is the
    /// ambiguous load cut. One Next reloads B and never advances to C.
    func testOneNextWithACutWhileOurPlayIsAwaitingStaysOnTheSelectedSong() async {
        let show = Show()
        show.suspendAt = .play
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        XCTAssertTrue(show.playAwaiting, "the load is suspended inside play()")
        show.feed(show.sample(playing: true, position: 0.5))
        show.feed(show.cleared())
        XCTAssertEqual(show.lastCutAwaitingPlay, true)
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        XCTAssertEqual(show.reloads, 1, "the ambiguous cut reloads the same song once")
        XCTAssertEqual(show.advances, 1, "one Next is one advance")
    }

    /// Next #2 arrives (as a clear) while B's load is suspended, and then that load throws. Both
    /// suspension points: in `prepareToPlay` and inside our own `play()`. Ends on C, never paused.
    func testSecondNextDuringASuspendedLoadThatThenThrowsLandsOnTheNextSong() async {
        for phase in [Show.LoadPhase.prepare, .play] {
            let show = Show()
            show.suspendAt = phase
            show.throwOnLoad = [phase]
            show.primePlaying()
            show.feed(show.cleared())
            await show.untilLoadSuspended()
            show.markHistory()
            show.feed(show.sample(playing: phase == .play, position: 0.5))
            show.feed(show.cleared())
            show.finishLoad()
            await show.untilIdle()
            show.assertOwnerOutcome(index: 2, "\(phase)")
        }
    }

    /// Poll lag: the cut happened during B's `play()`, B was recovered (the one recovery is spent),
    /// and only then does the poll see the owner's second Next. It must not pause; it lands on C.
    func testPollLagAfterTheRecoveryWasSpentAdvancesInsteadOfPausing() async {
        let show = Show()
        show.suspendAt = .play
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.feed(show.sample(playing: true, position: 0.5))
        show.feed(show.cleared())
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        XCTAssertEqual(show.reloads, 1, "the recovery is spent")
        show.feed(show.sample(playing: true, position: 0.5))
        show.feed(show.cleared())
        await show.untilIdle()
        show.assertPlaying(index: 2)
        XCTAssertFalse(show.everPaused)
        XCTAssertEqual(show.surfaces, 0)
    }

    /// Past the budget and with no chain in flight, a cut of a song that was seen playing is a
    /// Next (`exhaustedIsAdvance`), not `surfaceSkipFailure`.
    func testExhaustedCutOfASongSeenPlayingAdvancesInsteadOfPausing() {
        XCTAssertTrue(SkipLoadCutRoute.exhaustedIsAdvance(SkipLoadCut(shape: .clear, targetSeenPlaying: true)))
        XCTAssertFalse(SkipLoadCutRoute.exhaustedIsAdvance(SkipLoadCut(shape: .clear, targetSeenPlaying: false)))
    }

    /// A surfaced failure left the index on a song the user's lock-screen Next was meant to leave.
    /// Play must take that Next, not reload the skipped song.
    func testPlayAfterASurfacedFailureDoesNotReplayASkippedSong() async {
        let show = Show()
        show.suspendAt = .prepare
        show.primePlaying()
        // Next #1 to B, then a second in-app Next queued while B loads: the chain is sealed on C.
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        await show.skip()
        // C's load: the owner's third press arrives as a clear (ignored: one follow-up only), and
        // C and its one retry both fail. The failure is surfaced and the player pauses on C.
        show.throwOnLoad = [.prepare, .prepare, .prepare]
        show.releaseOne()
        await show.untilLoadSuspended()
        XCTAssertEqual(show.index, 2)
        show.feed(show.cleared())
        show.finishLoad()
        await show.untilIdle()
        XCTAssertEqual(show.index, 2)
        XCTAssertEqual(show.surfaces, 1, "C could not start")
        XCTAssertEqual(show.coordinator.skippedPastIndex, 2, "the user pressed Next on C")
        show.throwOnLoad = []
        await show.userResume()
        await show.untilIdle()
        XCTAssertEqual(show.lastResumeDecision, .advancePastSkipped)
        show.assertPlaying(index: 3)
        XCTAssertEqual(show.reloads, 1, "only C's own retry; Play did not reload C")
    }

    /// Without a skipped-past mark, Play after a surfaced failure still reloads the selected song.
    func testPlayAfterASurfacedFailureWithNoSkippedPastSongReloadsTheSelectedSong() {
        XCTAssertEqual(SkippedPastResume.decide(.reloadSelected, selectedIndex: 1, skippedPast: nil, queueCount: 6),
                       .asDecided(.reloadSelected))
        XCTAssertEqual(SkippedPastResume.decide(.playLoaded, selectedIndex: 1, skippedPast: 1, queueCount: 6),
                       .asDecided(.playLoaded))
        XCTAssertEqual(SkippedPastResume.decide(.reloadSelected, selectedIndex: 5, skippedPast: 5, queueCount: 6),
                       .asDecided(.reloadSelected), "the last song has nothing to advance to")
        XCTAssertEqual(SkippedPastResume.decide(.reloadSelected, selectedIndex: 1, skippedPast: 1, queueCount: 6),
                       .advancePastSkipped)
    }

    /// DJ variant: B's break is prepared, then the owner's second Next arrives only as a clear.
    /// B's break is dropped (`songCut(afterTrack: 1)`) and never airs. Ends on C.
    func testSecondLockScreenNextDropsTheSkippedSongsPreparedBreak() async {
        // Chatty: the only preset that plans back-to-back breaks, so B has one of its own.
        let show = await Show.preparedBreak(commentary: .chatty)
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        await show.startSongAndPrepareItsBreak()
        XCTAssertTrue(show.breakIsReady(afterTrack: 1), "B's break is ready before the second Next")
        show.feed(show.sample(playing: true, position: 0.5))
        show.feed(show.cleared())
        await show.untilIdle()
        await show.untilDropsSettle()
        await show.assertBreakNotAiring(advancedTo: 2)
        XCTAssertEqual(show.reloads, 0)
        XCTAssertTrue(show.cutBreaks.contains(1), "songCut(afterTrack: 1) ran for the skipped song")
        let dropped = await show.preparer?.testResult(afterTrack: 1)
        XCTAssertEqual(dropped, .skipped(.notNaturalBoundary))
        let aired = await show.session?.naturalBoundary(afterTrack: 1)
        XCTAssertNil(aired, "B's prepared break was dropped with the skip and is not played")
    }

    // MARK: - #444 build 43, Sentinel: a cut-as-Next never plays over a hold

    func testCutAsNextWhilePausedDoesNotPlayAndKeepsThePause() async {
        await assertCutUnderHoldDoesNotPlay("pause") { $0.pause() }
    }

    func testCutAsNextDuringAnInterruptionDoesNotPlayAndKeepsTheHold() async {
        await assertCutUnderHoldDoesNotPlay("interruption") { $0.interruptionBegan() }
    }

    func testCutAsNextAfterRouteLossDoesNotPlayAndKeepsTheHold() async {
        await assertCutUnderHoldDoesNotPlay("route") { $0.routeRemoved() }
    }

    /// The route itself: any hold ignores the cut, whatever the play phase.
    func testSkipLoadCutRouteIgnoresEveryHold() {
        for awaiting in [false, true] {
            XCTAssertEqual(SkipLoadCutRoute.decide(awaitingOwnPlay: awaiting, userWantsPlayback: false,
                                                   pausedBySystem: false), .ignoreHeld)
            XCTAssertEqual(SkipLoadCutRoute.decide(awaitingOwnPlay: awaiting, userWantsPlayback: true,
                                                   pausedBySystem: true), .ignoreHeld)
        }
        XCTAssertEqual(SkipLoadCutRoute.decide(awaitingOwnPlay: true, userWantsPlayback: true,
                                               pausedBySystem: false), .reloadSameSong)
        XCTAssertEqual(SkipLoadCutRoute.decide(awaitingOwnPlay: false, userWantsPlayback: true,
                                               pausedBySystem: false), .advance)
    }

    /// B loaded and playing, a hold lands, then the system clears B (the lock-screen Next while
    /// held). Also a hold whose skip-load flag a poll could still see: the hold is forced on
    /// the policy only, so the route itself has to refuse. No play(), no userPlay(), hold stays.
    private func assertCutUnderHoldDoesNotPlay(_ name: String, _ hold: (Show) -> Void,
                                               file: StaticString = #filePath, line: UInt = #line) async {
        for policyOnly in [false, true] {
            let show = Show()
            show.primePlaying()
            show.feed(show.cleared())
            await show.untilLoadSuspended()
            show.finishLoad()
            await show.untilIdle()
            show.feed(show.sample(playing: true, position: 0.5))
            if policyOnly { show.holdPolicyOnly(name) } else { hold(show) }
            let plays = show.playCalls
            let userPlays = show.userPlays
            show.feed(show.cleared())
            await show.untilIdle()
            XCTAssertEqual(show.playCalls, plays, "\(name) policyOnly=\(policyOnly): no play()", file: file, line: line)
            XCTAssertEqual(show.userPlays, userPlays, "\(name) policyOnly=\(policyOnly): no userPlay()", file: file, line: line)
            XCTAssertEqual(show.index, 1, "\(name) policyOnly=\(policyOnly)", file: file, line: line)
            XCTAssertFalse(show.audible, "\(name) policyOnly=\(policyOnly)", file: file, line: line)
            if name == "pause" {
                XCTAssertFalse(show.policy.userWantsPlayback, file: file, line: line)
            } else {
                XCTAssertTrue(show.policy.pausedBySystem, "\(name): the hold stays", file: file, line: line)
            }
        }
    }


    // MARK: - #459 B1 (Sentinel): a hold between the route decision and the step wins

    /// The route said `.advance` (no hold yet), then a call or route loss reaches the session policy
    /// before the step runs (a deferred interruption replay updates the policy without invalidating
    /// the chain). The cut-derived step passes `allowsStep()`: no play(), no userPlay(), hold stays.
    func testHoldBetweenTheRouteAndACutAsNextStepDoesNotPlay() async {
        for hold in ["interruption", "route"] {
            let show = Show()
            await show.landOnBPlaying()
            let plays = show.playCalls
            let userPlays = show.userPlays
            show.feed(show.cleared())
            XCTAssertEqual(show.lastCutAwaitingPlay, false, "\(hold): routed as a Next")
            show.holdPolicyOnly(hold)
            await show.untilIdle()
            show.assertHeldWithoutPlay(hold, plays: plays, userPlays: userPlays)
        }
    }

    /// The same for `exhaustedAdvance`: B's recovery is spent, a cut lands while some other
    /// attempt's `play()` is awaiting (no chain in flight), so `noteLoadCut` is `.exhausted`, and
    /// B was seen playing, so the cut is taken as a Next. A hold lands before that step runs.
    func testHoldBetweenTheRouteAndAnExhaustedAdvanceStepDoesNotPlay() async {
        for hold in ["interruption", "route"] {
            let show = Show()
            await show.spendBsRecovery()
            show.feed(show.sample(playing: true, position: 0.5))
            show.beginOwnPlayOutsideASkip()
            let plays = show.playCalls
            let userPlays = show.userPlays
            show.feed(show.cleared())
            XCTAssertEqual(show.lastCutAwaitingPlay, true, hold)
            XCTAssertEqual(show.lastExhaustedAdvance, true, "\(hold): the exhausted cut is taken as a Next")
            show.holdPolicyOnly(hold)
            await show.untilIdle()
            show.assertHeldWithoutPlay(hold, plays: plays, userPlays: userPlays)
        }
    }

    /// Control for both: with no hold, the same cut-derived steps do advance to C.
    func testCutDerivedStepsAdvanceWhenNoHoldLands() async {
        let viaNext = Show()
        await viaNext.landOnBPlaying()
        viaNext.feed(viaNext.cleared())
        await viaNext.untilIdle()
        viaNext.assertPlaying(index: 2)

        let viaExhausted = Show()
        await viaExhausted.spendBsRecovery()
        viaExhausted.feed(viaExhausted.sample(playing: true, position: 0.5))
        viaExhausted.beginOwnPlayOutsideASkip()
        viaExhausted.feed(viaExhausted.cleared())
        XCTAssertEqual(viaExhausted.lastExhaustedAdvance, true)
        await viaExhausted.untilIdle()
        XCTAssertEqual(viaExhausted.index, 2)
        XCTAssertTrue(viaExhausted.audible)
    }

    /// A real user Next keeps its privilege: pressed while held, it still plays (unchanged rule).
    func testUserNextStillOpensWithFreshNextPrivilegeUnderAHold() async {
        let show = Show()
        await show.landOnBPlaying()
        show.holdPolicyOnly("route")
        await show.skip()
        await show.untilIdle()
        XCTAssertEqual(show.index, 2)
        XCTAssertTrue(show.audible)
        XCTAssertFalse(show.policy.pausedBySystem, "the user's Next calls userPlay() and clears the hold")
    }

    /// Coordinator level: a cut-opened chain's first step is gated; a user-opened one is not.
    func testCoordinatorGatesOnlyTheCutOpenedFirstStep() async {
        var held = false
        let coordinator = SkipCoordinator()
        coordinator.stepGate = { (true, held) }
        XCTAssertEqual(coordinator.noteCutAsNext(from: 1), .begin)
        held = true
        var ran = 0
        await coordinator.runChain { _ in ran += 1; return .playing }
        XCTAssertEqual(ran, 0, "the cut-opened step does not run over the hold")
        XCTAssertFalse(coordinator.isInFlight)

        XCTAssertEqual(coordinator.requestAdvance(), .begin)
        await coordinator.runChain { job in
            XCTAssertTrue(coordinator.admits(job), "the user's own Next keeps its privilege")
            ran += 1
            return .playing
        }
        XCTAssertEqual(ran, 1)
    }

    // MARK: - #444 build 43 diagnostics

    func testDiagnosticLinesCarryOnlyIndexesTokensAndCounts() {
        XCTAssertEqual(PlaybackLog.remoteNextCommand(index: 1), "remoteNextCommand fired index=1")
        XCTAssertEqual(PlaybackLog.skipLoadCut(index: 1, generation: 4, shape: .clear, chainInFlight: false,
                                               awaitingPlay: true, recoveries: 0, disposition: "folded"),
                       "skipLoadCut index=1 generation=4 shape=clear chainInFlight=false awaitingPlay=true recoveries=0 disposition=folded")
        XCTAssertEqual(PlaybackLog.skipStep(job: .reload, target: 2, result: .failed(.couldNotStart, target: 2)),
                       "skipStep job=reload target=2 result=failedCouldNotStart")
        XCTAssertEqual(PlaybackLog.skipSurface(reason: .exhausted, index: 1), "skipSurface reason=exhausted index=1")
        XCTAssertEqual(PlaybackLog.resumeDecision(ResumeTargetDecision.reloadSelected.logToken, index: 1),
                       "resume decision=reloadSelected index=1")
    }

    /// `MusicKitService` wires the build 43 routing, logs every cut with `awaitingPlay=`, and
    /// converts a cut to a Next only through the skip path.
    func testMusicKitServiceRoutesACutThroughTheSkipPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("AeroDJ/MusicKitService.swift"), encoding: .utf8)
        let body = source.split(separator: "private func noteSkipLoadCut(").dropFirst().first.map(String.init) ?? ""
        let cutFunc = body.split(separator: "\n    private func ").first.map(String.init) ?? ""
        XCTAssertTrue(cutFunc.contains("SkipLoadCutRoute.decide("))
        XCTAssertTrue(cutFunc.contains("selfStartGate.isAwaitingPlay(attempts.current)"))
        XCTAssertTrue(cutFunc.contains("skipCoordinator.noteCutAsNext(from: index)"))
        XCTAssertTrue(cutFunc.contains("startSkip(intake)"), "a cut-as-Next runs oneSkip(.advance)")
        XCTAssertFalse(cutFunc.contains("userPlay()"), "the cut path never calls userPlay() itself")
        XCTAssertFalse(cutFunc.contains("player.play()"))
        XCTAssertTrue(cutFunc.contains("awaitingPlay: awaitingPlay"), "every cut logs awaitingPlay=")
        XCTAssertTrue(source.contains("PlaybackLog.remoteNextCommand(index:"))
        XCTAssertTrue(source.contains("PlaybackLog.skipStep(job:"))
        XCTAssertTrue(source.contains("PlaybackLog.skipSurface(reason:"))
        XCTAssertTrue(source.contains("PlaybackLog.resumeDecision("))
        XCTAssertTrue(source.contains("selfStartGate.playThrew(attempt)"))
        XCTAssertTrue(source.contains("skipCoordinator.noteSelected(index: next)"))
        XCTAssertFalse(source.contains("logPlayback(\"skipLoadCut index="), "the old unstructured line is gone")
    }
}

// MARK: - Show

/// The skip/poll loop `MusicKitService` runs, on the real engine and detector.
/// A prepared or airing break uses the real session, preparer and on-device renderer.
///
/// #444 build 43: a load is `prepareToPlay` then `play()`, like `playIfStillAllowed`. The real
/// `SelfStartInterruptionGate` marks our `play()` awaiting. `suspendAt` picks where the load waits
/// (default: inside `play()`, where the Duo spends its 831 ms), and `throwOnLoad` makes the next
/// loads throw at a phase. The poll routes a cut with the real `SkipLoadCutRoute`.
@MainActor
private final class Show {
    enum LoadPhase: CustomStringConvertible {
        case prepare
        case play
        var description: String { self == .prepare ? "prepare" : "play" }
    }

    let songs = 6
    let coordinator = SkipCoordinator()
    var boundaries = BoundaryInterpreter()
    var engine = PlaybackEngine()
    var policy = AudioSessionPolicy()
    private var attempts = PlaybackAttempts()
    private var startGate = SelfStartInterruptionGate()
    private let gate = LoadGate()
    /// Where a load waits for `finishLoad()` / `releaseOne()`.
    var suspendAt: LoadPhase = .play
    /// One entry per load, in order: that load throws at this phase. Taken when the load starts.
    var throwOnLoad: [LoadPhase?] = []
    private(set) var index = 0
    private(set) var audible = false
    private(set) var pausedByNoProgress = false
    private(set) var loadCuts = 0
    private(set) var noProgressEnds = 0
    private(set) var reloads = 0
    private(set) var advances = 0
    private(set) var playCalls = 0
    private(set) var userPlays = 0
    private(set) var surfaces = 0
    private(set) var queueEmpty = false
    private(set) var unexpectedBoundary: BoundaryStep?
    private(set) var speechOverlapped = false
    private(set) var lastCutAwaitingPlay: Bool?
    private(set) var lastCutShape: SkipLoadCutShape?
    private(set) var lastResumeDecision: SkippedPastResume?
    private(set) var lastExhaustedAdvance: Bool?
    private(set) var cutBreaks: [Int] = []
    /// `nowPlaying` ids and paused transports seen after `markHistory()`.
    private(set) var nowPlayingHistory: [String] = []
    private(set) var everPaused = false
    private var recording = false
    private var loadedTarget: LoadedPlayerTarget?
    private var pendingDrops: [Task<Void, Never>] = []
    private var clock: TimeInterval = 100
    let session: DJBreakSession?
    let preparer: DJBreakPreparer?
    let dj: DJPresentationStore?

    init() {
        session = nil
        preparer = nil
        dj = nil
        startEngine()
    }

    private init(session: DJBreakSession, preparer: DJBreakPreparer, dj: DJPresentationStore) {
        self.session = session
        self.preparer = preparer
        self.dj = dj
        startEngine()
    }

    /// Song 0 playing, its break rendered and waiting. Not on air.
    static func preparedBreak(commentary: CommentaryFrequency = .frequent) async -> Show {
        let rig = await Self.makeSession(commentary: commentary)
        await rig.session.queueStarted(djTracks(8))
        await rig.session.songStarted(index: 0, remaining: .seconds(180))
        let show = Show(session: rig.session, preparer: rig.preparer, dj: rig.dj)
        await show.waitUntilReady()
        return show
    }

    /// That break has been handed out and the player reports it speaking.
    static func airingBreak() async -> Show {
        let show = await preparedBreak()
        let handed = await show.session?.naturalBoundary(afterTrack: 0)
        XCTAssertNotNil(handed, "the airing break is the one the preparer rendered")
        XCTAssertFalse(handed?.clips.isEmpty ?? true, "VoiceRenderer produced the break's audio")
        show.beginSpeech()
        return show
    }

    private static func makeSession(commentary: CommentaryFrequency) async
        -> (session: DJBreakSession, preparer: DJBreakPreparer, dj: DJPresentationStore) {
        var config = StationConfiguration(commentary: commentary)
        config.seeds = [StationSeed(kind: .artist, catalogID: "skip", name: "Artist")]
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        await station.setPlaybackActivity(.holdingSong)
        let renderer = VoiceRenderer(
            routes: [VoiceRoute(providerID: "device", provider: DoubleSkipVoice(), voice: djVoice)],
            budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        await session.start()
        return (session, preparer, dj)
    }

    var breakIsReady: Bool {
        if case .ready = dj?.state { return true }
        return false
    }

    func breakIsReady(afterTrack track: Int) -> Bool {
        if case let .ready(afterTrack, _, _) = dj?.state { return afterTrack == track }
        return false
    }

    /// `onSongStarted` for the song now playing: the existing `DJBreakSession.songStarted` hook,
    /// then wait until its break is rendered.
    func startSongAndPrepareItsBreak() async {
        guard let session, let dj else { return }
        guard session.testPlannedBreaks[index] != nil else {
            XCTFail("no break is planned after track \(index)")
            return
        }
        await session.songStarted(index: index, remaining: .seconds(180))
        if breakIsReady(afterTrack: index) { return }
        for await state in dj.updates() {
            if case let .ready(afterTrack, _, _) = state, afterTrack == index { return }
        }
    }

    func assertPlaying(index expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(index, expected, "queue index", file: file, line: line)
        XCTAssertEqual(engine.snapshot.nowPlaying?.id, "t\(expected)", file: file, line: line)
        XCTAssertEqual(engine.snapshot.transport, .playing, file: file, line: line)
        XCTAssertTrue(audible, "the player is audible", file: file, line: line)
        XCTAssertFalse(pausedByNoProgress, file: file, line: line)
        XCTAssertNil(unexpectedBoundary, file: file, line: line)
    }

    /// The owner's acceptance: on `index`, playing and audible, never paused, no reload, and the
    /// two songs left behind never come back as now playing.
    func assertOwnerOutcome(index expected: Int, _ label: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        assertPlaying(index: expected, file: file, line: line)
        XCTAssertEqual(reloads, 0, "\(label) no reload", file: file, line: line)
        XCTAssertFalse(everPaused, "\(label) never paused", file: file, line: line)
        XCTAssertEqual(surfaces, 0, "\(label) no surfaced failure", file: file, line: line)
        XCTAssertFalse(nowPlayingHistory.contains("t0"), "\(label)", file: file, line: line)
        XCTAssertFalse(nowPlayingHistory.contains("t1"), "\(label) the skipped song never comes back", file: file, line: line)
    }

    func assertBreakNotAiring(advancedTo expected: Int) async {
        assertPlaying(index: expected)
        XCTAssertFalse(dj?.state.isLive ?? false, "no break is speaking")
        XCTAssertFalse(speechOverlapped, "a second line started while one was still speaking")
        XCTAssertNotEqual(dj?.state.speakingTrack, 0)
    }

    func markHistory() {
        recording = true
        nowPlayingHistory = []
        everPaused = false
    }

    /// `extraPresses` arrive while the first load is suspended. 0, 1 and 2 cover single, double, triple.
    func finishSkips(extraPresses: Int) async {
        let running = Task { await skip() }
        await untilLoadSuspended()
        for _ in 0..<extraPresses {
            await skip()
        }
        finishLoad()
        await running.value
        await untilIdle()
    }

    /// Same intake as `MusicKitService.skip()`.
    func skip() async {
        installGate()
        await startSkip(coordinator.requestAdvance())
    }

    /// Same as `MusicKitService.startSkip`.
    private func startSkip(_ intake: SkipCoordinator.Intake) async {
        switch intake {
        case .queueOneMore, .ignore, .beginWhenIdle:
            return
        case .begin:
            boundaries.setSkipLoadInFlight(true)
            await coordinator.runChain(surface: { self.surface($0) }) { job in
                await self.perform(job)
            }
        }
    }

    private func installGate() {
        guard coordinator.stepGate == nil else { return }
        coordinator.stepGate = { [weak self] in
            guard let self else { return (false, true) }
            return (self.policy.userWantsPlayback, self.policy.pausedBySystem)
        }
    }

    func finishLoad() { gate.release() }

    func releaseOne() { gate.releaseOne() }

    var playAwaiting: Bool { startGate.isAwaitingPlay(attempts.current) }

    /// Same bookkeeping as `MusicKitService.pause`: the in-flight load is invalidated and the
    /// skip-load flag is cleared, so the next Next has to set the flag itself.
    func pause() {
        coordinator.invalidate(.userPause)
        boundaries.setSkipLoadInFlight(false)
        _ = policy.userPause()
        boundaries.pausedByApp(.userPause)
        audible = false
    }

    /// `applySessionUngated` + `performSessionStep` for an interruption that began.
    func interruptionBegan() {
        _ = policy.handle(.interruptionBegan, breakIsActive: false)
        coordinator.invalidate(.interruptionBegan)
        boundaries.setSkipLoadInFlight(false)
        boundaries.pausedByApp(.systemInterruption)
        audible = false
        apply(.interruptionPaused)
    }

    /// The same for a route loss.
    func routeRemoved() {
        _ = policy.handle(.routeChanged(.oldDeviceUnavailable), breakIsActive: false)
        coordinator.invalidate(.routeRemoved)
        boundaries.setSkipLoadInFlight(false)
        boundaries.pausedByApp(.routeLoss)
        audible = false
        apply(.routePaused)
    }

    /// A hold on the session policy only: the detector still has the skip-load flag and still
    /// reports the cut, so `SkipLoadCutRoute` alone has to refuse it.
    func holdPolicyOnly(_ name: String) {
        switch name {
        case "pause": _ = policy.userPause()
        case "interruption": _ = policy.handle(.interruptionBegan, breakIsActive: false)
        default: _ = policy.handle(.routeChanged(.oldDeviceUnavailable), breakIsActive: false)
        }
        audible = false
    }

    /// `MusicKitService.resume()`: the skipped-past guard, read before `stopSkipForPlay`, then
    /// `LoadedTargetPolicy`.
    func userResume() async {
        policy.userPlay()
        userPlays += 1
        let skippedPast = coordinator.skippedPastIndex
        if coordinator.hasPendingSkipWork {
            coordinator.invalidate(.userPlay)
            boundaries.setSkipLoadInFlight(false)
        }
        let base = LoadedTargetPolicy.decide(loaded: loadedTarget, selectedIndex: index,
                                             generation: attempts.queueGeneration, selectedIsPlayable: true)
        let decision = SkippedPastResume.decide(base, selectedIndex: index, skippedPast: skippedPast,
                                                queueCount: songs)
        lastResumeDecision = decision
        if decision == .advancePastSkipped {
            apply(.userResumed)
            installGate()
            await startSkip(coordinator.requestAdvance())
            return
        }
        let attempt = attempts.beginStart()
        startGate.startBegan(attempt)
        if base == .reloadSelected { adoptLoadedEntry() }
        playCalls += 1
        loadedTarget = LoadedPlayerTarget(index: index, generation: attempts.queueGeneration)
        audible = true
        apply(.userResumed)
        apply(.playbackConfirmed)
    }

    /// A from A by a lock-screen Next, B loaded and playing at 0.5 s.
    func landOnBPlaying() async {
        primePlaying()
        feed(cleared())
        await untilLoadSuspended()
        finishLoad()
        await untilIdle()
        feed(sample(playing: true, position: 0.5))
    }

    /// Echo's case: one Next, a cut while B's `play()` is awaiting, B reloaded. B's one recovery
    /// is spent and B has not played past the failed-start window.
    func spendBsRecovery() async {
        suspendAt = .play
        primePlaying()
        feed(cleared())
        await untilLoadSuspended()
        feed(sample(playing: true, position: 0.5))
        feed(cleared())
        finishLoad()
        await untilIdle()
        XCTAssertEqual(index, 1)
        XCTAssertEqual(reloads, 1)
    }

    /// Another attempt (not a skip) has called `play()` and it has not returned.
    func beginOwnPlayOutsideASkip() {
        let attempt = attempts.beginStart()
        startGate.startBegan(attempt)
        startGate.playCalled(attempt, at: clock)
    }

    func assertHeldWithoutPlay(_ name: String, plays: Int, userPlays: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(playCalls, plays, "\(name): no play()", file: file, line: line)
        XCTAssertEqual(self.userPlays, userPlays, "\(name): no userPlay()", file: file, line: line)
        XCTAssertEqual(index, 1, "\(name): still on B", file: file, line: line)
        XCTAssertFalse(audible, name, file: file, line: line)
        XCTAssertTrue(policy.pausedBySystem, "\(name): the hold stays", file: file, line: line)
        XCTAssertFalse(coordinator.isInFlight, name, file: file, line: line)
    }

    func untilLoadSuspended() async {
        for _ in 0..<1000 where !gate.isWaiting { await Task.yield() }
        XCTAssertTrue(gate.isWaiting, "the skip load is in flight")
    }

    func untilIdle() async {
        for _ in 0..<1000 where coordinator.isInFlight || gate.isWaiting { await Task.yield() }
        XCTAssertFalse(coordinator.isInFlight)
    }

    func untilDropsSettle() async {
        let drops = pendingDrops
        pendingDrops = []
        for drop in drops { await drop.value }
    }

    /// One poll, in `MusicKitService.pollPlaybackPosition`'s order.
    func feed(_ observation: PlaybackObservation) {
        if observation.entryID == nil { queueEmpty = true }
        let step = boundaries.interpret(observation, queueIndex: index, queueCount: songs)
        if boundaries.takeSkipLoadProgress() { coordinator.noteProgress() }
        if let step {
            unexpectedBoundary = step
            return
        }
        if boundaries.takeRemoteSkip() {
            Task { await self.skip() }
            return
        }
        let cut = boundaries.pendingSkipLoadCut
        if boundaries.takeSkipLoadCut(), let cut {
            loadCuts += 1
            noteSkipLoadCut(cut)
            return
        }
        if boundaries.takeNoProgressEnd() {
            noProgressEnds += 1
            if coordinator.isInFlight { return }
            pausedByNoProgress = true
            audible = false
            apply(.userPaused)
        }
    }

    /// Same decisions as `MusicKitService.noteSkipLoadCut`.
    private func noteSkipLoadCut(_ cut: SkipLoadCut) {
        installGate()
        let awaiting = startGate.isAwaitingPlay(attempts.current)
        lastCutAwaitingPlay = awaiting
        lastCutShape = cut.shape
        loadedTarget = nil
        let at = index
        switch SkipLoadCutRoute.decide(awaitingOwnPlay: awaiting, userWantsPlayback: policy.userWantsPlayback,
                                       pausedBySystem: policy.pausedBySystem) {
        case .ignoreHeld:
            return
        case .advance:
            let intake = coordinator.noteCutAsNext(from: at)
            Task { await self.startSkip(intake) }
            return
        case .reloadSameSong:
            break
        }
        switch coordinator.noteLoadCut(target: at) {
        case .folded:
            return
        case .recover:
            boundaries.setSkipLoadInFlight(true)
            Task {
                await self.coordinator.runRecovery(surface: { self.surface($0) }) { job in
                    await self.perform(job)
                }
            }
        case .exhausted:
            if SkipLoadCutRoute.exhaustedIsAdvance(cut) {
                lastExhaustedAdvance = true
                let intake = coordinator.noteCutAsNext(from: at)
                Task { await self.startSkip(intake) }
                return
            }
            pausedByNoProgress = true
            surface(.couldNotStart)
        }
    }

    /// `surfaceSkipFailure`: pause, recoverable banner, the selected song is not loaded.
    private func surface(_ failure: SkipTerminalFailure) {
        surfaces += 1
        boundaries.setSkipLoadInFlight(false)
        loadedTarget = nil
        audible = false
        boundaries.pausedByApp(.userPause)
        if policy.userWantsPlayback { _ = policy.userPause() }
        apply(.userPaused)
    }

    func primePlaying() {
        for position in stride(from: 0.0, through: 60.0, by: 1.0) {
            feed(sample(entry: "song-0", playing: true, position: position))
        }
    }

    func cleared() -> PlaybackObservation {
        clock += 1
        return PlaybackObservation(entryID: nil, isPlaying: false, position: nil, duration: nil, uptime: clock)
    }

    func rewound() -> PlaybackObservation {
        sample(entry: "song-\(index)", playing: false, position: 0)
    }

    func sample(playing: Bool, position: TimeInterval) -> PlaybackObservation {
        sample(entry: "song-\(index)", playing: playing, position: position)
    }

    private func sample(entry: String, playing: Bool, position: TimeInterval) -> PlaybackObservation {
        clock += 1
        return PlaybackObservation(entryID: entry, isPlaying: playing, position: position, duration: 200, uptime: clock)
    }

    private func startEngine() {
        let tracks = (0..<songs).map { TrackInfo(id: "t\($0)", title: "Song \($0)", artistName: "Artist") }
        engine.apply(.queueStarted(tracks: tracks, startIndex: 0, station: nil))
        engine.apply(.playbackConfirmed)
        policy.userPlay()
        loadedTarget = LoadedPlayerTarget(index: 0, generation: attempts.queueGeneration)
        audible = true
    }

    private func apply(_ event: PlaybackEvent) {
        engine.apply(event)
        guard recording else { return }
        if let id = engine.snapshot.nowPlaying?.id { nowPlayingHistory.append(id) }
        if engine.snapshot.transport == .paused { everPaused = true }
    }

    private func perform(_ job: SkipJob) async -> SkipLoadResult {
        guard coordinator.admits(job) else { return .cancelled }
        let throwAt = throwOnLoad.isEmpty ? nil : throwOnLoad.removeFirst()
        var dropped: Task<Void, Never>?
        switch job {
        case .advance:
            advances += 1
            boundaries.setSkipLoadInFlight(true)
            boundaries.userRequestedChange()
            policy.userPlay()
            userPlays += 1
            let cut = index
            stopSpeechIfAiring()
            // `onSongSkipped(queueIndex)`: the skipped song's prepared break is dropped.
            let drop = Task { await self.dropPreparedBreak(after: cut) }
            pendingDrops.append(drop)
            dropped = drop
            let next = index + 1
            guard next < songs else {
                boundaries.setSkipLoadInFlight(false)
                audible = false
                apply(.queueFinished)
                await drop.value
                return .queueStopped
            }
            index = next
            coordinator.noteSelected(index: next)
            apply(.userSkipped(nextIndex: index))
            boundaries.userRequestedChange()
            adoptLoadedEntry()
            await Task.yield()
        case .reload:
            reloads += 1
            boundaries.userRequestedChange()
            boundaries.setSkipLoadInFlight(true)
            adoptLoadedEntry()
        }
        let attempt = attempts.beginStart()
        startGate.startBegan(attempt)
        loadedTarget = LoadedPlayerTarget(index: index, generation: attempts.queueGeneration)
        let result = await load(attempt: attempt, throwAt: throwAt)
        if let dropped { await dropped.value }
        if job == .reload, case .playing = result { queueEmpty = false }
        switch result {
        case .playing:
            audible = true
            if engine.snapshot.transport == .preparing { apply(.playbackConfirmed) }
        case .cancelled, .failed, .queueStopped, .loadCut:
            boundaries.setSkipLoadInFlight(false)
            loadedTarget = nil
        }
        return result
    }

    /// `playIfStillAllowed`: prepare, `playCalled`, play, `playReturned` (or `playThrew`).
    private func load(attempt: PlaybackAttemptID, throwAt: LoadPhase?) async -> SkipLoadResult {
        if suspendAt == .prepare { await gate.wait() }
        if throwAt == .prepare { return .failed(.couldNotStart, target: index) }
        startGate.playCalled(attempt, at: clock)
        playCalls += 1
        if suspendAt == .play { await gate.wait() }
        if throwAt == .play {
            startGate.playThrew(attempt)
            return .failed(.couldNotStart, target: index)
        }
        startGate.playReturned(attempt, at: clock)
        guard attempts.isCurrent(attempt) else { return .cancelled }
        if !policy.userWantsPlayback || policy.pausedBySystem { return .cancelled }
        return .playing
    }

    /// `onBreakMustStop`: a speaking break stops before the next load. A line that is only
    /// prepared is not speaking; `songCut` drops it.
    private func stopSpeechIfAiring() {
        guard let dj, dj.state.isLive else { return }
        let track = dj.state.speakingTrack ?? index
        dj.send(.playbackFailed(afterTrack: track))
        if dj.state.isLive { speechOverlapped = true }
    }

    private func dropPreparedBreak(after track: Int) async {
        guard let session else { return }
        cutBreaks.append(track)
        await session.songCut(afterTrack: track)
    }

    private func beginSpeech() {
        guard let dj else { return }
        if dj.state.isLive { speechOverlapped = true }
        dj.send(.playbackStarted(afterTrack: index))
        dj.updateSpeechLevel(0.5, afterTrack: index)
    }

    private func adoptLoadedEntry() {
        let step = boundaries.interpret(sample(entry: "song-\(index)", playing: false, position: 0),
                                        queueIndex: index, queueCount: songs)
        if let step { unexpectedBoundary = step }
    }

    private func waitUntilReady() async {
        guard let dj else { return }
        if breakIsReady { return }
        for await state in dj.updates() {
            if case .ready = state { return }
        }
    }
}

/// On-device, free, no delay. The prepared break's audio is this renderer's clip.
private struct DoubleSkipVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 1, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
private final class LoadGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isWaiting = false

    func wait() async {
        if open { return }
        isWaiting = true
        await withCheckedContinuation { waiters.append($0) }
        isWaiting = false
    }

    func release() {
        open = true
        isWaiting = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func releaseOne() {
        guard !waiters.isEmpty else { return }
        if waiters.count == 1 { isWaiting = false }
        waiters.removeFirst().resume()
    }
}
