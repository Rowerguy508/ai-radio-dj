import XCTest
@testable import AeroDJCore

/// #444 follow-up (-Echo): the skip chain MusicKitService runs, with a test double for the player.
///
/// `SkipCoordinator` decides. This driver calls it the way `MusicKitService.skip`, `pause`,
/// `noteSkipLoadCut`, and `applySessionUngated` do: an explicit Next may `userPlay()`, a reload
/// and a recovery must not, and a load cut is not a second Next. The Show harness in
/// `LockScreenDoubleSkipTests` always finishes a load as playing; these tests cover the outcomes
/// it cannot.
@MainActor
final class SkipChainOrchestrationTests: XCTestCase {
    func testPauseAfterAQueuedNextDoesNotAdvanceOrRestorePlayback() async {
        let player = Driver()
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        await player.skip()
        player.pause()
        player.finishLoad()
        await running.value
        XCTAssertEqual(player.plays, [.advance], "the queued Next is cancelled with the pause")
        XCTAssertEqual(player.index, 1)
        XCTAssertFalse(player.policy.userWantsPlayback)
        XCTAssertEqual(player.userPlayCount, 1, "the follow-up must not call userPlay()")
        XCTAssertEqual(player.engine.snapshot.transport, .paused)
        XCTAssertEqual(player.engine.snapshot.nowPlaying?.id, "t1")
    }

    func testRouteLossBlocksTheReloadAndDoesNotClearTheHold() async {
        let player = Driver()
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        player.routeRemoved()
        player.finishLoad()
        await running.value
        XCTAssertEqual(player.plays, [.advance])
        XCTAssertTrue(player.policy.pausedBySystem)
        XCTAssertEqual(player.userPlayCount, 1, "a reload must not call userPlay() over a route hold")
        XCTAssertEqual(player.index, 1)
    }

