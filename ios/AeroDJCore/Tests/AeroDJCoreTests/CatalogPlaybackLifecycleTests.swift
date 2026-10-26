import XCTest
@testable import AeroDJCore

/// Stand-in for `ApplicationMusicPlayer`. Tests advance time on `ManualClock`; nothing sleeps.
private struct ScriptedCatalogPlayer {
    var entryID: String?
    var isPlaying = false
    var position: Duration = .zero
    var duration: Duration
    private(set) var loads: [String] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0

    mutating func load(_ id: String) {
        loads.append(id)
        entryID = id
        position = .zero
        isPlaying = false
    }

    mutating func play() {
        playCount += 1
        isPlaying = true
    }

    mutating func pause() {
        pauseCount += 1
        isPlaying = false
    }

    mutating func stop() {
        stopCount += 1
        isPlaying = false
        entryID = nil
    }

    mutating func advance(to position: Duration) {
        self.position = position
    }

    var observation: PlaybackObservation {
        PlaybackObservation(entryID: entryID, isPlaying: isPlaying)
    }
}

/// Song lifecycle through the same types `MusicKitService` calls. The double is not Apple Music.
final class CatalogPlaybackLifecycleTests: XCTestCase {
    func testSongStartRecordsDurationAndPositionFromTheClock() {
        var player = ScriptedCatalogPlayer(duration: .seconds(180))
        var progress = PlaybackProgress()
        var clock = ManualClock()
        var deferred = DeferredSongStart()
        var policy = AudioSessionPolicy()
        policy.userPlay()

        player.load("song-0")
        XCTAssertTrue(policy.mayAutoResume)
        player.play()
        deferred.clear()
        progress.songStarted(duration: player.duration)

        XCTAssertEqual(player.loads, ["song-0"])
        XCTAssertEqual(player.playCount, 1)
        XCTAssertEqual(progress.position, .zero)
        XCTAssertEqual(progress.duration, .seconds(180))
        XCTAssertEqual(progress.preparationDeadline, .seconds(177))

        clock.advance(by: .seconds(25))
        player.advance(to: clock.now)
        progress.seek(to: player.position)
        XCTAssertEqual(progress.position, .seconds(25))
        XCTAssertEqual(progress.remaining, .seconds(155))
        XCTAssertEqual(progress.preparationDeadline, .seconds(152))

        progress.seek(to: .seconds(10_000))
        XCTAssertEqual(progress.position, .seconds(180), "position does not run past the catalog duration")
        XCTAssertEqual(progress.remaining, .zero)
        XCTAssertNil(progress.preparationDeadline)
    }

    func testPreparationDeadlineExpiresBeforeTheBoundary() {
        var progress = PlaybackProgress()
        progress.songStarted(duration: .seconds(180))
        var clock = ManualClock()
        clock.advance(by: .seconds(177))
        progress.seek(to: clock.now)
        XCTAssertNil(progress.preparationDeadline, "inside the 3 s margin nothing is rendered")
        XCTAssertEqual(BreakHandoffPolicy.decide(prepared: nil), .continueMusic)

        progress.seek(to: .seconds(176))
        XCTAssertEqual(progress.preparationDeadline, .seconds(1))
        progress.seek(to: .seconds(177))
        XCTAssertNil(DJBreakPreparer.deadline(remainingInSong: .seconds(3)))
        XCTAssertNil(progress.preparationDeadline)
    }

    func testSongWithoutADurationDoesNotInventADeadline() {
        var progress = PlaybackProgress()
        progress.songStarted(duration: nil)
        progress.seek(to: .seconds(10))
        XCTAssertNil(progress.duration)
        XCTAssertNil(progress.preparationDeadline)
        XCTAssertEqual(BreakHandoffPolicy.decide(prepared: nil), .continueMusic)
    }

    func testNaturalTrackCompletionIsReportedOnce() {
        var player = ScriptedCatalogPlayer(duration: .seconds(30))
        var boundaries = BoundaryInterpreter()
        player.load("song-0")
        player.play()

        XCTAssertNil(boundaries.interpret(player.observation, queueIndex: 0, queueCount: 2))
        player.stop()
        let handoff = boundaries.interpret(player.observation, queueIndex: 0, queueCount: 2)
        XCTAssertEqual(
            handoff,
            .plannedHandoff(finishedIndex: 0, nextIndex: 1, boundary: .naturalEnd(finishedEntryID: "song-0"))
        )
        XCTAssertNil(
            boundaries.interpret(player.observation, queueIndex: 0, queueCount: 2),
            "the same ended sample is not a second boundary"
        )

        var last = BoundaryInterpreter()
        var end = ScriptedCatalogPlayer(duration: .seconds(30))
        end.load("song-1")
        end.play()
        XCTAssertNil(last.interpret(end.observation, queueIndex: 1, queueCount: 2))
        end.stop()
        XCTAssertEqual(
            last.interpret(end.observation, queueIndex: 1, queueCount: 2),
            .stopped(finishedIndex: 1, boundary: .queueFinished(lastEntryID: "song-1"))
        )
        XCTAssertNil(last.interpret(end.observation, queueIndex: 1, queueCount: 2))
    }

