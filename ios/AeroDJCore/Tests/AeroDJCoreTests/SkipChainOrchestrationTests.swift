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
    private var unavailable: Set<Int> = []
    var boundaries = BoundaryInterpreter()
    private var clock: TimeInterval = 100
    private var reloadCounts: [Int: Int] = [:]
    private let gate = OrchestrationGate()
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
    func userResume() {
        policy.userPlay()
        performResume()
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
                resume: { await self.resumeIfAllowed() },
                body)
        } else {
            await coordinator.runChain(
                surface: { self.surface($0) },
                resume: { await self.resumeIfAllowed() },
                body)
        }
    }

    private func execute(_ job: SkipJob) async -> SkipLoadResult {
        guard coordinator.admits(job) else { return .cancelled }
        if job == .advance {
            policy.userPlay()
            userPlayCount += 1
            _ = attempts.userChangedQueue()
            _ = attempts.beginStart()
            let next = index + 1
            guard next < songs else { return .queueStopped }
            index = next
            engine.apply(.userSkipped(nextIndex: index))
        } else {
            reloadCounts[index, default: 0] += 1
        }
        plays.append(job)
        await gate.wait()
        guard coordinator.allowsStep() else { return .cancelled }
        guard policy.userWantsPlayback, !policy.pausedBySystem else { return .cancelled }
        guard !script.isEmpty else {
            isAudible = true
            audibleID = "t\(index)"
            playerEntryID = audibleID
            noteLoadedTarget()
            return .playing
        }
        let scripted = script.removeFirst()
        if case let .failed(failure, target) = scripted {
            let failedAt = target >= 0 ? target : index
            if failure == .songUnavailable { unavailable.insert(failedAt) }
            noteLoadedTargetStale()
            return .failed(failure, target: failedAt)
        }
        if case .playing = scripted {
            isAudible = true
            audibleID = "t\(index)"
            playerEntryID = audibleID
            noteLoadedTarget()
        }
        if case .loadCut = scripted { noteLoadedTargetStale() }
        if case .cancelled = scripted { noteLoadedTargetStale() }
        return scripted
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