    func testInterruptionThatShouldNotResumeKeepsTheHold() async {
        let player = Driver()
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        player.interruptionBegan()
        await player.interruptionEnded(shouldResume: false)
        player.finishLoad()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance])
        XCTAssertEqual(player.resumes, 0)
        XCTAssertTrue(player.policy.pausedBySystem)
        XCTAssertEqual(player.userPlayCount, 1)
    }

    func testInterruptionEndThatShouldResumeIsNotDroppedWhileTheChainIsInFlight() async {
        let player = Driver()
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        player.interruptionBegan()
        await player.interruptionEnded(shouldResume: true)
        XCTAssertEqual(player.resumes, 0, "the resume waits until the in-flight chain exits")
        player.finishLoad()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.resumes, 1, "a permitted interruption end still resumes")
        XCTAssertFalse(player.policy.pausedBySystem)
        XCTAssertTrue(player.policy.mayAutoResume)
        XCTAssertEqual(player.plays, [.advance], "the chain does not keep skipping after the hold")
    }

    func testStationReplacementBeforeRecoveryDoesNotReloadTheOldTarget() async {
        let player = Driver()
        await player.skip()
        XCTAssertEqual(player.index, 1)
        player.holdNextLoad()
        player.noteCut()
        await player.untilWaiting()
        let playsBefore = player.plays.count
        player.replaceStation()
        player.finishLoad()
        await player.untilIdle()
        XCTAssertEqual(player.index, 0)
        XCTAssertEqual(player.engine.snapshot.nowPlaying?.id, "t0")
        XCTAssertEqual(player.station, "new")
        XCTAssertEqual(player.plays.count, playsBefore, "the scheduled recovery does not load")
        XCTAssertEqual(player.userPlayCount, 2, "only the original Next and the new station's play")
    }

    func testUnavailableSongStaysOnTheSelectedTargetAndSurfacesTheError() async {
        let player = Driver()
        player.script = [.failed(.songUnavailable, target: -1)]
        await player.skip()
        XCTAssertEqual(player.plays, [.advance], "an unavailable song is not reloaded onto another index")
        XCTAssertEqual(player.index, 1)
        XCTAssertEqual(player.engine.snapshot.nowPlaying?.id, "t1")
        XCTAssertEqual(player.engine.snapshot.transport, .paused)
        XCTAssertEqual(player.surfaces, [.songUnavailable])
        XCTAssertEqual(player.engine.snapshot.error?.message, PlaybackFailureCopy.message(for: .songUnavailable))
        XCTAssertEqual(player.engine.snapshot.error?.isRecoverable, true)
    }

    func testRepeatedPlayThrowsStayOnTheTargetAndSurfaceTheError() async {
        let player = Driver()
        player.script = [
            .failed(.couldNotStart, target: -1),
            .failed(.couldNotStart, target: -1),
            .failed(.couldNotStart, target: -1)
        ]
        await player.skip()
        XCTAssertEqual(player.plays, [.advance, .reload], "one same-target retry, then stop")
        XCTAssertEqual(player.index, 1, "the retry does not jump to another song")
        XCTAssertEqual(player.engine.snapshot.nowPlaying?.id, "t1")
        XCTAssertEqual(player.userPlayCount, 1, "the retry does not call userPlay()")
        XCTAssertEqual(player.surfaces, [.couldNotStart])
        XCTAssertEqual(player.engine.snapshot.transport, .paused)
        XCTAssertEqual(player.engine.snapshot.error?.message, PlaybackFailureCopy.message(for: .couldNotStart))
        XCTAssertEqual(player.engine.snapshot.error?.isRecoverable, true)
    }

    func testOneNextPlusATransientClearRecoversTheSelectedTrack() async {
        let player = Driver()
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        player.noteCut()
        player.finishLoad()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance, .reload])
        XCTAssertEqual(player.index, 1, "the clear is not a second Next")
        XCTAssertEqual(player.engine.snapshot.transport, .playing)
        XCTAssertTrue(player.surfaces.isEmpty)
    }

    func testExplicitNextAndItsMusicKitObservationAdvanceOnce() async {
        let player = Driver()
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        await player.skip()
        player.noteCut()
        player.finishLoad()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance, .advance], "the observation is not a third Next")
        XCTAssertEqual(player.index, 2)
        XCTAssertEqual(player.engine.snapshot.transport, .playing)
        XCTAssertEqual(player.engine.snapshot.nowPlaying?.id, "t2")
    }

    func testRepeatedClearsAfterEachReturnAreBoundedUntilProgress() async {
        let player = Driver()
        await player.skip()
        XCTAssertEqual(player.index, 1)
        player.noteCut()
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance, .reload])
        for _ in 0..<7 { player.noteCut() }
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance, .reload], "later clears do not start another recovery")
        XCTAssertEqual(player.surfaces, [.couldNotStart])
        XCTAssertEqual(player.index, 1)
        XCTAssertEqual(player.engine.snapshot.error?.isRecoverable, true)

        player.coordinator.noteProgress()
        player.skipLoadOpen = true
        player.policy.userPlay()
        player.surfaces.removeAll()
        player.noteCut()
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance, .reload, .reload], "real progress gives this target one more recovery")
        XCTAssertEqual(player.index, 1)
    }

    /// `surfaceSkipFailure` with no current attempt still drops the skip-load flag, so a later
    /// resume is not stuck behind it.
    func testTerminalFailureWithNoAttemptClearsTheSkipLoadFlag() async {
        let player = Driver()
        player.skipLoadOpen = true
        player.surface(.couldNotStart)
        XCTAssertNil(player.attempts.current)
        XCTAssertFalse(player.skipLoadOpen)
        await player.resumeIfAllowed()
        XCTAssertEqual(player.resumes, 0, "the failure paused on purpose; it does not auto-resume")
        player.play()
        XCTAssertEqual(player.engine.snapshot.transport, .playing)
    }

    /// The exhausted load-cut path calls `surfaceSkipFailure` outside a chain. The flag ends false.
    func testExhaustedLoadCutClearsTheSkipLoadFlag() async {
        let player = Driver()
        await player.skip()
        player.skipLoadOpen = true
        player.noteCut()
        await player.untilIdle()
        player.noteCut()
        XCTAssertFalse(player.skipLoadOpen)
        XCTAssertEqual(player.plays, [.advance, .reload])
        player.play()
        XCTAssertEqual(player.engine.snapshot.transport, .playing)
        XCTAssertEqual(player.index, 0)
    }

    func testPauseThenFreshNextPlaysTheNextSong() async {
        let player = Driver()
        await player.skip()
        player.pause()
        await player.skip()
        XCTAssertEqual(player.index, 2)
        XCTAssertTrue(player.isAudible)
        XCTAssertEqual(player.audibleID, "t2")
        XCTAssertTrue(player.policy.userWantsPlayback)
        XCTAssertEqual(player.plays, [.advance, .advance])
    }

    func testPauseThenRemoteNextPlaysTheNextSong() async {
        let player = Driver()
        await player.skip()
        player.pause()
        await player.remoteNext()
        XCTAssertEqual(player.index, 2)
        XCTAssertTrue(player.isAudible)
        XCTAssertEqual(player.audibleID, "t2")
        XCTAssertTrue(player.policy.userWantsPlayback)
    }

    func testFreshNextAfterPauseDuringTheLoadPlaysAndTheOldQueueStaysCancelled() async {
        let player = Driver()
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        await player.skip()
        player.pause()
        await player.skip()
        player.finishLoad()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance, .advance], "the Next from before the pause is dropped; the fresh one runs")
        XCTAssertTrue(player.isAudible)
        XCTAssertTrue(player.policy.userWantsPlayback)
        XCTAssertFalse(player.policy.pausedBySystem)
    }

    func testFreshNextAfterRouteLossAndInterruptionPlays() async {
        for hold: (Driver) -> Void in [{ $0.routeRemoved() }, { $0.interruptionBegan() }] {
            let player = Driver()
            player.holdNextLoad()
            let running = Task { await player.skip() }
            await player.untilWaiting()
            await player.skip()
            hold(player)
            XCTAssertTrue(player.policy.pausedBySystem)
            await player.skip()
            player.finishLoad()
            await running.value
            await player.untilIdle()
            XCTAssertEqual(player.plays, [.advance, .advance])
            XCTAssertTrue(player.isAudible)
            XCTAssertFalse(player.policy.pausedBySystem, "the fresh Next calls userPlay() and clears the hold")
        }
    }

    /// Pause, then Next, then another hold, all while the old load is open. The Next is cancelled.
    func testLaterHoldCancelsThePendingFreshNext() async {
        let laterHolds: [(String, (Driver) -> Void)] = [
            ("pause", { $0.pause() }),
            ("interruption", { $0.interruptionBegan() }),
            ("route", { $0.routeRemoved() })
        ]
        for (name, hold) in laterHolds {
            let player = Driver()
            player.holdNextLoad()
            let running = Task { await player.skip() }
            await player.untilWaiting()
            let indexAtPress = player.index
            player.pause()
            await player.skip()
            let userPlaysAtPress = player.userPlayCount
            hold(player)
            player.finishLoad()
            await running.value
            await player.untilIdle()
            XCTAssertEqual(player.plays, [.advance], name)
            XCTAssertEqual(player.userPlayCount, userPlaysAtPress, "\(name): the pending Next must not call userPlay()")
            XCTAssertEqual(player.index, indexAtPress, name)
            XCTAssertFalse(player.isAudible, "\(name): nothing plays when the old load returns")
            XCTAssertNil(player.audibleID, name)
            if name == "pause" {
                XCTAssertFalse(player.policy.userWantsPlayback, name)
            } else {
                XCTAssertTrue(player.policy.pausedBySystem, "\(name): the hold stays, so nothing plays over it")
            }
        }

        let player = Driver()
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        player.pause()
        await player.skip()
        player.finishLoad()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance, .advance], "with no later hold, the Next plays")
        XCTAssertEqual(player.index, 2)
        XCTAssertTrue(player.isAudible)
        XCTAssertEqual(player.audibleID, "t2")
        XCTAssertTrue(player.policy.userWantsPlayback)
        XCTAssertEqual(player.userPlayCount, 2)
    }

    func testNextDuringRecoveryReloadRunsAfterTheReload() async {
        let player = Driver()
        await player.skip()
        player.plays.removeAll()
        player.holdNextLoad()
        player.noteCut()
        await player.untilWaiting()
        let intake = player.coordinator.requestAdvance()
        XCTAssertEqual(intake, .queueOneMore)
        player.finishLoad()
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.reload, .advance])
        XCTAssertEqual(player.index, 2)
        XCTAssertTrue(player.isAudible)
    }

    func testNextQueuedBeforeAThrowRunsAfterTheReload() async {
        let player = Driver()
        player.script = [.failed(.couldNotStart, target: -1), .playing]
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        await player.skip()
        player.finishLoad()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance, .reload, .advance],
                       "the throw is retried once, then the stored Next advances")
        XCTAssertEqual(player.index, 2)
        XCTAssertTrue(player.surfaces.isEmpty)
    }

    func testStoredNextAfterFailureOrReloadStaysCancelledWhenAHoldLands() async {
        let holds: [(String, (Driver) -> Void)] = [
            ("pause", { $0.pause() }),
            ("route", { $0.routeRemoved() }),
            ("interruption", { $0.interruptionBegan() })
        ]
        for (name, hold) in holds {
            let failed = Driver()
            failed.script = [.failed(.songUnavailable, target: -1)]
            failed.holdNextLoad()
            let failing = Task { await failed.skip() }
            await failed.untilWaiting()
            await failed.skip()
            hold(failed)
            failed.finishLoad()
            await failing.value
            await failed.untilIdle()
            XCTAssertEqual(failed.plays, [.advance], name)
            XCTAssertEqual(failed.index, 1, "\(name): the stored Next after .failed stays cancelled")

            let reloading = Driver()
            await reloading.skip()
            reloading.plays.removeAll()
            reloading.holdNextLoad()
            reloading.noteCut()
            await reloading.untilWaiting()
            XCTAssertEqual(reloading.coordinator.requestAdvance(), .queueOneMore, name)
            hold(reloading)
            reloading.finishLoad()
            await reloading.untilIdle()
            XCTAssertEqual(reloading.plays, [.reload], name)
            XCTAssertEqual(reloading.index, 1, "\(name): the stored Next after .reload stays cancelled")
        }
    }

    func testRepeatedFailuresAndStoredNextsStayWithinOneRecovery() async {
        let player = Driver()
        player.script = [
            .failed(.couldNotStart, target: 1),
            .failed(.couldNotStart, target: 1),
            .failed(.couldNotStart, target: 1),
            .failed(.couldNotStart, target: 1)
        ]
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        await player.skip()
        player.finishLoad()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.reloads(of: 1), 1, "the stored Next must not reset this song's recovery")
        XCTAssertEqual(player.surfaces, [.couldNotStart])

        player.index = 1
        player.skipLoadOpen = true
        player.policy.userPlay()
        player.noteCut()
        await player.untilIdle()
        XCTAssertEqual(player.reloads(of: 1), 1, "the same target stays spent until real progress")

        player.coordinator.noteProgress()
        player.skipLoadOpen = true
        player.policy.userPlay()
        player.noteCut()
        await player.untilIdle()
        XCTAssertEqual(player.reloads(of: 1), 2, "real progress allows one more recovery of this target")
    }

    func testUnavailableSongDoesNotLeaveTheOldSongAudibleOrReportItAsTheNewOne() async {
        let player = Driver()
        player.primeAudibleA()
        player.script = [.failed(.songUnavailable, target: -1)]
        await player.skip()
        XCTAssertEqual(player.index, 1)
        XCTAssertEqual(player.engine.snapshot.nowPlaying?.id, "t1")
        XCTAssertFalse(player.isAudible)
        XCTAssertNil(player.audibleID)
        XCTAssertEqual(player.playerEntryID, "t0", "the player queue was still A")
        player.poll()
        XCTAssertFalse(player.isAudible, "the poll must not keep A sounding under B")
        XCTAssertEqual(player.index, 1)
        XCTAssertEqual(player.engine.snapshot.nowPlaying?.id, "t1")
        XCTAssertEqual(player.engine.snapshot.transport, .paused)
        await player.resumeIfAllowed()
        XCTAssertEqual(player.resumes, 0)
        XCTAssertFalse(player.isAudible)
        player.userResume()
        XCTAssertFalse(player.isAudible, "resume must not play A as if it were B")
    }

    /// Without `LoadedTargetPolicy`, explicit Play calls `play()` on the entry still in the player (A)
    /// while `queueIndex` is B. The shared decision fails closed instead.
    func testExplicitPlayAfterUnavailableSkipDoesNotPlayTheLoadedSong() async {
        let player = Driver()
        player.primeAudibleA()
        player.script = [.failed(.songUnavailable, target: -1)]
        await player.skip()
        XCTAssertEqual(player.playerEntryID, "t0")
        XCTAssertEqual(player.index, 1)
        player.userResume()
        XCTAssertEqual(player.lastResumeDecision, .failClosed)
        XCTAssertFalse(player.isAudible)
        XCTAssertNil(player.audibleID)
        XCTAssertEqual(player.playerEntryID, "t0", "Play did not start the song still loaded")
        XCTAssertEqual(player.engine.snapshot.nowPlaying?.id, "t1")
        XCTAssertEqual(player.engine.snapshot.error?.isRecoverable, true)
        XCTAssertEqual(player.surfaces.last, .songUnavailable)
    }

    /// Remote Play and `resumeIfAllowed` use the same decision. A hold that has been cleared must
    /// still not start A.
    func testRemoteAndAutomaticResumeAfterUnavailableSkipDoNotPlayTheLoadedSong() async {
        let remote = Driver()
        remote.primeAudibleA()
        remote.script = [.failed(.songUnavailable, target: -1)]
        await remote.skip()
        await remote.remoteResume()
        XCTAssertEqual(remote.lastResumeDecision, .failClosed)
        XCTAssertFalse(remote.isAudible)
        XCTAssertNil(remote.audibleID)
        XCTAssertEqual(remote.playerEntryID, "t0")
        XCTAssertEqual(remote.engine.snapshot.error?.isRecoverable, true)

        let automatic = Driver()
        automatic.primeAudibleA()
        automatic.script = [.failed(.songUnavailable, target: -1)]
        await automatic.skip()
        automatic.policy.userPlay()
        await automatic.resumeIfAllowed()
        XCTAssertEqual(automatic.lastResumeDecision, .failClosed)
        XCTAssertFalse(automatic.isAudible)
        XCTAssertNil(automatic.audibleID)
        XCTAssertEqual(automatic.playerEntryID, "t0")
        XCTAssertEqual(automatic.resumes, 0)
        XCTAssertEqual(automatic.engine.snapshot.error?.isRecoverable, true)
    }

    /// The skip could not start B, so A is still loaded. A later Play reloads B and reports B.
    func testRetryAfterAFailedSkipLoadsAndPlaysTheSelectedSong() async {
        let player = Driver()
        player.primeAudibleA()
        player.script = [
            .failed(.couldNotStart, target: -1),
            .failed(.couldNotStart, target: -1)
        ]
        await player.skip()
        XCTAssertEqual(player.index, 1)
        XCTAssertEqual(player.playerEntryID, "t0")
        XCTAssertFalse(player.isAudible)
        player.userResume()
        XCTAssertEqual(player.lastResumeDecision, .reloadSelected)
        XCTAssertTrue(player.isAudible)
        XCTAssertEqual(player.audibleID, "t1")
        XCTAssertEqual(player.playerEntryID, "t1")
        XCTAssertEqual(player.index, 1)
        XCTAssertEqual(player.engine.snapshot.nowPlaying?.id, "t1")
        XCTAssertEqual(player.engine.snapshot.transport, .playing)
    }

    /// Play at 18s, then the old skip's prepare throws. Same queue generation, new attempt.
    /// Removing `isCurrent` from `ownsLoad` lets the throw recover and reset the playhead.
    func testPrepareThrowAfterSameGenerationPlayDoesNotRecover() async {
        await throwAfterSameGenerationPlay(queuedNext: false)
    }

    /// The old skip's play() throws after that Play. Same rule as a prepare throw.
    func testPlayThrowAfterSameGenerationPlayDoesNotRecover() async {
        await throwAfterSameGenerationPlay(queuedNext: false)
    }

    /// A Next stored on the old skip does not run after the newer Play.
    func testQueuedNextAfterSameGenerationPlayDoesNotRunWhenTheSkipThrows() async {
        await throwAfterSameGenerationPlay(queuedNext: true)
    }

    private func throwAfterSameGenerationPlay(queuedNext: Bool) async {
        let player = Driver()
        player.holdNextLoad()
        player.script = [.failed(.couldNotStart, target: -1)]
        let running = Task { await player.skip() }
        await player.untilWaiting()
        if queuedNext { await player.skip() }
        player.playAt(18)
        let starts = player.songStarts
        let queues = player.queueAssignments
        player.finishLoad()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance])
        XCTAssertEqual(player.reloads(of: 1), 0)
        XCTAssertEqual(player.index, 1)
        XCTAssertEqual(player.position, 18)
        XCTAssertEqual(player.songStarts, starts)
        XCTAssertEqual(player.queueAssignments, queues)
        XCTAssertTrue(player.surfaces.isEmpty)
        XCTAssertTrue(player.policy.userWantsPlayback)
        XCTAssertFalse(player.policy.pausedBySystem)
        XCTAssertEqual(player.engine.snapshot.transport, .playing)
    }

    /// Explicit Play clears the skip-load flag while the old load is still held open.
    func testResumeClearsTheSkipLoadFlagWhileTheSkipIsStillLoading() async {
        let player = Driver()
        player.holdNextLoad()
        player.skipLoadOpen = true
        let running = Task { await player.skip() }
        await player.untilWaiting()
        player.landPlaying(at: 18)
        player.userResume()
        XCTAssertFalse(player.skipLoadOpen)
        XCTAssertEqual(player.position, 18)
        let queues = player.queueAssignments
        let starts = player.songStarts
        player.finishLoad()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance])
        XCTAssertEqual(player.queueAssignments, queues)
        XCTAssertEqual(player.songStarts, starts)
        XCTAssertEqual(player.position, 18)
        XCTAssertTrue(player.surfaces.isEmpty)
    }

    /// #453: the old chain is ending and awaits its owed interruption resume (`isInFlight` is
    /// already false). A Next pressed there is stored to run after that resume. A newer explicit
    /// Play of B at 18 s must cancel it: no later advance, same song, same playhead.
    func testPlayDuringTheOwedResumeCancelsTheNextStoredThere() async {
        let player = Driver()
        let running = await player.skipIntoSuspendedOwedResume()
        let stored = await player.nextIntake()
        XCTAssertEqual(stored, .beginWhenIdle, "a Next during the owed resume is stored")
        player.landPlaying(at: 18)
        player.userResume()
        let queues = player.queueAssignments
        let starts = player.songStarts
        player.releaseOwedResume()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.owedResumes, 1, "the legitimate owed resume still runs")
        XCTAssertEqual(player.plays, [.advance], "the Next stored before Play does not advance after it")
        XCTAssertEqual(player.index, 1)
        XCTAssertEqual(player.position, 18)
        XCTAssertEqual(player.queueAssignments, queues, "no reload")
        XCTAssertEqual(player.songStarts, starts)
        XCTAssertEqual(player.engine.snapshot.nowPlaying?.id, "t1")
        XCTAssertTrue(player.surfaces.isEmpty)
    }

    /// Remote Play is the same `resume()` and cancels the same stored Next.
    func testRemotePlayDuringTheOwedResumeCancelsTheNextStoredThere() async {
        let player = Driver()
        let running = await player.skipIntoSuspendedOwedResume()
        _ = await player.nextIntake()
        player.landPlaying(at: 18)
        await player.remoteResume()
        player.releaseOwedResume()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.plays, [.advance])
        XCTAssertEqual(player.index, 1)
        XCTAssertEqual(player.position, 18)
    }

    /// Control: a Next pressed after the newer Play is the user's latest intent. It runs once.
    func testNextAfterPlayDuringTheOwedResumeStillRunsOnce() async {
        let player = Driver()
        let running = await player.skipIntoSuspendedOwedResume()
        _ = await player.nextIntake()
        player.landPlaying(at: 18)
        player.userResume()
        let later = await player.nextIntake()
        let repeated = await player.nextIntake()
        XCTAssertEqual(later, .beginWhenIdle)
        XCTAssertEqual(repeated, .beginWhenIdle, "a repeat is the same one pending Next")
        player.releaseOwedResume()
        await running.value
        await player.untilIdle()
        XCTAssertEqual(player.owedResumes, 1)
        XCTAssertEqual(player.plays, [.advance, .advance], "exactly one advance after the Play")
        XCTAssertEqual(player.index, 2)
    }

    /// Control: Pause, route loss, or an interruption after that later Next still cancels it.
    func testHoldAfterTheLaterNextCancelsIt() async {
        for hold in ["pause", "route", "interruption"] {
            let player = Driver()
            let running = await player.skipIntoSuspendedOwedResume()
            _ = await player.nextIntake()
            player.landPlaying(at: 18)
            player.userResume()
            _ = await player.nextIntake()
            switch hold {
            case "pause": player.pause()
            case "route": player.routeRemoved()
            default: player.interruptionBegan()
            }
            let userPlays = player.userPlayCount
            player.releaseOwedResume()
            await running.value
            await player.untilIdle()
            XCTAssertEqual(player.plays, [.advance], "\(hold) cancels the pending Next")
            XCTAssertEqual(player.index, 1, hold)
            XCTAssertEqual(player.userPlayCount, userPlays, "\(hold): no userPlay() over the hold")
        }
    }

    func testMusicKitServicePlayCancelsSkipWorkThroughTheOwedResume() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("AeroDJ/MusicKitService.swift"), encoding: .utf8)
        let stop = source.split(separator: "private func stopSkipForPlay").dropFirst().first
            .map(String.init)?
            .split(separator: "\n    }\n").first
            .map(String.init) ?? ""
        XCTAssertTrue(stop.contains("guard skipCoordinator.hasPendingSkipWork else { return }"),
                      "Play cancels a chain that is ending as well as one in flight (#453)")
        XCTAssertFalse(stop.contains("guard skipCoordinator.isInFlight"))
    }

    func testAdmitCancelsAThrowWhenOnlyTheAttemptChanged() {
        var attempts = PlaybackAttempts()
        let skip = attempts.beginStart()
        let generation = attempts.queueGeneration
        _ = attempts.beginStart()
        XCTAssertEqual(attempts.queueGeneration, generation)
        let admitted = SkipStepOutcome.admit(
            .failed(.couldNotStart, target: 1), attempt: skip, generation: generation, attempts: attempts)
        XCTAssertEqual(admitted, .cancelled)
    }

    func testAdmitCancelsAThrowWhenOnlyTheQueueGenerationChanged() {
        var attempts = PlaybackAttempts()
        let skip = attempts.beginStart()
        let generation = attempts.queueGeneration
        _ = attempts.userChangedQueue()
        XCTAssertTrue(attempts.isCurrent(skip))
        let admitted = SkipStepOutcome.admit(
            .failed(.couldNotStart, target: 1), attempt: skip, generation: generation, attempts: attempts)
        XCTAssertEqual(admitted, .cancelled)
    }

    func testMusicKitServiceAdmitsAThrowBeforeTheCoordinatorSeesIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("AeroDJ/MusicKitService.swift"), encoding: .utf8)
        let oneSkip = source.split(separator: "private func oneSkip").dropFirst().first
            .map(String.init)?
            .split(separator: "private func loadSkippedSong").first
            .map(String.init) ?? ""
        XCTAssertEqual(
            oneSkip.components(separatedBy: "ownsLoad(attempt: attempt, generation: generation) else { return .cancelled }").count,
            3,
            "advance and reload both cancel a step they no longer own")
        XCTAssertTrue(source.contains("return SkipStepOutcome.admit("),
                      "a thrown prepare or play is admitted before the coordinator")
        let stop = source.split(separator: "private func stopSkipForPlay").dropFirst().first.map(String.init) ?? ""
        XCTAssertTrue(stop.contains("invalidate(.userPlay)"))
        XCTAssertTrue(stop.contains("setSkipLoadInFlight(false)"),
                      "Play clears the skip-load flag while the old load is still in flight")
    }

    /// The old advance is still awaited when the queue is replaced with C. Its `.cancelled`
    /// continuation must not clear C. Without that ownership check, resume reloads and assigns
    /// the queue again.
    func testSupersededAdvanceKeepsTheReplacementLoadedTarget() async {
        let player = Driver()
        player.holdNextLoad()
        let running = Task { await player.skip() }
        await player.untilWaiting()
        player.loadSongC(at: 18)
        let queues = player.queueAssignments
        let starts = player.songStarts
        player.finishLoad()
        await running.value
        await player.untilIdle()
        player.pauseAt(18)
        player.userResume()
        XCTAssertEqual(player.lastResumeDecision, .playLoaded)
        XCTAssertEqual(player.queueAssignments, queues)
        XCTAssertEqual(player.songStarts, starts)
        XCTAssertEqual(player.position, 18)
        XCTAssertEqual(player.playerEntryID, "t2")
        XCTAssertEqual(player.audibleID, "t2")
        XCTAssertTrue(player.isAudible)
        XCTAssertEqual(player.index, 2)
    }

    /// Same ownership rule when the in-flight step is a recovery reload rather than an advance.
    func testSupersededRecoveryKeepsTheReplacementLoadedTarget() async {
        let player = Driver()
        await player.skip()
        player.holdNextLoad()
        player.noteCut()
        await player.untilWaiting()
        player.loadSongC(at: 22)
        let queues = player.queueAssignments
        let starts = player.songStarts
        player.finishLoad()
        await runningWait(player)
        player.pauseAt(22)
        player.userResume()
        XCTAssertEqual(player.lastResumeDecision, .playLoaded)
        XCTAssertEqual(player.queueAssignments, queues)
        XCTAssertEqual(player.songStarts, starts)
        XCTAssertEqual(player.position, 22)
        XCTAssertEqual(player.playerEntryID, "t2")
        XCTAssertEqual(player.audibleID, "t2")
        XCTAssertTrue(player.isAudible)
        XCTAssertEqual(player.index, 2)
    }

    private func runningWait(_ player: Driver) async {
        await player.untilIdle()
    }
}