    func testEntryAdvanceIsOneNaturalEnd() {
        var boundaries = BoundaryInterpreter()
        XCTAssertNil(boundaries.interpret(PlaybackObservation(entryID: "a", isPlaying: true), queueIndex: 0, queueCount: 3))
        let step = boundaries.interpret(PlaybackObservation(entryID: "b", isPlaying: true), queueIndex: 0, queueCount: 3)
        XCTAssertEqual(step, .advancedEntry(finishedIndex: 0, boundary: .naturalEnd(finishedEntryID: "a")))
        XCTAssertNil(boundaries.interpret(PlaybackObservation(entryID: "b", isPlaying: true), queueIndex: 1, queueCount: 3))
    }

    func testDJTransitionIsExactlyOnce() async throws {
        let (preparer, djBreak) = try await readyBreak()
        let outcome = await preparer.takeBreak(afterTrack: djBreak.afterTrack)
        guard case let .ready(prepared) = outcome else {
            return XCTFail("expected a prepared break, got \(outcome)")
        }
        guard case let .play(handed) = BreakHandoffPolicy.decide(prepared: prepared) else {
            return XCTFail("the ready break should play once")
        }
        XCTAssertEqual(handed.afterTrack, djBreak.afterTrack)
        XCTAssertFalse(handed.clips.isEmpty)

        let again = await preparer.takeBreak(afterTrack: djBreak.afterTrack)
        XCTAssertEqual(again, .skipped(.notPlanned))
        XCTAssertEqual(BreakHandoffPolicy.decide(again), .continueMusic, "the same boundary does not play a second break")
    }

