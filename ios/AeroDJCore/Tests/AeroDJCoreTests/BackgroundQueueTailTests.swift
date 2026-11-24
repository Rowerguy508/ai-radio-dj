import XCTest
@testable import AeroDJCore

/// #304 R1 (-Atlas): the player queue holds one song in the foreground and, in the background with
/// nothing armed for the boundary, the next station song too, so a suspended app still advances.
final class BackgroundQueueTailTests: XCTestCase {
    private func backgrounded() -> BackgroundQueueTail {
        var tail = BackgroundQueueTail()
        tail.sceneEnteredBackground()
        return tail
    }

    /// Song 2 of 6 playing, tail queued behind it (song 3, catalog "s3").
    private func queued(_ tail: inout BackgroundQueueTail, generation: Int = 7) {
        tail.noteQueued(afterIndex: 2, generation: generation, headEntryID: "e2", nextSongID: "s3")
    }

    // MARK: - Widening

    func testWidensWithTheNextSongInTheBackground() {
        let tail = backgrounded()
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: 2, headPlaying: true, headPosition: 40, boundaryWorkArmed: false),
                       .queueNext(afterIndex: 2, nextIndex: 3))
    }

    func testStaysOneSongInTheForeground() {
        var tail = BackgroundQueueTail()
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: 2, headPlaying: true, headPosition: 40, boundaryWorkArmed: false),
                       .keepOneSong(.foreground))
        tail.sceneEnteredBackground()
        tail.sceneBecameActive()
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: 2, headPlaying: true, headPosition: 40, boundaryWorkArmed: false),
                       .keepOneSong(.foreground), "back in the foreground: one song again")
    }

    func testStaysOneSongWhenABreakIsArmed() {
        XCTAssertEqual(backgrounded().widen(queueIndex: 2, queueCount: 6, loadedIndex: 2, headPlaying: true, headPosition: 40, boundaryWorkArmed: true),
                       .keepOneSong(.boundaryWorkArmed))
    }

    func testStaysOneSongOnTheLastStationSong() {
        XCTAssertEqual(backgrounded().widen(queueIndex: 5, queueCount: 6, loadedIndex: 5, headPlaying: true, headPosition: 40, boundaryWorkArmed: false),
                       .keepOneSong(.noNextSong))
    }

    /// The boundary before the queue's last song runs the station refill: that boundary keeps today's path.
    func testStaysOneSongWhenTheNextSongIsTheLast() {
        XCTAssertEqual(backgrounded().widen(queueIndex: 4, queueCount: 6, loadedIndex: 4, headPlaying: true, headPosition: 40, boundaryWorkArmed: false),
                       .keepOneSong(.refillBoundary))
    }

    func testStaysOneSongWhenThePlayingSongIsNotTheLoadedOne() {
        let tail = backgrounded()
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: nil, headPlaying: true, headPosition: 40, boundaryWorkArmed: false),
                       .keepOneSong(.notLoaded))
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: 1, headPlaying: true, headPosition: 40, boundaryWorkArmed: false),
                       .keepOneSong(.notLoaded))
    }

    /// Paused, or just started (the DJ session may still be arming this boundary's break): asked
    /// again on a later background poll.
    func testWaitsForAPlayingSettledSong() {
        let tail = backgrounded()
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: 2, headPlaying: false, headPosition: 40,
                                  boundaryWorkArmed: false), .keepOneSong(.notPlaying))
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: 2, headPlaying: true, headPosition: 1,
                                  boundaryWorkArmed: false), .keepOneSong(.settling))
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: 2, headPlaying: true, headPosition: nil,
                                  boundaryWorkArmed: false), .keepOneSong(.settling))
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: 2, headPlaying: true,
                                  headPosition: BackgroundQueueTail.settleSeconds, boundaryWorkArmed: false),
                       .queueNext(afterIndex: 2, nextIndex: 3))
    }

    func testQueuesOnlyOneTail() {
        var tail = backgrounded()
        queued(&tail)
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: 2, headPlaying: true, headPosition: 40, boundaryWorkArmed: false),
                       .keepOneSong(.alreadyQueued))
    }

    // MARK: - Adoption

    func testAdoptionAfterWakingIsNotASkipAndNotANaturalEndBreak() {
        var tail = backgrounded()
        _ = tail.observe(entryID: "e2", entrySongID: "s2", queueIndex: 2, generation: 7, appNextSongID: nil,
                         boundaryWorkArmed: false, uptime: 100)
        queued(&tail)
        // Suspended for minutes; MusicKit is on the queued song when the app wakes.
        let step = tail.observe(entryID: "e3", entrySongID: "s3", queueIndex: 2, generation: 7, appNextSongID: "s3",
                                boundaryWorkArmed: false, uptime: 400)
        XCTAssertEqual(step, .adopt(finishedIndex: 2, nextIndex: 3, woke: true))
        XCTAssertNil(tail.pending, "adopted once")
        XCTAssertEqual(tail.observe(entryID: "e3", entrySongID: "s3", queueIndex: 3, generation: 7, appNextSongID: nil,
                                    boundaryWorkArmed: false, uptime: 401), .unchanged)
    }

    func testAdoptionWhileAwakeWithNothingArmed() {
        var tail = backgrounded()
        queued(&tail)
        XCTAssertEqual(tail.observe(entryID: "e2", entrySongID: "s2", queueIndex: 2, generation: 7, appNextSongID: "s3",
                                    boundaryWorkArmed: false, uptime: 100), .unchanged)
        XCTAssertEqual(tail.observe(entryID: "e3", entrySongID: "s3", queueIndex: 2, generation: 7, appNextSongID: "s3",
                                    boundaryWorkArmed: false, uptime: 101),
                       .adopt(finishedIndex: 2, nextIndex: 3, woke: false))
    }

    /// An inserted entry is transient and its id can change, so the tail is recognised by its song.
    func testTheTailIsRecognisedByItsSongNotItsEntryID() {
        var tail = backgrounded()
        queued(&tail)
        XCTAssertEqual(tail.observe(entryID: "resolved-id", entrySongID: "s3", queueIndex: 2, generation: 7,
                                    appNextSongID: "s3", boundaryWorkArmed: false, uptime: nil),
                       .adopt(finishedIndex: 2, nextIndex: 3, woke: true))
    }

    /// The detector must hear about the adoption first: otherwise the same sample is a natural end
    /// (a DJ break over the next song, then that song loaded again).
    func testTheDetectorSeesAnAdoptionAsTheAppsOwnChange() {
        func playThroughHead(_ detector: inout BoundaryInterpreter) {
            for second in stride(from: 0.0, through: 175, by: 5) {
                _ = detector.interpret(PlaybackObservation(entryID: "e2", isPlaying: true, position: second,
                                                           duration: 180, uptime: 1000 + second),
                                       queueIndex: 2, queueCount: 6)
            }
        }
        let onTail = PlaybackObservation(entryID: "e3", isPlaying: true, position: 1, duration: 200, uptime: 1181)

        var unannounced = BoundaryInterpreter()
        playThroughHead(&unannounced)
        if case .advancedEntry = unannounced.interpret(onTail, queueIndex: 2, queueCount: 6) {} else {
            XCTFail("without the adoption call this sample is a natural end")
        }

        var adopted = BoundaryInterpreter()
        playThroughHead(&adopted)
        adopted.userRequestedChange()
        XCTAssertNil(adopted.interpret(onTail, queueIndex: 3, queueCount: 6), "not a natural end")
        XCTAssertFalse(adopted.takeRemoteSkip(), "not a remote skip")
        XCTAssertFalse(adopted.takeNoProgressEnd())
        XCTAssertFalse(adopted.takeSkipLoadCut())
    }

    /// A lock-screen Next onto the queued song while the app is awake is adopted too (no break was
    /// armed, so nothing is lost), not reloaded by the remote-skip path.
    func testAMidSongMoveOntoTheTailIsAdopted() {
        var tail = backgrounded()
        queued(&tail)
        _ = tail.observe(entryID: "e2", entrySongID: "s2", queueIndex: 2, generation: 7, appNextSongID: "s3",
                         boundaryWorkArmed: false, uptime: 50)
        XCTAssertEqual(tail.observe(entryID: "e3", entrySongID: "s3", queueIndex: 2, generation: 7, appNextSongID: "s3",
                                    boundaryWorkArmed: false, uptime: 51),
                       .adopt(finishedIndex: 2, nextIndex: 3, woke: false))
    }

    // MARK: - Trim before a break, and in the foreground

    func testTrimsBeforeABreak() {
        var tail = backgrounded()
        queued(&tail)
        XCTAssertEqual(tail.observe(entryID: "e2", entrySongID: "s2", queueIndex: 2, generation: 7, appNextSongID: "s3",
                                    boundaryWorkArmed: true, uptime: 100), .trim(.boundaryWorkArmed))
        tail.trimmed()
        XCTAssertNil(tail.pending)
    }

    /// Fry's #617 follow-up: arming the boundary trims at once (event-driven), not on the next poll.
    func testArmingTheBoundaryTrimsImmediately() {
        var tail = backgrounded()
        queued(&tail)
        XCTAssertEqual(tail.workArmed(afterIndex: 2, entryID: "e2"), .trim(.boundaryWorkArmed),
                       "no poll needed: the arm itself trims")
        XCTAssertEqual(tail.workArmed(afterIndex: 1, entryID: "e2"), .unchanged, "another boundary's work")
        XCTAssertEqual(tail.workArmed(afterIndex: 2, entryID: "e3"), .unchanged,
                       "already on the tail: the poll hands it back instead")
        tail.trimmed()
        XCTAssertEqual(tail.workArmed(afterIndex: 2, entryID: "e2"), .unchanged, "nothing left to trim")
        XCTAssertEqual(BackgroundQueueTail().workArmed(afterIndex: 2, entryID: "e2"), .unchanged)
    }

    /// The trim comes before the talk-over's duck: the claim trims, and the last gate before the duck
    /// finds nothing left, so no duck step ever runs with the next song still queued.
    func testTheTrimRunsBeforeTheBreaksDuckStarts() {
        var tail = backgrounded()
        queued(&tail)
        var events: [String] = []
        func arm() {
            if case let .trim(reason) = tail.workArmed(afterIndex: 2, entryID: "e2") {
                tail.trimmed()
                events.append("trim:\(reason.logCode)")
            }
        }
        arm()                                   // TalkoverCoordinator.tick: right after the claim
        arm()                                   // TalkoverCoordinator.take: right before the duck
        for step in TalkoverSessionSequence.duck {
            XCTAssertNil(tail.pending, "no queued next song while the duck runs")
            events.append("duck:\(step)")
        }
        XCTAssertEqual(events.first, "trim:boundaryWorkArmed")
        XCTAssertEqual(events.filter { $0.hasPrefix("trim") }.count, 1, "trimmed once")
        XCTAssertGreaterThan(events.count, 1, "the duck has steps")
        // The poll backstop then sees no tail and keeps one song while the break is armed.
        XCTAssertEqual(tail.observe(entryID: "e2", entrySongID: "s2", queueIndex: 2, generation: 7, appNextSongID: "s3",
                                    boundaryWorkArmed: true, uptime: 100), .unchanged)
        XCTAssertEqual(tail.widen(queueIndex: 2, queueCount: 6, loadedIndex: 2, headPlaying: true, headPosition: 40,
                                  boundaryWorkArmed: true), .keepOneSong(.boundaryWorkArmed))
    }

    func testTrimsBackToOneSongInTheForeground() {
        var tail = backgrounded()
        queued(&tail)
        tail.sceneBecameActive()
        XCTAssertEqual(tail.observe(entryID: "e2", entrySongID: "s2", queueIndex: 2, generation: 7, appNextSongID: "s3",
                                    boundaryWorkArmed: false, uptime: 100), .trim(.foreground))
    }

    func testTrimsWhenTheAppsNextSongChanged() {
        var tail = backgrounded()
        queued(&tail)
        XCTAssertEqual(tail.observe(entryID: "e2", entrySongID: "s2", queueIndex: 2, generation: 7, appNextSongID: "s9",
                                    boundaryWorkArmed: false, uptime: 100), .trim(.queueChanged))
    }

    /// The app was awake at the end, and a break was armed after the tail was queued: the DJ must
    /// not talk over the next song, so the tail goes back to the normal boundary.
    func testAnArmedBreakAtAnAwakeEndHandsTheTailBack() {
        var tail = backgrounded()
        queued(&tail)
        _ = tail.observe(entryID: "e2", entrySongID: "s2", queueIndex: 2, generation: 7, appNextSongID: "s3",
                         boundaryWorkArmed: false, uptime: 100)
        XCTAssertEqual(tail.observe(entryID: "e3", entrySongID: "s3", queueIndex: 2, generation: 7, appNextSongID: "s3",
                                    boundaryWorkArmed: true, uptime: 101),
                       .handBack(finishedIndex: 2, finishedEntryID: "e2"))
        XCTAssertNil(tail.pending)
    }

    /// Asleep through the end, the boundary is gone: the playing next song is adopted, never cut.
    func testAnArmedBreakAfterWakingStillAdopts() {
        var tail = backgrounded()
        _ = tail.observe(entryID: "e2", entrySongID: "s2", queueIndex: 2, generation: 7, appNextSongID: nil,
                         boundaryWorkArmed: false, uptime: 100)
        queued(&tail)
        XCTAssertEqual(tail.observe(entryID: "e3", entrySongID: "s3", queueIndex: 2, generation: 7, appNextSongID: "s3",
                                    boundaryWorkArmed: true, uptime: 300),
                       .adopt(finishedIndex: 2, nextIndex: 3, woke: true))
    }

    /// The app's next song changed while it slept: the playing song is not adopted under the wrong index.
    func testAChangedNextSongIsHandedBackEvenAfterWaking() {
        var tail = backgrounded()
        queued(&tail)
        XCTAssertEqual(tail.observe(entryID: "e3", entrySongID: "s3", queueIndex: 2, generation: 7, appNextSongID: "s9",
                                    boundaryWorkArmed: false, uptime: nil),
                       .handBack(finishedIndex: 2, finishedEntryID: "e2"))
    }

    // MARK: - Stale tails

    func testANewQueueForgetsTheTail() {
        var tail = backgrounded()
        queued(&tail)
        tail.queueReplaced()
        XCTAssertNil(tail.pending)
        queued(&tail)
        XCTAssertEqual(tail.observe(entryID: "x0", entrySongID: "s3", queueIndex: 0, generation: 8, appNextSongID: nil,
                                    boundaryWorkArmed: false, uptime: 100), .forget, "another generation is never adopted")
    }

    func testAnEmptiedPlayerForgetsTheTailAndLeavesTheSampleToTheDetector() {
        var tail = backgrounded()
        queued(&tail)
        XCTAssertEqual(tail.observe(entryID: nil, entrySongID: nil, queueIndex: 2, generation: 7, appNextSongID: "s3",
                                    boundaryWorkArmed: false, uptime: 100), .forget)
    }

    func testAnUnknownEntryIsNotAdopted() {
        var tail = backgrounded()
        queued(&tail)
        XCTAssertEqual(tail.observe(entryID: "e9", entrySongID: "s9", queueIndex: 2, generation: 7, appNextSongID: "s3",
                                    boundaryWorkArmed: false, uptime: 100), .forget)
    }

    // MARK: - What counts as armed

    func testBoundaryWorkArmed() {
        func armed(_ dj: DJPresentationState, speaking: Bool = false, talkover: Bool = false, station: Bool = false) -> Bool {
            BackgroundQueueTail.boundaryWorkArmed(afterTrack: 2, dj: dj, interludeSpeaking: speaking,
                                                  talkoverOwnsBoundary: talkover, stationWorkPending: station)
        }
        XCTAssertFalse(armed(.idle))
        XCTAssertTrue(armed(.preparing(afterTrack: 2, includesBriefing: false)))
        XCTAssertTrue(armed(.ready(afterTrack: 2, includesBriefing: false, seconds: 8)))
        XCTAssertFalse(armed(.ready(afterTrack: 1, includesBriefing: false, seconds: 8)), "another boundary's break")
        XCTAssertTrue(armed(.speaking(afterTrack: 1, includesBriefing: false)))
        XCTAssertTrue(armed(.idle, speaking: true))
        XCTAssertTrue(armed(.idle, talkover: true))
        XCTAssertTrue(armed(.idle, station: true))
        XCTAssertFalse(armed(.unavailable(.voiceFailed)))
    }

    func testLogLinesCarryIndicesAndCodesOnly() {
        XCTAssertEqual(PlaybackLog.queueTailQueued(after: 2, next: 3), "queueTail queued after=2 next=3")
        XCTAssertEqual(PlaybackLog.queueTailKept(index: 4, reason: .refillBoundary), "queueTail kept index=4 reason=refillBoundary")
        XCTAssertEqual(PlaybackLog.queueTailTrimmed(after: 2, reason: .boundaryWorkArmed),
                       "queueTail trimmed after=2 reason=boundaryWorkArmed")
        XCTAssertEqual(PlaybackLog.queueTailAdopted(finished: 2, next: 3, woke: true), "queueTail adopted finished=2 next=3 woke=true")
        XCTAssertEqual(PlaybackLog.queueTailHandedBack(finished: 2), "queueTail handedBack finished=2")
    }

    // MARK: - App wiring (source checks; the app target does not build on Linux)

    private static let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.ios.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheScenePhaseHookIsWired() throws {
        let app = try source("AeroDJ/AeroDJApp.swift")
        XCTAssertTrue(app.contains("@Environment(\\.scenePhase) private var scenePhase"))
        XCTAssertTrue(app.contains("case .background: dependencies.playback.sceneEnteredBackground()"))
        XCTAssertTrue(app.contains("case .active: dependencies.playback.sceneBecameActive()"))
        // Not behind the DIAG flag: the hook ships in every build.
        let hook = try XCTUnwrap(app.range(of: "sceneEnteredBackground()"))
        let before = app[..<hook.lowerBound]
        XCTAssertEqual(before.components(separatedBy: "#if").count, before.components(separatedBy: "#endif").count,
                       "the scene-phase hook is outside any #if block")
    }

    func testMusicKitServiceJudgesTheTailBeforeTheDetector() throws {
        let service = try source("AeroDJ/MusicKitService.swift")
        let step = try XCTUnwrap(service.range(of: "switch queueTailStep(observation)"))
        let interpret = try XCTUnwrap(service.range(of: "let interpreted = boundaries.interpret(observation"))
        XCTAssertLessThan(step.lowerBound, interpret.lowerBound, "the tail is judged before the detector")
        XCTAssertTrue(service.contains("try await player.queue.insert(song, position: .tail)"))
        XCTAssertTrue(service.contains("queueTail.queueReplaced()"), "a new one-song queue forgets the tail")
        // Adoption tells the detector first, then reports the song start (the DJ plans its next break).
        let adopt = try XCTUnwrap(service.range(of: "private func adoptQueueTail("))
        let body = service[adopt.lowerBound...].prefix(1400)
        let told = try XCTUnwrap(body.range(of: "boundaries.userRequestedChange()"))
        let started = try XCTUnwrap(body.range(of: "noteSongStarted(index: next"))
        XCTAssertLessThan(told.lowerBound, started.lowerBound)
        XCTAssertFalse(body.contains("onBoundary?("), "an adopted song is not a natural-end boundary")
        XCTAssertFalse(body.contains("onSongSkipped?("), "an adopted song is not a skip")
    }

    /// Fry's #617 condition 1: widen and trim work in place on the live queue. Only `startTrack`'s
    /// load assigns the queue.
    func testTailHelpersNeverReassignTheQueue() throws {
        let service = try source("AeroDJ/MusicKitService.swift")
        let start = try XCTUnwrap(service.range(of: "// MARK: - #304 R1: the next song behind the playing one"))
        let end = try XCTUnwrap(service.range(of: "// MARK: - Track-boundary observation"))
        let helpers = service[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(helpers.contains("player.queue ="), "no queue reset in the tail helpers")
        XCTAssertFalse(helpers.contains("player.queue.entries ="), "no entries reassignment in the tail helpers")
        XCTAssertTrue(helpers.contains("player.queue.entries.remove(at: index)"), "in-place removal")
        XCTAssertTrue(helpers.contains("for index in doomed.reversed()"), "highest index first")
        XCTAssertTrue(helpers.contains("guard index > at else { return false }"), "never the current entry or before")
        XCTAssertEqual(service.components(separatedBy: "player.queue = ").count - 1, 1, "only the load line")
        XCTAssertTrue(service.contains("player.queue = ApplicationMusicPlayer.Queue(for: [song])"))
        XCTAssertFalse(service.contains("player.queue.entries = "))
    }

    /// Fry's #617 follow-up (a): the handed-back song is paused before the boundary (and its break) runs.
    func testHandBackPausesBeforeTheBoundary() throws {
        let service = try source("AeroDJ/MusicKitService.swift")
        let fn = try XCTUnwrap(service.range(of: "private func handBackQueueTail("))
        let body = service[fn.lowerBound...].prefix(1400)
        let pause = try XCTUnwrap(body.range(of: "player.pause()"))
        let boundary = try XCTUnwrap(body.range(of: "onBoundary?("))
        XCTAssertLessThan(pause.lowerBound, boundary.lowerBound)
    }

    /// The talk-over trims at its claim and again right before `duckForTalkover`, which is where the
    /// duck starts (`TalkoverAudioSession.duck`: `.duckOthers`, then the activation).
    func testTalkoverTrimsBeforeTheDuck() throws {
        let talkover = try source("AeroDJ/TalkoverCoordinator.swift")
        let claim = try XCTUnwrap(talkover.range(of: "book.claim(key(k))"))
        let afterClaim = talkover[claim.upperBound...].prefix(200)
        XCTAssertTrue(afterClaim.contains("music.boundaryWorkWasArmed(afterTrack: k)"), "trimmed at the claim")
        let take = try XCTUnwrap(talkover.range(of: "private func take(_ k: Int, token: Int) async {"))
        let body = talkover[take.lowerBound...]
        let trim = try XCTUnwrap(body.range(of: "music.boundaryWorkWasArmed(afterTrack: k)"))
        let duck = try XCTUnwrap(body.range(of: "interlude.duckForTalkover(afterTrack: k)"))
        XCTAssertLessThan(trim.lowerBound, duck.lowerBound, "the trim precedes the duck")
        let adapter = try source("AeroDJ/InterludePlaybackAdapter.swift")
        XCTAssertTrue(adapter.contains("guard TalkoverAudioSession.duck(afterTrack: afterTrack) else { return false }"),
                      "the duck starts inside duckForTalkover")
    }

    func testABreakArmingTrimsAtOnce() throws {
        let player = try source("AeroDJ/PlayerView.swift")
        XCTAssertTrue(player.contains("for await state in dj.updates() {"))
        XCTAssertTrue(player.contains("case let .preparing(k, _), let .ready(k, _, _): music.boundaryWorkWasArmed(afterTrack: k)"))
    }

    func testTheCompositionRootReportsArmedWork() throws {
        let player = try source("AeroDJ/PlayerView.swift")
        XCTAssertTrue(player.contains("music.boundaryWorkArmed = {"))
        XCTAssertTrue(player.contains("talkoverOwnsBoundary: talkover.ownsBoundary(k)"))
        XCTAssertTrue(player.contains("stationWorkPending: stationQueue?.boundaryWorkPending ?? false"))
        XCTAssertTrue(player.contains("music.onQueueTailAdopted = {"))
    }
}