// MARK: - Driver

/// The MusicKitService skip/pause/session/load-cut calls, with a scripted player.
@MainActor
private final class Driver {
    let coordinator = SkipCoordinator()
    var policy = AudioSessionPolicy()
    var engine = PlaybackEngine()
    var attempts = PlaybackAttempts()
    var index = 0
    var station = "old"
    var plays: [SkipJob] = []
    var userPlayCount = 0
    var resumes = 0
    var surfaces: [SkipTerminalFailure] = []
    var script: [SkipLoadResult] = []
    var skipLoadOpen = true
    var isAudible = true
    var audibleID: String? = "t0"
    var playerEntryID: String? = "t0"
    var loadedTarget: LoadedPlayerTarget? = LoadedPlayerTarget(index: 0, generation: 0)
    var lastResumeDecision: ResumeTargetDecision?
    var queueAssignments = 0
    var songStarts = 0
    var position: TimeInterval = 0
    private var unavailable: Set<Int> = []
    var boundaries = BoundaryInterpreter()
    private var clock: TimeInterval = 100
    private var reloadCounts: [Int: Int] = [:]
    private let gate = OrchestrationGate()
    /// #453: holds the owed interruption resume a chain awaits as it ends. Open unless a test closes it.
    private let owedResumeGate = OrchestrationGate()
    /// Owed resumes the chain ran after the gate opened.
    private(set) var owedResumes = 0
    private let songs = 6