    func testFailedNarrationReturnsToMusicImmediately() async throws {
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1), seed: 1)
        let djBreak = try XCTUnwrap(writer.plan(tracks: djTracks(3), briefing: nil, hour: 9).breaks.first)
        let preparer = DJBreakPreparer(
            renderer: djRenderer(free: DJFakeVoice(fails: true), capMicrodollars: 0),
            userID: "u",
            stationID: "s"
        )
        let settled = expectation(description: "render failed")
        await preparer.observe { event in
            if case .skipped(let track, _) = event, track == djBreak.afterTrack { settled.fulfill() }
        }
        let started = ContinuousClock.now
        await preparer.prepare(djBreak, deadline: .seconds(30))
        await fulfillment(of: [settled], timeout: 2)
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .milliseconds(500), "a failed render returns without waiting out the deadline")

        let outcome = await preparer.takeBreak(afterTrack: djBreak.afterTrack)
        XCTAssertEqual(outcome, .skipped(.renderFailed))
        XCTAssertEqual(BreakHandoffPolicy.decide(outcome), .continueMusic)
        let replay = await preparer.takeBreak(afterTrack: djBreak.afterTrack)
        XCTAssertEqual(BreakHandoffPolicy.decide(replay), .continueMusic)

        var machine = AudioStateMachine(state: .transition)
        let decision = NarrationResumePolicy.decide(.failed, mayAutoResume: true, phase: machine.state)
        XCTAssertEqual(decision.audioEvent, .noInterlude)
        XCTAssertTrue(decision.resumeMusic)
        guard let backToMusic = decision.audioEvent else { return XCTFail("failure leaves the transition") }
        XCTAssertEqual(machine.apply(backToMusic), .music)

        var held = AudioSessionPolicy()
        held.userPlay()
        _ = held.handle(.interruptionBegan, breakIsActive: true)
        let suspended = NarrationResumePolicy.decide(.failed, mayAutoResume: held.mayAutoResume, phase: .voice)
        XCTAssertFalse(suspended.resumeMusic)
        guard let leaveVoice = suspended.audioEvent else { return XCTFail("failure leaves the voice phase") }
        var voice = AudioStateMachine(state: .voice)
        XCTAssertEqual(voice.apply(leaveVoice), .music)
    }

    func testQueueChangeAndCancellationDropTheBreak() async throws {
        var player = ScriptedCatalogPlayer(duration: .seconds(180))
        var boundaries = BoundaryInterpreter()
        player.load("song-0")
        player.play()
        _ = boundaries.interpret(player.observation, queueIndex: 0, queueCount: 2)

        let (preparer, djBreak) = try await readyBreak()
        await preparer.cancelAll()
        let outcome = await preparer.takeBreak(afterTrack: djBreak.afterTrack)
        XCTAssertEqual(BreakHandoffPolicy.decide(outcome), .continueMusic)

        boundaries.userRequestedChange()
        player.load("other-queue")
        player.play()
        XCTAssertNil(
            boundaries.interpret(player.observation, queueIndex: 0, queueCount: 1),
            "replacing the queue is not a natural end"
        )
        XCTAssertEqual(player.loads, ["song-0", "other-queue"])
    }

    func testCancellationBeforeTheBreakIsReadyDoesNotPlayIt() async throws {
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1), seed: 1)
        let djBreak = try XCTUnwrap(writer.plan(tracks: djTracks(3), briefing: nil, hour: 9).breaks.first)
        let preparer = DJBreakPreparer(
            renderer: djRenderer(free: DJFakeVoice(), capMicrodollars: 0),
            userID: "u",
            stationID: "s"
        )
        let log = DJEventLog()
        await preparer.observe { log.add($0) }
        await preparer.prepare(djBreak, deadline: .seconds(30))
        await preparer.cancelAll()
        XCTAssertTrue(log.all.contains {
            if case .skipped(let track, .cancelled) = $0 { track == djBreak.afterTrack } else { false }
        })
        let outcome = await preparer.takeBreak(afterTrack: djBreak.afterTrack)
        if case .ready = outcome { XCTFail("a cancelled break must not be handed to the player") }
        XCTAssertEqual(BreakHandoffPolicy.decide(outcome), .continueMusic)
    }

    func testDeferredSongStartIsReportedOnceWhenResumeIsPermitted() {
        var policy = AudioSessionPolicy()
        var deferred = DeferredSongStart()
        var player = ScriptedCatalogPlayer(duration: .seconds(200))
        var progress = PlaybackProgress()

        policy.userPlay()
        _ = policy.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertFalse(policy.mayAutoResume)
        player.load("song-1")
        deferred.arm(1)
        XCTAssertEqual(player.playCount, 0, "a song loaded during a call stays paused")

        XCTAssertEqual(policy.handle(.interruptionEnded(shouldResume: false), breakIsActive: false), .none)
        XCTAssertEqual(player.playCount, 0, "without permission the loaded song stays paused")
        XCTAssertEqual(deferred.index, 1)

        policy.userPlay()
        XCTAssertTrue(policy.mayAutoResume)
        player.play()
        let started = deferred.take()
        XCTAssertEqual(started, 1)
        progress.songStarted(duration: player.duration)
        XCTAssertNil(deferred.take(), "songStarted is delivered once")
        XCTAssertEqual(progress.duration, .seconds(200))
        XCTAssertEqual(player.playCount, 1)
    }

    func testPauseAndHeadphoneSamplesAreNotTrackEnds() {
        var boundaries = BoundaryInterpreter()
        let playing = PlaybackObservation(entryID: "a", isPlaying: true)
        XCTAssertNil(boundaries.interpret(playing, queueIndex: 0, queueCount: 2))
        XCTAssertNil(boundaries.interpret(PlaybackObservation(entryID: "a", isPlaying: false), queueIndex: 0, queueCount: 2))
        XCTAssertNil(boundaries.interpret(playing, queueIndex: 0, queueCount: 2))
    }

    private func readyBreak() async throws -> (DJBreakPreparer, DJBreak) {
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1), seed: 1)
        let djBreak = try XCTUnwrap(writer.plan(tracks: djTracks(3), briefing: nil, hour: 9).breaks.first)
        let preparer = DJBreakPreparer(
            renderer: djRenderer(free: DJFakeVoice(), capMicrodollars: 0),
            userID: "u",
            stationID: "s"
        )
        let ready = expectation(description: "prepared")
        await preparer.observe { event in
            if case .prepared(let track, _, _) = event, track == djBreak.afterTrack { ready.fulfill() }
        }
        await preparer.prepare(djBreak, deadline: .seconds(30))
        await fulfillment(of: [ready], timeout: 2)
        return (preparer, djBreak)
    }
}
