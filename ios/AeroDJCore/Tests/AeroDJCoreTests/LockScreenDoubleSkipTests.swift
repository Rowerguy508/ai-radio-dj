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

    // MARK: - #444 after #459: a Next that clears the skip's song before the poll has seen it

    /// The 1 s poll has not run since B was installed and started (no sample of B), and the second
    /// lock-screen Next clears B. Before this fix the detector still held A's facts (or none), so the
    /// clear reported nothing: no cut, no remote skip, no failed start. The chain had already ended
    /// on `.playing`, so the app showed B playing on an empty MusicKit queue: the freeze.
    func testSecondNextClearingTheSkipsSongBeforeAnyPollSawItAdvancesToTheNextSong() async {
        let show = Show()
        show.pollSeesLoadedEntry = false
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        show.markHistory()
        show.feed(show.cleared())
        await show.untilIdle()
        show.assertOwnerOutcome(index: 2)
        XCTAssertEqual(show.loadCuts, 1, "the clear of B is reported as a cut of B")
        XCTAssertEqual(show.lastCutAwaitingPlay, false)
        XCTAssertEqual(show.lastCutShape, .clear)
        XCTAssertEqual(show.advances, 2)
        XCTAssertEqual(show.noProgressEnds, 0)
    }

    /// The same when the first Next was the app's own (in-app Skip or the command target), so the
    /// detector still holds A's entry with the app's change pending when B is cleared.
    func testClearOfAnUnseenSkipSongAfterAnInAppNextAdvancesToTheNextSong() async {
        let show = Show()
        show.pollSeesLoadedEntry = false
        show.primePlaying()
        let running = Task { await show.skip() }
        await show.untilLoadSuspended()
        show.finishLoad()
        await running.value
        await show.untilIdle()
        show.assertPlaying(index: 1)
        show.markHistory()
        show.feed(show.cleared())
        await show.untilIdle()
        show.assertOwnerOutcome(index: 2)
        XCTAssertEqual(show.loadCuts, 1)
        XCTAssertNil(show.unexpectedBoundary, "A's entry going away is not a natural end")
        XCTAssertEqual(show.noProgressEnds, 0)
    }

    /// Three lock-screen Nexts, each clearing the song the previous one loaded before a poll saw it.
    func testThreeNextsThatEachClearAnUnseenSkipSongLandThreeSongsOn() async {
        let show = Show()
        show.pollSeesLoadedEntry = false
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.feed(show.cleared())
        await show.untilIdle()
        show.assertPlaying(index: 2)
        show.feed(show.cleared())
        await show.untilIdle()
        show.assertPlaying(index: 3)
        XCTAssertEqual(show.reloads, 0)
        XCTAssertEqual(show.surfaces, 0)
    }

    /// The clear is first seen while our `play()` for B is still awaiting, with no sample of B. That
    /// poll reports nothing (the route cannot tell yet). Once `play()` returns, the next poll still
    /// sees the empty queue and that is routed as the user's Next, the trade-off #459 accepted for a
    /// cut only seen after our `play()` returned. It never pauses and never reloads B.
    func testAnUnseenClearFirstPolledWhilePlayAwaitsIsRoutedOnceOurPlayReturned() async {
        let show = Show()
        show.pollSeesLoadedEntry = false
        show.suspendAt = .play
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        XCTAssertTrue(show.playAwaiting)
        show.feed(show.cleared())
        XCTAssertEqual(show.loadCuts, 0, "nothing is decided while our play() is awaiting")
        show.finishLoad()
        await show.untilIdle()
        show.markHistory()
        show.feed(show.cleared())
        await show.untilIdle()
        show.assertOwnerOutcome(index: 2)
        XCTAssertEqual(show.loadCuts, 1)
    }

    /// Detector controls for the unseen clear.
    func testUnseenClearIsACutOnlyForAStartedSkipLoadWithNoHold() {
        func primed() -> (BoundaryInterpreter, TimeInterval) {
            var b = BoundaryInterpreter()
            var t: TimeInterval = 100
            for position in stride(from: 0.0, through: 30.0, by: 1.0) {
                _ = b.interpret(PlaybackObservation(entryID: "song-0", isPlaying: true, position: position,
                                                    duration: 200, uptime: t), queueIndex: 0, queueCount: 4)
                t += 1
            }
            return (b, t)
        }
        func clear(_ b: inout BoundaryInterpreter, _ t: TimeInterval) -> BoundaryStep? {
            b.interpret(PlaybackObservation(entryID: nil, isPlaying: false, position: nil, duration: nil, uptime: t),
                        queueIndex: 1, queueCount: 4)
        }
        // The fix: a skip load, our play() returned, no sample of the new entry, then a clear.
        do {
            var (b, t) = primed()
            b.setSkipLoadInFlight(true)
            b.userRequestedChange()
            b.noteOwnPlayReturned()
            XCTAssertNil(clear(&b, t))
            XCTAssertEqual(b.pendingSkipLoadCut, SkipLoadCut(shape: .clear, targetSeenPlaying: false))
            XCTAssertTrue(b.takeSkipLoadCut())
            XCTAssertFalse(b.takeRemoteSkip())
            XCTAssertFalse(b.takeNoProgressEnd())
            t += 1
            XCTAssertNil(clear(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut(), "reported once")
        }
        // Our play() has not returned: nothing is reported (unchanged).
        do {
            var (b, t) = primed()
            b.setSkipLoadInFlight(true)
            b.userRequestedChange()
            XCTAssertNil(clear(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut())
            XCTAssertFalse(b.takeRemoteSkip())
            XCTAssertFalse(b.takeNoProgressEnd())
        }
        // Not a skip load (a natural next song or a tap): nothing is reported (unchanged).
        do {
            var (b, t) = primed()
            b.userRequestedChange()
            b.noteOwnPlayReturned()
            XCTAssertNil(clear(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut())
        }
        // A poll saw the new entry: the existing skip-load path decides, not this one.
        do {
            var (b, t) = primed()
            b.setSkipLoadInFlight(true)
            b.userRequestedChange()
            b.noteOwnPlayReturned()
            XCTAssertNil(b.interpret(PlaybackObservation(entryID: "song-1", isPlaying: true, position: 0.5,
                                                         duration: 200, uptime: t), queueIndex: 1, queueCount: 4))
            t += 1
            XCTAssertNil(clear(&b, t))
            XCTAssertEqual(b.pendingSkipLoadCut, SkipLoadCut(shape: .clear, targetSeenPlaying: true))
        }
        // A user pause or route loss after the load: the hold wins, no cut.
        for cause in [PlaybackBoundaryDetector.HoldCause.userPause, .routeLoss] {
            var (b, t) = primed()
            b.setSkipLoadInFlight(true)
            b.userRequestedChange()
            b.noteOwnPlayReturned()
            b.pausedByApp(cause)
            XCTAssertNil(clear(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut(), "\(cause)")
        }
        // An interruption after the load: no cut.
        do {
            var (b, t) = primed()
            b.setSkipLoadInFlight(true)
            b.userRequestedChange()
            b.noteOwnPlayReturned()
            b.pausedByApp(.systemInterruption)
            XCTAssertNil(clear(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut())
        }
    }

    /// The app reports its own returned `play()` to the detector in `startTrack`.
    func testMusicKitServiceReportsItsReturnedPlayToTheDetector() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("AeroDJ/MusicKitService.swift"), encoding: .utf8)
        let startTrack = source.split(separator: "func startTrack(at index: Int").dropFirst().first.map(String.init) ?? ""
        let body = startTrack.split(separator: "func startNextTrack(").first.map(String.init) ?? ""
        let played = try XCTUnwrap(body.range(of: "playIfStillAllowed(attempt: attempt)"))
        let noted = try XCTUnwrap(body.range(of: "boundaries.noteOwnPlayReturned()"))
        let refused = try XCTUnwrap(body.range(of: "guard started else"))
        XCTAssertLessThan(played.lowerBound, noted.lowerBound)
        XCTAssertLessThan(refused.lowerBound, noted.lowerBound, "only a play() that started the song")
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

    // MARK: - #444 at cafea9d4: MusicKit's own Next, twice, while a break is in flight

    /// The system Next (queue cleared) arrives again while the first skip is still in
    /// `prepareToPlay`, dropping the prepared break. One stored follow-up: two songs on,
    /// still playing, and that break never airs.
    func testMusicKitClearDetectedTwiceWhileDroppingAPreparedBreakStaysPlaying() async {
        let show = await Show.preparedBreak()
        XCTAssertTrue(show.breakIsReady)
        await show.musicKitSkipsWhileLoading(first: .clear, extra: 1)
        await show.assertBreakNotAiring(advancedTo: 2)
        XCTAssertEqual(show.reloads, 0, "the second clear is a follow-up Next, not a reload")
        XCTAssertEqual(show.surfaces, 0)
        XCTAssertFalse(show.pausedByNoProgress)
        XCTAssertFalse(show.everPaused)
        let dropped = await show.preparer?.testResult(afterTrack: 0)
        XCTAssertEqual(dropped, .skipped(.notNaturalBoundary))
        let aired = await show.session?.naturalBoundary(afterTrack: 0)
        XCTAssertNil(aired, "the prepared break was dropped with the skip and is not played")
    }

    /// The rewind shape of the same moment: the new song has only been seen at 0:00, so the
    /// second rewind is not a distinct Next. It is ignored. Playback stays on the first advance
    /// and the prepared break still does not air.
    func testMusicKitRewindDetectedTwiceWhileDroppingAPreparedBreakDoesNotStick() async {
        let show = await Show.preparedBreak()
        XCTAssertTrue(show.breakIsReady)
        await show.musicKitSkipsWhileLoading(first: .rewind, extra: 1)
        show.assertPlaying(index: 1)
        XCTAssertEqual(show.advances, 1, "the second rewind is ignored, not a second chain")
        XCTAssertEqual(show.reloads, 0)
        XCTAssertEqual(show.surfaces, 0)
        XCTAssertFalse(show.pausedByNoProgress)
        await show.assertPreparedBreakDropped()
    }

    /// A break is on air. Two system clears: the first skip stops the speech, the second is the
    /// one stored follow-up. Speech stays stopped and the player is not paused.
    func testMusicKitClearDetectedTwiceWhileABreakIsAiringStopsItAndStaysPlaying() async {
        let show = await Show.airingBreak()
        XCTAssertTrue(show.dj?.state.isLive == true)
        await show.musicKitSkipsWhileLoading(first: .clear, extra: 1)
        await show.assertBreakNotAiring(advancedTo: 2)
        XCTAssertEqual(show.dj?.speechLevel, 0)
        XCTAssertFalse(show.speechOverlapped)
        XCTAssertEqual(show.surfaces, 0)
        XCTAssertFalse(show.pausedByNoProgress)
        let aired = await show.session?.naturalBoundary(afterTrack: 0)
        XCTAssertNil(aired)
    }

    /// Rewind twice while that break is on air and the first skip is still loading. The second
    /// rewind is not a second Next. Speech stops with the first skip and playback continues.
    func testMusicKitRewindDetectedTwiceWhileABreakIsAiringDoesNotStick() async {
        let show = await Show.airingBreak()
        XCTAssertTrue(show.dj?.state.isLive == true)
        await show.musicKitSkipsWhileLoading(first: .rewind, extra: 1)
        show.assertPlaying(index: 1)
        XCTAssertEqual(show.dj?.speechLevel, 0)
        XCTAssertFalse(show.speechOverlapped)
        XCTAssertEqual(show.advances, 1)
        XCTAssertEqual(show.surfaces, 0)
        XCTAssertFalse(show.pausedByNoProgress)
    }

    /// Three system clears while the first skip is dropping a prepared break. The third is ignored.
    func testThreeMusicKitClearsWhileDroppingAPreparedBreakAdvanceTwice() async {
        let show = await Show.preparedBreak()
        await show.musicKitSkipsWhileLoading(first: .clear, extra: 2)
        await show.assertBreakNotAiring(advancedTo: 2)
        XCTAssertEqual(show.advances, 2, "a triple clear stores one follow-up and ignores the third")
        XCTAssertEqual(show.reloads, 0)
        XCTAssertEqual(show.surfaces, 0)
        await show.assertPreparedBreakDropped()
    }

    /// Three system clears while a break is on air. Same coalesce: two advances, speech stopped.
    func testThreeMusicKitClearsWhileABreakIsAiringAdvanceTwice() async {
        let show = await Show.airingBreak()
        await show.musicKitSkipsWhileLoading(first: .clear, extra: 2)
        await show.assertBreakNotAiring(advancedTo: 2)
        XCTAssertEqual(show.advances, 2)
        XCTAssertEqual(show.dj?.speechLevel, 0)
        XCTAssertFalse(show.speechOverlapped)
        XCTAssertEqual(show.surfaces, 0)
        XCTAssertFalse(show.pausedByNoProgress)
    }

    /// Both ways a lock-screen Next can arrive for the same presses: the command target and
    /// MusicKit clearing the one-song queue. Two of each, while the first load is in flight,
    /// still advance twice and keep playing.
    func testTwoNextTrackCommandsAndTwoMusicKitClearsWhileLoadingAdvanceTwice() async {
        let show = Show()
        show.suspendAt = .prepare
        show.primePlaying()
        XCTAssertEqual(RemoteNextCommand.decide(queueIndex: 0, queueCount: show.songs), .skip)
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        await show.skip()
        show.feed(show.cleared())
        XCTAssertEqual(RemoteNextCommand.decide(queueIndex: show.index, queueCount: show.songs), .skip)
        await show.skip()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 2)
        XCTAssertEqual(show.advances, 2)
        XCTAssertEqual(show.reloads, 0)
        XCTAssertEqual(show.surfaces, 0)
        XCTAssertFalse(show.pausedByNoProgress)
        XCTAssertFalse(show.coordinator.isInFlight)
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
    /// #444 (-Atlas): false models the 1 s poll not having run between a skip installing its
    /// song and the next observation. The detector then never sees the new entry before a clear.
    var pollSeesLoadedEntry = true
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

    /// How MusicKit's own lock-screen Next shows up in the poll: the one-song queue is cleared,
    /// or the entry is kept and rewound to 0:00.
    enum MusicKitSkipShape {
        case clear
        case rewind
    }

    /// `extra` further MusicKit observations arrive while the first skip is suspended in
    /// `prepareToPlay`. The first observation is a mid-song remote skip, the same intake as
    /// `nextTrackCommand` → `skip()`.
    func musicKitSkipsWhileLoading(first shape: MusicKitSkipShape, extra: Int) async {
        suspendAt = .prepare
        primePlaying()
        markHistory()
        XCTAssertEqual(RemoteNextCommand.decide(queueIndex: index, queueCount: songs), .skip)
        feed(observation(shape))
        await untilLoadSuspended()
        for _ in 0..<extra {
            feed(observation(shape))
        }
        finishLoad()
        await untilIdle()
        await untilDropsSettle()
    }

    func assertPreparedBreakDropped() async {
        let dropped = await preparer?.testResult(afterTrack: 0)
        XCTAssertEqual(dropped, .skipped(.notNaturalBoundary))
        let aired = await session?.naturalBoundary(afterTrack: 0)
        XCTAssertNil(aired, "the prepared break was dropped with the skip and is not played")
    }

    private func observation(_ shape: MusicKitSkipShape) -> PlaybackObservation {
        switch shape {
        case .clear: cleared()
        case .rewind: rewound()
        }
    }

    /// Same intake as `MusicKitService.skip()`.
    func skip() async {
        installGate()
        boundaries.noteUserSkip()
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
        // `startTrack` after `playIfStillAllowed` started the song.
        boundaries.noteOwnPlayReturned()
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
        guard pollSeesLoadedEntry else { return }
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

// MARK: - #444 (-Fry): a second Next that rewinds the skip's song before any poll saw it play

/// MusicKit's other lock-screen Next shape is to keep the one-song queue and rewind it to 0:00,
/// paused. When that second Next lands after our own `play()` for B returned but before any 1 s
/// poll saw B playing, the detector has only seen B at 0:00 (or not at all), so the rewind is
/// neither `rewoundMidSong` (needs a sample past 2 s) nor the seen-playing skip-load cut (needs a
/// playing sample). Before this fix the poll reported nothing: the chain had ended on `.playing`,
/// MusicKit sat paused at 0:00 on B, and Play started B again. The owner's build 43 symptom.
extension LockScreenDoubleSkipTests {
    /// The poll never saw B before the rewind (Next #1 was a clear of A).
    func testSecondNextRewindingTheSkipsSongBeforeAnyPollSawItAdvancesToTheNextSong() async {
        let show = Show()
        show.pollSeesLoadedEntry = false
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        show.markHistory()
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        show.assertOwnerOutcome(index: 2)
        XCTAssertEqual(show.loadCuts, 1, "the rewind of B is reported once, as a cut of B")
        XCTAssertEqual(show.lastCutShape, .rewind)
        XCTAssertEqual(show.lastCutAwaitingPlay, false, "seen after B's play() returned")
        XCTAssertEqual(show.advances, 2)
        XCTAssertEqual(show.noProgressEnds, 0)
        XCTAssertEqual(show.surfaces, 0)
    }

    /// The poll saw B only at 0:00 while it loaded (before our `play()`), never playing. Both Nexts
    /// use the rewind shape, the way a kept one-song queue reports them.
    func testSecondNextRewindingASkipSongOnlySeenAtTheStartAdvancesToTheNextSong() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.rewound())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        show.markHistory()
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        show.assertOwnerOutcome(index: 2)
        XCTAssertEqual(show.loadCuts, 1)
        XCTAssertEqual(show.lastCutShape, .rewind)
        XCTAssertEqual(show.reloads, 0)
    }

    /// Next #1 was the app's own (in-app Skip or the command target), Next #2 a lock-screen rewind.
    func testRewindOfAnUnplayedSkipSongAfterAnInAppNextAdvancesToTheNextSong() async {
        let show = Show()
        show.pollSeesLoadedEntry = false
        show.primePlaying()
        let running = Task { await show.skip() }
        await show.untilLoadSuspended()
        show.finishLoad()
        await running.value
        await show.untilIdle()
        show.assertPlaying(index: 1)
        show.markHistory()
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        show.assertOwnerOutcome(index: 2)
        XCTAssertNil(show.unexpectedBoundary, "A's entry going away is not a natural end")
        XCTAssertEqual(show.noProgressEnds, 0)
    }

    /// Three Nexts, each rewinding the song the previous one loaded before a poll saw it play.
    /// #585 review (Atlas): rewind-derived cuts are capped at one until a song is seen playing, so
    /// the third press (C stalled at 0:00, never seen playing) is not taken: it ends on C. A stall
    /// and a rewind look the same there, and walking down the queue is the worse failure.
    /// `testAfterCPlaysTheNextRewindIsTakenAgain` covers the press once C has played.
    func testThreeNextsThatEachRewindAnUnplayedSkipSongAreCappedAtOneRewindCut() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        show.assertPlaying(index: 2)
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        show.assertPlaying(index: 2)
        XCTAssertEqual(show.loadCuts, 1, "one rewind-derived cut")
        XCTAssertEqual(show.advances, 2)
        XCTAssertEqual(show.reloads, 0)
        XCTAssertEqual(show.surfaces, 0)
    }

    /// DJ variant: B's break is prepared, then the second Next rewinds B before a poll saw it play.
    /// B's break is dropped (`songCut(afterTrack: 1)`) and never airs. Ends on C.
    func testSecondNextRewindingAnUnplayedSkipSongDropsItsPreparedBreak() async {
        let show = await Show.preparedBreak(commentary: .chatty)
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        await show.startSongAndPrepareItsBreak()
        XCTAssertTrue(show.breakIsReady(afterTrack: 1), "B's break is ready before the second Next")
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        await show.untilDropsSettle()
        await show.assertBreakNotAiring(advancedTo: 2)
        XCTAssertEqual(show.reloads, 0)
        XCTAssertTrue(show.cutBreaks.contains(1), "songCut(afterTrack: 1) ran for the skipped song")
        let aired = await show.session?.naturalBoundary(afterTrack: 1)
        XCTAssertNil(aired, "B's prepared break was dropped with the skip and is not played")
    }

    /// One Next: a single stopped-at-0:00 sample right after our `play()` returned (MusicKit's
    /// status not updated yet), then B plays. That is not a Next: B keeps playing, nothing reloads.
    func testOneStoppedSampleRightAfterOurPlayReturnedIsNotASecondNext() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.feed(show.rewound())
        show.feed(show.sample(playing: true, position: 1))
        show.feed(show.sample(playing: true, position: 2))
        show.feed(show.sample(playing: true, position: 3))
        await show.untilIdle()
        show.assertPlaying(index: 1)
        XCTAssertEqual(show.loadCuts, 0)
        XCTAssertEqual(show.advances, 1)
        XCTAssertEqual(show.reloads, 0)
    }

    /// A Pause after B started, then B sits at 0:00: the hold wins. No cut, no Next, nothing plays.
    func testUserPauseBeforeTheRewindedSkipSongIsSeenIsNotANext() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.pause()
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        XCTAssertEqual(show.index, 1)
        XCTAssertEqual(show.loadCuts, 0)
        XCTAssertEqual(show.advances, 1)
        XCTAssertFalse(show.audible)
    }

    /// Detector controls for the rewind of a skip's song that was never seen playing.
    func testUnplayedRewindIsACutOnlyAfterOurPlayReturnedForASkipLoadWithNoHold() {
        func primed() -> (BoundaryInterpreter, TimeInterval) {
            var b = BoundaryInterpreter()
            var t: TimeInterval = 100
            for position in stride(from: 0.0, through: 30.0, by: 1.0) {
                _ = b.interpret(PlaybackObservation(entryID: "song-0", isPlaying: true, position: position,
                                                    duration: 200, uptime: t), queueIndex: 0, queueCount: 4)
                t += 1
            }
            return (b, t)
        }
        func atStart(_ b: inout BoundaryInterpreter, _ t: TimeInterval, playing: Bool = false,
                     position: TimeInterval? = 0) -> BoundaryStep? {
            b.interpret(PlaybackObservation(entryID: "song-1", isPlaying: playing, position: position,
                                            duration: 200, uptime: t), queueIndex: 1, queueCount: 4)
        }
        func skipLoaded(_ b: inout BoundaryInterpreter) {
            b.setSkipLoadInFlight(true)
            b.userRequestedChange()
            b.noteOwnPlayReturned()
        }
        // The fix: two stopped samples at 0:00 of the skip's song after our play() returned.
        do {
            var (b, t) = primed()
            skipLoaded(&b)
            XCTAssertNil(atStart(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut(), "one sample may be MusicKit's status lagging our play()")
            t += PlaybackBoundaryDetector.rewoundBeforePlayingStallSeconds
            XCTAssertNil(atStart(&b, t))
            XCTAssertEqual(b.pendingSkipLoadCut, SkipLoadCut(shape: .rewind, targetSeenPlaying: false))
            XCTAssertTrue(b.takeSkipLoadCut())
            XCTAssertFalse(b.takeRemoteSkip())
            XCTAssertFalse(b.takeNoProgressEnd())
            t += 1
            XCTAssertNil(atStart(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut(), "reported once")
        }
        // The poll saw the entry at 0:00 before our play() (the load); the rule is the same after it.
        do {
            var (b, t) = primed()
            b.setSkipLoadInFlight(true)
            b.userRequestedChange()
            XCTAssertNil(atStart(&b, t))
            t += 1
            XCTAssertFalse(b.takeSkipLoadCut())
            b.noteOwnPlayReturned()
            XCTAssertNil(atStart(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut())
            t += PlaybackBoundaryDetector.rewoundBeforePlayingStallSeconds
            XCTAssertNil(atStart(&b, t))
            XCTAssertTrue(b.takeSkipLoadCut())
        }
        // Our play() has not returned: a song sitting at 0:00 is still loading. Nothing is reported.
        do {
            var (b, t) = primed()
            b.setSkipLoadInFlight(true)
            b.userRequestedChange()
            for _ in 0..<3 {
                XCTAssertNil(atStart(&b, t))
                t += 1
            }
            XCTAssertFalse(b.takeSkipLoadCut())
        }
        // Not a skip load (a natural next song or a tap): nothing is reported.
        do {
            var (b, t) = primed()
            b.userRequestedChange()
            b.noteOwnPlayReturned()
            for _ in 0..<3 {
                XCTAssertNil(atStart(&b, t))
                t += 1
            }
            XCTAssertFalse(b.takeSkipLoadCut())
        }
        // A playing sample in between: B started, so a later stop at 0:00 is not this cut.
        do {
            var (b, t) = primed()
            skipLoaded(&b)
            XCTAssertNil(atStart(&b, t))
            t += 1
            XCTAssertNil(atStart(&b, t, playing: true, position: 0.2))
            t += 1
            XCTAssertNil(atStart(&b, t, position: 0.2))
            XCTAssertEqual(b.pendingSkipLoadCut, SkipLoadCut(shape: .rewind, targetSeenPlaying: true),
                           "the existing seen-playing cut decides, not this one")
        }
        // No position: never a cut.
        do {
            var (b, t) = primed()
            skipLoaded(&b)
            XCTAssertNil(atStart(&b, t, position: nil))
            t += 1
            XCTAssertNil(atStart(&b, t, position: nil))
            XCTAssertFalse(b.takeSkipLoadCut())
        }
        // Two samples closer together than a poll (0.1 s): not yet confirmed; a later one is.
        do {
            var (b, t) = primed()
            skipLoaded(&b)
            XCTAssertNil(atStart(&b, t))
            XCTAssertNil(atStart(&b, t + 0.1))
            XCTAssertFalse(b.takeSkipLoadCut())
            XCTAssertNil(atStart(&b, t + PlaybackBoundaryDetector.rewoundBeforePlayingStallSeconds))
            XCTAssertTrue(b.takeSkipLoadCut())
        }
        // A user pause or route loss after our play() returned: the hold wins, no cut.
        for cause in [PlaybackBoundaryDetector.HoldCause.userPause, .routeLoss] {
            var (b, t) = primed()
            skipLoaded(&b)
            b.pausedByApp(cause)
            XCTAssertNil(atStart(&b, t))
            t += 1
            XCTAssertNil(atStart(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut(), "\(cause)")
        }
        // An interruption after our play() returned: no cut.
        do {
            var (b, t) = primed()
            skipLoaded(&b)
            b.pausedByApp(.systemInterruption)
            XCTAssertNil(atStart(&b, t))
            t += 1
            XCTAssertNil(atStart(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut())
        }
        // The skip-load flag cleared by the caller (pause, Play, a failed load): no cut.
        do {
            var (b, t) = primed()
            skipLoaded(&b)
            b.setSkipLoadInFlight(false)
            XCTAssertNil(atStart(&b, t))
            t += 1
            XCTAssertNil(atStart(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut())
        }
        // A newer app change (another skip or a new queue) before the second sample: no cut.
        do {
            var (b, t) = primed()
            skipLoaded(&b)
            XCTAssertNil(atStart(&b, t))
            t += 1
            b.userRequestedChange()
            XCTAssertNil(atStart(&b, t))
            XCTAssertFalse(b.takeSkipLoadCut())
        }
    }
}

// MARK: - #585 review (Echo, Atlas): a slow start is not a rewind

/// After our `play()` returns, MusicKit can keep reporting B paused at 0:00 for a few polls while
/// the catalog item buffers (cellular, AirPlay, the #526 lag). That is one Next and a slow start,
/// not a second Next: no cut, no reload, no skip, and B's prepared break stays.
extension LockScreenDoubleSkipTests {
    /// One Next, then B stalled at 0:00 on `stalled` polls 1 s apart, then B plays.
    private func assertSlowStartIsNotANext(stalled: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let show = Show()
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1, file: file, line: line)
        show.markHistory()
        for _ in 0..<stalled {
            show.feed(show.rewound())
            await show.untilIdle()
        }
        for position in 1...3 {
            show.feed(show.sample(playing: true, position: TimeInterval(position)))
            await show.untilIdle()
        }
        show.assertPlaying(index: 1, file: file, line: line)
        XCTAssertEqual(show.loadCuts, 0, "\(stalled) stalled polls: no cut", file: file, line: line)
        XCTAssertEqual(show.advances, 1, "\(stalled) stalled polls: one Next is one advance", file: file, line: line)
        XCTAssertEqual(show.reloads, 0, "\(stalled) stalled polls: no reload", file: file, line: line)
        XCTAssertEqual(show.surfaces, 0, file: file, line: line)
        XCTAssertFalse(show.everPaused, file: file, line: line)
        XCTAssertFalse(show.nowPlayingHistory.contains("t2"), "C never plays", file: file, line: line)
    }

    func testSlowStartWithTwoStalledPollsAfterOurPlayReturnedIsNotANext() async {
        await assertSlowStartIsNotANext(stalled: 2)
    }

    /// Atlas's control (a): a single Next, 3 stalled samples at 0:00, then B plays. Index 1, no cut.
    func testSlowStartWithThreeStalledPollsAfterOurPlayReturnedIsNotANext() async {
        await assertSlowStartIsNotANext(stalled: 3)
    }

    /// The window boundary: B stalled at 0:00 from the first poll after our `play()` until just
    /// under the start-confirm deadline (#109, 8 s), then it plays. Still a slow start.
    func testSlowStartJustUnderTheStartConfirmDeadlineIsNotANext() async {
        let polls = Int(PlaybackBoundaryDetector.rewoundBeforePlayingStallSeconds)  // 8 polls span 7 s
        await assertSlowStartIsNotANext(stalled: polls)
    }

    /// DJ variant: B's break is prepared, B is slow to start (3 stalled polls), then plays. The
    /// break is kept: no `songCut(afterTrack: 1)`, still ready after track 1.
    func testSlowStartKeepsTheSkipSongsPreparedBreak() async {
        let show = await Show.preparedBreak(commentary: .chatty)
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        await show.startSongAndPrepareItsBreak()
        XCTAssertTrue(show.breakIsReady(afterTrack: 1))
        for _ in 0..<3 {
            show.feed(show.rewound())
            await show.untilIdle()
        }
        for position in 1...3 {
            show.feed(show.sample(playing: true, position: TimeInterval(position)))
            await show.untilIdle()
        }
        await show.untilDropsSettle()
        show.assertPlaying(index: 1)
        XCTAssertEqual(show.loadCuts, 0)
        XCTAssertEqual(show.reloads, 0)
        XCTAssertFalse(show.cutBreaks.contains(1), "B's break is not cut")
        XCTAssertTrue(show.breakIsReady(afterTrack: 1), "B's prepared break is kept")
    }

    /// Atlas's control (b): every song stays paused at 0:00 after its `play()`. At most the one
    /// advance a real second press would give, then the start watchdog's path: never a walk down
    /// the queue.
    func testEverySongStallingAtTheStartNeverChainsDownTheQueue() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        for _ in 0..<40 {
            show.feed(show.rewound())
            await show.untilIdle()
        }
        XCTAssertLessThanOrEqual(show.index, 2, "at most one rewind-derived advance")
        XCTAssertLessThanOrEqual(show.advances, 2)
        XCTAssertLessThanOrEqual(show.loadCuts, 1)
        XCTAssertEqual(show.reloads, 0)
    }
}

// MARK: - #585 review: the cap resets once a song plays, and a long stall has one outcome

extension LockScreenDoubleSkipTests {
    /// After the capped rewind cut lands on C, C is seen playing. That resets the cap: the next
    /// Next (a rewind of C after it played) is taken, and so is a later stall-past-window of D.
    func testAfterCPlaysTheNextRewindIsTakenAgain() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        show.assertPlaying(index: 2)
        show.feed(show.sample(playing: true, position: 0.5))
        show.feed(show.rewound())
        await show.untilIdle()
        show.assertPlaying(index: 3)
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        show.assertPlaying(index: 4)
        XCTAssertEqual(show.loadCuts, 3)
        XCTAssertEqual(show.advances, 4)
        XCTAssertEqual(show.reloads, 0)
        XCTAssertEqual(show.surfaces, 0)
    }

    /// Atlas: the rewind window and #109's deadline come from one named constant and cannot drift.
    func testRewindWindowIsTheStartConfirmDeadline() {
        XCTAssertEqual(PlaybackConfirmPolicy.deadlineSeconds,
                       Double(PlaybackConfirmPolicy.maxPolls) * PlaybackConfirmPolicy.pollInterval)
        XCTAssertEqual(PlaybackBoundaryDetector.rewoundBeforePlayingStallSeconds, PlaybackConfirmPolicy.deadlineSeconds)
        XCTAssertEqual(PlaybackConfirmPolicy.deadlineSeconds, 8, accuracy: 0.001)
    }

    /// Atlas: a user skip resets the one-rewind-cut cap. After a capped cut (nothing seen playing),
    /// the user presses Next through the app's handler; a later rewind-type stall past the window on
    /// that new song cuts again, exactly once.
    func testAUserSkipResetsTheRewindCutCap() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        show.assertPlaying(index: 2)
        XCTAssertEqual(show.loadCuts, 1, "cap engaged after one rewind cut")
        await show.skip()
        await show.untilIdle()
        show.assertPlaying(index: 3)
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        show.assertPlaying(index: 4)
        XCTAssertEqual(show.loadCuts, 2, "the user skip reset the cap: one more rewind cut")
        show.feedRewoundStallPastTheStartDeadline()
        await show.untilIdle()
        show.assertPlaying(index: 4)
        XCTAssertEqual(show.loadCuts, 2, "and the cap holds again after it")
        XCTAssertEqual(show.reloads, 0)
        XCTAssertEqual(show.surfaces, 0)
    }

    /// Echo: a stall that crosses the 8 s window has exactly one outcome. The skip path never arms
    /// #109's start confirm (only a queue start and the resumes do; a skip's new attempt supersedes
    /// any running one), so the capped rewind cut is the only thing that fires: one cut, one extra
    /// advance, one `songCut` for B, no failed start, no surfaced error, no reload, and nothing more
    /// however long the stall lasts afterwards on C.
    func testAStallCrossingTheWindowHasExactlyOneOutcome() async {
        let show = await Show.preparedBreak(commentary: .chatty)
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 1)
        let window = PlaybackBoundaryDetector.rewoundBeforePlayingStallSeconds
        // Polls 1 s apart from 0 s: nothing at 7 s (just under), the cut on the poll at 8 s.
        for _ in 0..<Int(window) {
            show.feed(show.rewound())
            await show.untilIdle()
        }
        XCTAssertEqual(show.loadCuts, 0, "just under the window: still a slow start")
        XCTAssertEqual(show.index, 1)
        show.feed(show.rewound())
        await show.untilIdle()
        await show.untilDropsSettle()
        XCTAssertEqual(show.loadCuts, 1, "crossing the window: one cut")
        XCTAssertEqual(show.index, 2)
        // The stall goes on (now on C): no second outcome.
        for _ in 0..<20 {
            show.feed(show.rewound())
            await show.untilIdle()
        }
        await show.untilDropsSettle()
        XCTAssertEqual(show.loadCuts, 1)
        XCTAssertEqual(show.advances, 2, "one advance for the press, one for the cut")
        XCTAssertEqual(show.cutBreaks.filter { $0 == 1 }.count, 1, "one songCut for B")
        XCTAssertEqual(show.noProgressEnds, 0, "no failed start")
        XCTAssertFalse(show.pausedByNoProgress)
        XCTAssertEqual(show.surfaces, 0, "no surfaced error")
        XCTAssertEqual(show.reloads, 0)
        XCTAssertEqual(show.index, 2)
    }

    /// The exclusivity above rests on the app: the skip load does not arm #109's confirm watchdog.
    func testTheSkipLoadDoesNotArmTheStartConfirmWatchdog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("AeroDJ/MusicKitService.swift"), encoding: .utf8)
        let skipPath = source.split(separator: "private func oneSkip(").dropFirst().first
            .flatMap { $0.split(separator: "private func stopSkipForPlay(").first }.map(String.init) ?? ""
        let startTrack = source.split(separator: "func startTrack(at index: Int").dropFirst().first
            .flatMap { $0.split(separator: "func startNextTrack(").first }.map(String.init) ?? ""
        XCTAssertFalse(skipPath.isEmpty)
        XCTAssertFalse(startTrack.isEmpty)
        XCTAssertFalse(skipPath.contains("armPlaybackConfirmTimeout"))
        XCTAssertFalse(startTrack.contains("armPlaybackConfirmTimeout"))
    }

    /// Detector level: a stall far past the window reports one rewind cut and nothing else.
    func testDetectorReportsOneRewindCutForAStallFarPastTheWindow() {
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
        var cuts = 0
        for _ in 0..<30 {
            XCTAssertNil(b.interpret(PlaybackObservation(entryID: "song-1", isPlaying: false, position: 0,
                                                         duration: 200, uptime: t), queueIndex: 1, queueCount: 4))
            if b.takeSkipLoadCut() { cuts += 1 }
            XCTAssertFalse(b.takeNoProgressEnd())
            XCTAssertFalse(b.takeRemoteSkip())
            t += 1
        }
        XCTAssertEqual(cuts, 1)
    }
}

/// #585 review: MusicKit's rewind of the skip's song, held at 0:00 past the start-confirm deadline
/// (polls 1 s apart), so it is told apart from a slow start.
private extension Show {
    func feedRewoundStallPastTheStartDeadline() {
        let polls = Int(PlaybackBoundaryDetector.rewoundBeforePlayingStallSeconds) + 1
        for _ in 0..<polls { feed(rewound()) }
    }
}