    init() {
        startEngine(station: "old")
        policy.userPlay()
        coordinator.stepGate = { [weak self] in
            guard let self else { return (false, true) }
            return (self.policy.userWantsPlayback, self.policy.pausedBySystem)
        }
    }

    func skip() async {
        switch coordinator.requestAdvance() {
        case .begin:
            await run(first: .advance)
        case .queueOneMore, .ignore, .beginWhenIdle:
            return
        }
    }

    /// One explicit Next, returning the coordinator's intake. Starts a chain only on `.begin`.
    func nextIntake() async -> SkipCoordinator.Intake {
        let intake = coordinator.requestAdvance()
        if intake == .begin { await run(first: .advance) }
        return intake
    }

    /// #453 setup: Skip selects B and its load is held. An interruption begins and ends with
    /// permission to resume while the Skip is in flight. The load is released, and the chain
    /// ends awaiting its owed resume, which is held. Returns the old chain's task.
    func skipIntoSuspendedOwedResume() async -> Task<Void, Never> {
        holdNextLoad()
        holdOwedResume()
        let running = Task { await self.skip() }
        await untilWaiting()
        interruptionBegan()
        await interruptionEnded(shouldResume: true)
        XCTAssertTrue(coordinator.resumeOwed)
        finishLoad()
        await untilOwedResumeWaiting()
        XCTAssertFalse(coordinator.isInFlight, "the chain is in its ending window")
        XCTAssertTrue(coordinator.hasPendingSkipWork)
        XCTAssertEqual(index, 1)
        return running
    }

