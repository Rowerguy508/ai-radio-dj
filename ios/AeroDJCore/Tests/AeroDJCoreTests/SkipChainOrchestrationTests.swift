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
        XCTAssertEqual(player.resumes, 1)
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
        case .queueOneMore, .ignore:
            return
        case .begin:
            await run(first: .advance)
        }
    }

    /// Same gate as `MusicKitService.noteSkipLoadCut`: no recovery over a pause or a system hold.
    func noteCut() {
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
        index = 0
        policy.userPlay()
        userPlayCount += 1
        startEngine(station: station)
    }

    func replaceStation() {
        coordinator.invalidate(.queueReplaced)
        skipLoadOpen = false
        index = 0
        station = "new"
        policy.userPlay()
        userPlayCount += 1
        startEngine(station: "new")
    }

    func finishLoad() { gate.release() }
    func holdNextLoad() { gate.close() }

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
        guard coordinator.allowsStep() else { return .cancelled }
        if job == .advance {
            policy.userPlay()
            userPlayCount += 1
            _ = attempts.beginStart()
            let next = index + 1
            guard next < songs else { return .queueStopped }
            index = next
            engine.apply(.userSkipped(nextIndex: index))
        }
        plays.append(job)
        await gate.wait()
        guard coordinator.allowsStep() else { return .cancelled }
        guard policy.userWantsPlayback, !policy.pausedBySystem else { return .cancelled }
        guard !script.isEmpty else { return .playing }
        let scripted = script.removeFirst()
        if case let .failed(failure, _) = scripted {
            return .failed(failure, target: index)
        }
        return scripted
    }

    /// Same exits as `MusicKitService.surfaceSkipFailure`: no current attempt and a stale
    /// effect return before the banner, and the skip-load flag is cleared on every path.
    func surface(_ failure: SkipTerminalFailure) {
        defer { skipLoadOpen = false }
        guard let attempt = attempts.current else { return }
        let effect = SkipFailureSurface.effect(failure, attempt: attempt, current: attempts.current)
        guard effect != .none else { return }
        surfaces.append(failure)
        for event in effect.events { engine.apply(event) }
    }

    func resumeIfAllowed() async {
        guard policy.mayAutoResume, !skipLoadOpen else { return }
        resumes += 1
        if engine.snapshot.transport != .playing {
            engine.apply(.userResumed)
            engine.apply(.playbackConfirmed)
        }
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

    func close() { open = false }
}
