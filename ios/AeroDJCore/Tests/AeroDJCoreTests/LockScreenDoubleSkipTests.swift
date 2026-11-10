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

    /// MusicKit's own Next, twice: the first clear is a remote skip, the second clears the song
    /// that skip is loading. The second one must not pause.
    func testTwoMusicKitClearsWhileLoadingAdvanceTwiceAndDoNotPause() async {
        let show = Show()
        show.primePlaying()
        show.feed(show.cleared())
        await show.untilLoadSuspended()
        show.feed(show.cleared())
        XCTAssertFalse(show.pausedByNoProgress)
        show.finishLoad()
        await show.untilIdle()
        show.assertPlaying(index: 2)
        XCTAssertFalse(show.pausedByNoProgress)
        XCTAssertNil(show.unexpectedBoundary)
    }

    /// The other MusicKit shape: rewind to 0:00, then the loaded song rewound again before it
    /// has played past the failed-start window.
    func testTwoMusicKitRewindsWhileLoadingAdvanceTwiceAndDoNotPause() async {
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
        show.assertPlaying(index: 2)
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
    /// Reload that song. Do not pause and do not skip another one.
    func testLoadCutAfterTheChainFinishesReloadsInsteadOfPausing() async {
        let show = Show()
        let running = Task { await show.skip() }
        await show.untilLoadSuspended()
        show.finishLoad()
        await running.value
        show.assertPlaying(index: 1)
        show.feed(show.cleared())
        await show.untilIdle()
        show.assertPlaying(index: 1)
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
        XCTAssertTrue(source.contains("noteLoadCut()"))
        XCTAssertTrue(source.contains("await self?.skip()") || source.contains("await self.skip()"),
                      "nextTrackCommand still targets skip()")
        XCTAssertTrue(source.contains("if skipCoordinator.isInFlight { return }"),
                      "a break resume does not start a second play while a skip owns the player")
    }
}

// MARK: - Show

/// The skip/poll loop `MusicKitService` runs, on the real engine and detector.
/// A prepared or airing break uses the real session, preparer and on-device renderer.
@MainActor
private final class Show {
    let songs = 6
    let coordinator = SkipCoordinator()
    var boundaries = BoundaryInterpreter()
    var engine = PlaybackEngine()
    private let gate = LoadGate()
    private(set) var index = 0
    private(set) var audible = false
    private(set) var pausedByNoProgress = false
    private(set) var unexpectedBoundary: BoundaryStep?
    private(set) var speechOverlapped = false
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
    static func preparedBreak() async -> Show {
        let rig = await Self.makeSession()
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

    private static func makeSession() async -> (session: DJBreakSession, preparer: DJBreakPreparer, dj: DJPresentationStore) {
        var config = StationConfiguration(commentary: .frequent)
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

    func assertPlaying(index expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(index, expected, "queue index", file: file, line: line)
        XCTAssertEqual(engine.snapshot.nowPlaying?.id, "t\(expected)", file: file, line: line)
        XCTAssertEqual(engine.snapshot.transport, .playing, file: file, line: line)
        XCTAssertTrue(audible, "the player is audible", file: file, line: line)
        XCTAssertFalse(pausedByNoProgress, file: file, line: line)
        XCTAssertNil(unexpectedBoundary, file: file, line: line)
    }

    func assertBreakNotAiring(advancedTo expected: Int) async {
        assertPlaying(index: expected)
        XCTAssertFalse(dj?.state.isLive ?? false, "no break is speaking")
        XCTAssertFalse(speechOverlapped, "a second line started while one was still speaking")
        XCTAssertNotEqual(dj?.state.speakingTrack, 0)
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
        switch coordinator.requestAdvance() {
        case .queueOneMore, .ignore:
            return
        case .begin:
            boundaries.setSkipLoadInFlight(true)
            await coordinator.runChain { job in
                await self.perform(job)
            }
        }
    }

    func finishLoad() { gate.release() }

    func untilLoadSuspended() async {
        for _ in 0..<1000 where !gate.isWaiting { await Task.yield() }
        XCTAssertTrue(gate.isWaiting, "the skip load is in flight")
    }

    func untilIdle() async {
        for _ in 0..<1000 where coordinator.isInFlight || gate.isWaiting { await Task.yield() }
        XCTAssertFalse(coordinator.isInFlight)
    }

    /// One poll, in `MusicKitService.pollPlaybackPosition`'s order.
    func feed(_ observation: PlaybackObservation) {
        let step = boundaries.interpret(observation, queueIndex: index, queueCount: songs)
        if let step {
            unexpectedBoundary = step
            return
        }
        if boundaries.takeRemoteSkip() {
            Task { await self.skip() }
            return
        }
        if boundaries.takeSkipLoadCut() {
            if coordinator.isInFlight {
                coordinator.noteLoadCut()
                _ = coordinator.requestAdvance()
            } else if coordinator.beginRecovery() {
                boundaries.setSkipLoadInFlight(true)
                Task {
                    await self.coordinator.runChain(first: .reload) { job in
                        await self.perform(job)
                    }
                }
            }
            return
        }
        if boundaries.takeNoProgressEnd() {
            if coordinator.isInFlight { return }
            pausedByNoProgress = true
            audible = false
            engine.apply(.userPaused)
        }
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
        audible = true
    }

    private func perform(_ job: SkipJob) async -> SkipAdvanceOutcome {
        switch job {
        case .advance:
            let cut = index
            stopSpeechIfAiring()
            async let dropped: Void = dropPreparedBreak(after: cut)
            let next = index + 1
            guard next < songs else {
                boundaries.setSkipLoadInFlight(false)
                audible = false
                engine.apply(.queueFinished)
                _ = await dropped
                return .queueStopped
            }
            index = next
            engine.apply(.userSkipped(nextIndex: index))
            boundaries.userRequestedChange()
            adoptLoadedEntry()
            await Task.yield()
            await gate.wait()
            _ = await dropped
        case .reload:
            boundaries.userRequestedChange()
            boundaries.setSkipLoadInFlight(true)
            adoptLoadedEntry()
            await gate.wait()
        }
        audible = true
        if engine.snapshot.transport == .preparing {
            engine.apply(.playbackConfirmed)
        }
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
        await session?.songCut(afterTrack: track)
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
}