    /// Lock-screen Next: the same `skip()` `nextTrackCommand` targets.
    func remoteNext() async { await skip() }

    /// Lock-screen Play: the same `resume()` the remote play command targets.
    func remoteResume() async { userResume() }

    func reloads(of index: Int) -> Int { reloadCounts[index] ?? 0 }

    func primeAudibleA() {
        for position in [0.0, 10.0, 20.0] {
            _ = boundaries.interpret(PlaybackObservation(entryID: "t0", isPlaying: true, position: position,
                                                         duration: 200, uptime: clock),
                                     queueIndex: 0, queueCount: songs)
            clock += 1
        }
    }

    func poll() {
        if isAudible, !policy.mayAutoResume {
            isAudible = false
            audibleID = nil
        }
        _ = boundaries.interpret(PlaybackObservation(entryID: playerEntryID, isPlaying: isAudible,
                                                     position: isAudible ? 30 : 0, duration: 200, uptime: clock),
                                 queueIndex: index, queueCount: songs)
        clock += 1
    }

    /// Explicit Play. The same `LoadedTargetPolicy` decision as `MusicKitService.resume`.
    /// A skip that is still loading is invalidated and its flag drops before this Play starts.
    func userResume() {
        policy.userPlay()
        if coordinator.hasPendingSkipWork {
            coordinator.invalidate(.userPlay)
            skipLoadOpen = false
        }
        _ = attempts.beginStart()
        performResume()
    }

    /// The song already in the player is the selected one, at `seconds`. Not a new attempt.
    func landPlaying(at seconds: TimeInterval) {
        position = seconds
        playerEntryID = "t\(index)"
        audibleID = playerEntryID
        isAudible = true
        noteLoadedTarget()
        if engine.snapshot.transport != .playing {
            engine.apply(.userResumed)
            engine.apply(.playbackConfirmed)
        }
    }

    /// A newer Play in the same queue generation: new attempt, playhead at `seconds`, no invalidation.
    /// The old skip's throw still has to come back as `.cancelled` on its own.
    func playAt(_ seconds: TimeInterval) {
        policy.userPlay()
        _ = attempts.beginStart()
        position = seconds
        isAudible = true
        audibleID = playerEntryID ?? "t\(index)"
        playerEntryID = audibleID
        noteLoadedTarget()
        songStarts += 1
        if engine.snapshot.transport != .playing {
            engine.apply(.userResumed)
            engine.apply(.playbackConfirmed)
        }
    }

    /// Same gate as `MusicKitService.noteSkipLoadCut`: no recovery over a pause or a system hold.
    func noteCut() {
        noteLoadedTargetStale()
        guard policy.userWantsPlayback, !policy.pausedBySystem, skipLoadOpen else { return }
        switch coordinator.noteLoadCut(target: index) {
        case .folded:
            return
        case .recover:
            Task { await self.run(first: .reload) }
        case .exhausted:
            // The flag clear has to happen inside `surface`, as in `surfaceSkipFailure`.
            surface(.couldNotStart)
        }
    }

    func pause() {
        coordinator.invalidate(.userPause)
        skipLoadOpen = false
        isAudible = false
        audibleID = nil
        _ = policy.userPause()
        engine.apply(.userPaused)
    }

    /// Pause leaves the playhead where it is. A resume of this song must not look like a new load.
    func pauseAt(_ seconds: TimeInterval) {
        position = seconds
        pause()
    }

    /// The replacement queue's song C, loaded and playing at `seconds`.
    func loadSongC(at seconds: TimeInterval) {
        coordinator.invalidate(.queueReplaced)
        skipLoadOpen = false
        _ = attempts.userChangedQueue()
        _ = attempts.beginStart()
        index = 2
        playerEntryID = "t2"
        audibleID = "t2"
        isAudible = true
        position = seconds
        noteLoadedTarget()
        queueAssignments += 1
        songStarts += 1
        engine.apply(.userSkipped(nextIndex: index))
        engine.apply(.playbackConfirmed)
    }

    func routeRemoved() {
        _ = policy.handle(.routeChanged(.oldDeviceUnavailable), breakIsActive: false)
        coordinator.invalidate(.routeRemoved)
        skipLoadOpen = false
    }

    func interruptionBegan() {
        _ = policy.handle(.interruptionBegan, breakIsActive: false)
        coordinator.invalidate(.interruptionBegan)
        skipLoadOpen = false
    }

    func interruptionEnded(shouldResume: Bool) async {
        let directive = policy.handle(.interruptionEnded(shouldResume: shouldResume), breakIsActive: false)
        coordinator.noteInterruptionEnded(shouldResume: shouldResume, mayAutoResume: policy.mayAutoResume)
        if directive == .resumeIfPermitted, !coordinator.isInFlight {
            await resumeIfAllowed()
        }
    }

    /// Same shape as `MusicKitService.play`: a new queue clears the skip-load flag and starts.
    func play() {
        coordinator.invalidate(.queueReplaced)
        skipLoadOpen = false
        _ = attempts.userChangedQueue()
        index = 0
        policy.userPlay()
        userPlayCount += 1
        startEngine(station: station)
        playerEntryID = "t0"
        noteLoadedTarget()
    }

    func replaceStation() {
        coordinator.invalidate(.queueReplaced)
        skipLoadOpen = false
        _ = attempts.userChangedQueue()
        index = 0
        station = "new"
        policy.userPlay()
        userPlayCount += 1
        startEngine(station: "new")
        playerEntryID = "t0"
        noteLoadedTarget()
    }

    func finishLoad() { gate.release() }
    func holdNextLoad() { gate.close() }
    func releaseOne() { gate.releaseOne() }

    func untilWaiting() async {
        for _ in 0..<1000 where !gate.isWaiting { await Task.yield() }
        XCTAssertTrue(gate.isWaiting)
    }

    func holdOwedResume() { owedResumeGate.close() }
    func releaseOwedResume() { owedResumeGate.release() }

    /// Waits on a clock deadline, not a poll count, until the ending chain awaits its owed resume.
    func untilOwedResumeWaiting() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !owedResumeGate.isWaiting, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(owedResumeGate.isWaiting)
    }

    /// The `resume` the chain calls when it ends with an owed interruption resume.
    private func owedResume() async {
        await owedResumeGate.wait()
        owedResumes += 1
        await resumeIfAllowed()
    }

    func untilIdle() async {
        for _ in 0..<1000 where coordinator.isInFlight || gate.isWaiting { await Task.yield() }
        XCTAssertFalse(coordinator.isInFlight)
    }

    private func startEngine(station: String) {
        let tracks = (0..<songs).map { TrackInfo(id: "t\($0)", title: "Song \($0)", artistName: "Artist") }
        engine = PlaybackEngine()
        engine.apply(.queueStarted(tracks: tracks, startIndex: index, station: StationRef(id: station, name: station)))
        engine.apply(.playbackConfirmed)
    }

    private func run(first: SkipJob) async {
        let body: @MainActor (SkipJob) async -> SkipLoadResult = { job in await self.execute(job) }
        if first == .reload {
            await coordinator.runRecovery(
                surface: { self.surface($0) },
                resume: { await self.owedResume() },
                body)
        } else {
            await coordinator.runChain(
                surface: { self.surface($0) },
                resume: { await self.owedResume() },
                body)
        }
    }

    private func execute(_ job: SkipJob) async -> SkipLoadResult {
        guard coordinator.admits(job) else { return .cancelled }
        let attempt: PlaybackAttemptID
        let generation: Int
        if job == .advance {
            policy.userPlay()
            userPlayCount += 1
            _ = attempts.userChangedQueue()
            attempt = attempts.beginStart()
            generation = attempts.queueGeneration
            let next = index + 1
            guard next < songs else { return .queueStopped }
            index = next
            engine.apply(.userSkipped(nextIndex: index))
        } else {
            attempt = attempts.beginStart()
            generation = attempts.queueGeneration
            reloadCounts[index, default: 0] += 1
        }
        plays.append(job)
        await gate.wait()
        let result: SkipLoadResult
        if !coordinator.allowsStep() || !policy.userWantsPlayback || policy.pausedBySystem {
            result = .cancelled
        } else if script.isEmpty {
            isAudible = true
            audibleID = "t\(index)"
            playerEntryID = audibleID
            result = .playing
        } else {
            let scripted = script.removeFirst()
            if case let .failed(failure, target) = scripted {
                let failedAt = target >= 0 ? target : index
                if failure == .songUnavailable, attempts.ownsLoad(attempt: attempt, generation: generation) {
                    unavailable.insert(failedAt)
                }
                result = .failed(failure, target: failedAt)
            } else if case .playing = scripted {
                isAudible = true
                audibleID = "t\(index)"
                playerEntryID = audibleID
                result = .playing
            } else {
                result = scripted
            }
        }
        // Same rule as `loadSkippedSong`: a throw the load no longer owns is `.cancelled`.
        let admitted = SkipStepOutcome.admit(result, attempt: attempt, generation: generation, attempts: attempts)
        guard attempts.ownsLoad(attempt: attempt, generation: generation) else { return admitted }
        switch admitted {
        case .playing:
            noteLoadedTarget()
        case .cancelled, .failed, .queueStopped, .loadCut:
            noteLoadedTargetStale()
        }
        return admitted
    }

    /// Same exits as `MusicKitService.surfaceSkipFailure`: no current attempt and a stale
    /// effect return before the banner, and the skip-load flag is cleared on every path.
    func surface(_ failure: SkipTerminalFailure) {
        defer { skipLoadOpen = false }
        noteLoadedTargetStale()
        isAudible = false
        audibleID = nil
        boundaries.pausedByApp(.userPause)
        if policy.userWantsPlayback { _ = policy.userPause() }
        engine.apply(.userPaused)
        guard let attempt = attempts.current else { return }
        let effect = SkipFailureSurface.effect(failure, attempt: attempt, current: attempts.current)
        guard effect != .none else { return }
        surfaces.append(failure)
        for event in effect.events { engine.apply(event) }
    }

    func resumeIfAllowed() async {
        guard policy.mayAutoResume, !skipLoadOpen else { return }
        if coordinator.isInFlight { return }
        performResume()
    }

    /// `MusicKitService.playResume`: one `LoadedTargetPolicy` decision, then play, reload, or fail closed.
    private func performResume() {
        let decision = LoadedTargetPolicy.decide(
            loaded: loadedTarget,
            selectedIndex: index,
            generation: attempts.queueGeneration,
            selectedIsPlayable: !unavailable.contains(index)
        )
        lastResumeDecision = decision
        switch decision {
        case .playLoaded:
            isAudible = true
            audibleID = playerEntryID
            resumes += 1
            if engine.snapshot.transport != .playing {
                engine.apply(.userResumed)
                engine.apply(.playbackConfirmed)
            }
        case .reloadSelected:
            queueAssignments += 1
            songStarts += 1
            position = 0
            playerEntryID = "t\(index)"
            audibleID = playerEntryID
            isAudible = true
            noteLoadedTarget()
            resumes += 1
            engine.apply(.userSkipped(nextIndex: index))
            engine.apply(.userResumed)
            engine.apply(.playbackConfirmed)
        case .failClosed:
            isAudible = false
            audibleID = nil
            let failure: SkipTerminalFailure = unavailable.contains(index) ? .songUnavailable : .couldNotStart
            let attempt = attempts.beginStart()
            let effect = SkipFailureSurface.effect(failure, attempt: attempt, current: attempts.current)
            surfaces.append(failure)
            engine.apply(.userPaused)
            for event in effect.events { engine.apply(event) }
        }
    }

    private func noteLoadedTarget() {
        loadedTarget = LoadedPlayerTarget(index: index, generation: attempts.queueGeneration)
    }

    private func noteLoadedTargetStale() {
        loadedTarget = nil
    }
}

@MainActor
private final class OrchestrationGate {
    private var open = true
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

    func close() { open = false }
}
