import XCTest
@testable import AeroDJCore

// `StudioPresentationModel.isBreakPrepared`, the Bool behind Nova's fixed "A break is coming"
// line. Drives the real StudioPresentationModel fed by the real DJBreakSession/DJBreakPreparer
// (on-device voice, $0 budget). Waits use the DJ store's update stream, never sleeps. -Fry

/// One-shot gate: `wait()` suspends until `open()`; `arrived()` returns once someone waits.
private actor Gate {
    private var isOpen = false
    private var arrivedCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        arrivedCount += 1
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func arrived() async {
        if arrivedCount > 0 { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
}

private struct BPVoice: VoiceProvider {
    var gate: Gate?
    var fails = false
    struct Failure: Error {}
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        if let gate { await gate.wait() }
        if fails { throw Failure() }
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: 2, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// Re-resolves expiry against the model's clock, like the live providers do.
private actor ExpiringProvider: ConnectionItemProvider {
    nonisolated let integration: StationIntegration = .obsidian
    let id: UUID
    let expiresAt: Date
    init(id: UUID, expiresAt: Date) { self.id = id; self.expiresAt = expiresAt }
    func items(now: Date) async throws -> [ConnectionItem] {
        [ConnectionItem(id: id, integration: .obsidian, title: "[TEST] note",
                        state: now < expiresAt ? .approved : .expired, expiresAt: expiresAt)]
    }
    func perform(_ action: ConnectionAction, on id: UUID) async throws {}
}

@MainActor private final class Seen { var all: [Bool] = [] }

@MainActor
final class StudioBreakPreparedTests: XCTestCase {
    private struct Rig {
        let studio: StudioPresentationModel
        let session: DJBreakSession
        let connections: ConnectionsModel
        let dj: DJPresentationStore
        let clock: TestClock
        let item: UUID
        /// The item's Connections row, as the app passes it with the briefing.
        let source: ConnectionItem
        let purger: NarrationPurger
        /// Every `isBreakPrepared` value seen on each DJ state change (current value first).
        let seen: () -> [Bool]
        let recorder: Task<Void, Never>
    }

    private func rig(voice: BPVoice = .init(), expiresIn: TimeInterval? = nil) async -> Rig {
        let item = UUID()
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([.obsidian: .granted]))
        await station.load()
        let cache = InMemoryAudioCache()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: voice, voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        await session.start()
        let purger = NarrationPurger(cache: cache, preparer: preparer, session: session)
        let provider: any ConnectionItemProvider = expiresIn.map { ExpiringProvider(id: item, expiresAt: clock.now + $0) }
            ?? InMemoryConnectionItemProvider(integration: .obsidian, items: [
                ConnectionItem(id: item, integration: .obsidian, title: "[TEST] note", state: .approved)])
        let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(),
                                           providers: [provider],
                                           purger: purger,
                                           now: { clock.now })
        await connections.refresh()
        let studio = StudioPresentationModel(station: station, recipes: StationRecipeLibrary(store: InMemoryStationRecipeStore()),
                                             connections: connections, dj: dj)
        let values = Seen()
        let updates = dj.updates()
        let recorder = Task { @MainActor in
            for await _ in updates { values.all.append(studio.isBreakPrepared) }
        }
        let source = ConnectionItem(id: item, integration: .obsidian, title: "[TEST] note", state: .approved,
                                    expiresAt: expiresIn.map { clock.now + $0 }, sensitivity: .low)
        return Rig(studio: studio, session: session, connections: connections, dj: dj, clock: clock, item: item, source: source,
                   purger: purger, seen: { values.all }, recorder: recorder)
    }

    private func briefing(_ item: UUID) -> NarrationHandoff {
        let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "From your notes: water the plants.",
                               estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .obsidian, provenance: "fixture:n1")
        return NarrationHandoff(cues: [cue], maxSpokenSeconds: 60, experienceSeconds: 600)
    }

    /// Waits for the next DJ state matching `condition` (bounded only by the suite timeout).
    private func until(_ dj: DJPresentationStore, _ condition: (DJPresentationState) -> Bool) async {
        for await s in dj.updates() where condition(s) { return }
    }
    private func isReady(_ s: DJPresentationState) -> Bool { if case .ready = s { true } else { false } }
    private func isPreparing(_ s: DJPresentationState) -> Bool { if case .preparing = s { true } else { false } }

    /// What the player reports at a song start (PlayerView `onSongStarted`): the Studio's
    /// playback position, then the DJ session.
    private func play(_ r: Rig, _ index: Int) async {
        r.studio.songStarted(index: index)
        await r.session.songStarted(index: index, remaining: .seconds(180))
    }

    /// What the player reports when song `k` ends on its own (PlayerView `onBoundary`).
    private func boundary(_ r: Rig, _ k: Int) async -> PreparedDJBreak? {
        r.studio.songBoundaryReached(afterTrack: k)
        return await r.session.naturalBoundary(afterTrack: k)
    }

    /// Queue started with the item's note in break 0, song 0 playing, break 0 rendered and waiting.
    private func readyRig(voice: BPVoice = .init(), expiresIn: TimeInterval? = nil) async -> Rig {
        let r = await rig(voice: voice, expiresIn: expiresIn)
        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item), sources: [r.source])
        await play(r, 0)
        await until(r.dj, isReady)
        XCTAssertTrue(r.studio.isBreakPrepared, "rendered and waiting for the boundary")
        return r
    }

    // MARK: Shape and privacy

    func testExposesOnlyAReadOnlyBool() async {
        let r = await rig()
        let path: KeyPath<StudioPresentationModel, Bool> = \.isBreakPrepared
        XCTAssertFalse(path is WritableKeyPath<StudioPresentationModel, Bool>, "read-only")
        XCTAssertTrue(type(of: r.studio.isBreakPrepared) == Bool.self, "a Bool: no text, names or ids")
        r.recorder.cancel()
    }

    // MARK: Lifecycle

    func testStartsFalseAndIsTrueOnlyWhileARenderedBreakWaits() async {
        let gate = Gate()
        let r = await rig(voice: BPVoice(gate: gate))
        XCTAssertFalse(r.studio.isBreakPrepared, "initial: false")
        XCTAssertEqual(r.dj.state, .idle)

        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item), sources: [r.source])
        XCTAssertFalse(r.studio.isBreakPrepared, "idle: false")
        await play(r, 0)
        await until(r.dj, isPreparing)
        XCTAssertFalse(r.studio.isBreakPrepared, "preparing: false")

        await gate.open()
        await until(r.dj, isReady)
        XCTAssertTrue(r.studio.isBreakPrepared, "ready: true")

        let handed = await boundary(r, 0)
        XCTAssertNotNil(handed)
        r.session.playbackStarted(afterTrack: 0)
        XCTAssertFalse(r.studio.isBreakPrepared, "speaking: false")
        r.session.playbackFinished(afterTrack: 0)
        XCTAssertFalse(r.studio.isBreakPrepared, "after the break: false")
        XCTAssertEqual(r.dj.state, .idle)
        r.recorder.cancel()
    }

    func testFailedPlaybackIsFalse() async {
        let r = await readyRig()
        _ = await boundary(r, 0)
        r.session.playbackFailed(afterTrack: 0)
        XCTAssertFalse(r.studio.isBreakPrepared, "failed: false")
        r.recorder.cancel()
    }

    func testRenderFailureNeverBecomesTrue() async {
        let r = await rig(voice: BPVoice(fails: true))
        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item), sources: [r.source])
        await play(r, 0)
        await until(r.dj) { if case .unavailable(.voiceFailed) = $0 { true } else { false } }
        XCTAssertFalse(r.studio.isBreakPrepared, "render failure: false")
        XCTAssertFalse(r.seen().contains(true), "never true")
        r.recorder.cancel()
    }

    func testBreakStillRenderingAtTheBoundaryIsDroppedAndNeverTrue() async {
        let gate = Gate()
        let r = await rig(voice: BPVoice(gate: gate))
        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item), sources: [r.source])
        await play(r, 0)
        await gate.arrived()
        let outcome = await boundary(r, 0)   // missed its deadline: dropped
        XCTAssertNil(outcome, "music never waits")
        XCTAssertFalse(r.studio.isBreakPrepared, "dropped: false")
        await gate.open()
        await play(r, 1)
        _ = await boundary(r, 1)
        XCTAssertFalse(r.seen().contains(true), "a late render never raises it")
        r.recorder.cancel()
    }

    // MARK: Dropped

    func testSongCutDropsIt() async {
        let r = await readyRig()
        await r.session.songCut(afterTrack: 0)
        await until(r.dj) { !self.isReady($0) }
        XCTAssertFalse(r.studio.isBreakPrepared, "songCut: false")
        r.recorder.cancel()
    }

    /// The player's skip: the playing song is cut, the next one starts.
    func testSkipDropsIt() async {
        let r = await readyRig()
        await r.session.songCut(afterTrack: 0)
        await play(r, 1)
        await until(r.dj) { !self.isReady($0) }
        XCTAssertFalse(r.studio.isBreakPrepared, "skip: false")
        let none = await boundary(r, 1)
        XCTAssertNil(none)
        XCTAssertFalse(r.studio.isBreakPrepared)
        r.recorder.cancel()
    }

    func testStopDropsIt() async {
        let r = await readyRig()
        await r.session.stop()
        XCTAssertFalse(r.studio.isBreakPrepared, "stopped: false")
        r.recorder.cancel()
    }

    // MARK: Consent

    func testPurgeOfItsSourceTurnsItFalseImmediately() async {
        let r = await readyRig()
        await r.purger.purge(sourceItemIDs: [r.item])
        XCTAssertFalse(r.studio.isBreakPrepared, "purge: false at once")
        let outcome = await boundary(r, 0)
        XCTAssertNil(outcome)
        r.recorder.cancel()
    }

    func testRevokeWhileReadyTurnsItFalseImmediately() async {
        let r = await readyRig()
        let result = await r.connections.perform(.revoke, on: r.item)
        XCTAssertNoThrow(try result.get())
        XCTAssertFalse(r.studio.isBreakPrepared, "revoked while ready: false")
        let outcome = await boundary(r, 0)
        XCTAssertNil(outcome)
        XCTAssertFalse(r.studio.isBreakPrepared)
        r.recorder.cancel()
    }

    func testExpiryOfItsSourceTurnsItFalse() async {
        let r = await readyRig(expiresIn: 600)
        r.clock.advance(601)
        await r.connections.refresh()   // expired items are purged here (boundary-time recheck: #73)
        XCTAssertFalse(r.studio.isBreakPrepared, "expired: false")
        let outcome = await boundary(r, 0)
        XCTAssertNil(outcome)
        r.recorder.cancel()
    }

    func testRevokeDuringPreparationNeverBecomesTrue() async {
        let gate = Gate()
        let r = await rig(voice: BPVoice(gate: gate))
        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item), sources: [r.source])
        await play(r, 0)
        await gate.arrived()                                        // rendering now
        _ = await r.connections.perform(.revoke, on: r.item)
        XCTAssertFalse(r.studio.isBreakPrepared)
        await gate.open()                                           // the render finishes after the revoke
        let outcome = await boundary(r, 0)
        XCTAssertNil(outcome, "revoked break never plays")
        for k in 1..<3 {   // the next planned break (3) has no personal item and may be prepared
            await play(r, k)
            _ = await boundary(r, k)
            XCTAssertFalse(r.studio.isBreakPrepared)
        }
        XCTAssertFalse(r.seen().contains(true), "never ready/true for the revoked break")
        r.recorder.cancel()
    }

    // MARK: Stale ready (handed out but never played)

    /// Sentinel #87 / Core fail-closed: a break handed out at its boundary that never plays
    /// can leave DJ status on `.ready` when PlayerView's `reportUnplayed` (.failed) does not
    /// run (Core-only path). `isBreakPrepared` must still go false once the boundary passed.
    func testHandedOutBreakThatNeverPlaysIsFalseOnceItsBoundaryPassed() async {
        let r = await readyRig()
        let handed = await boundary(r, 0)
        XCTAssertNotNil(handed, "handed to the player")
        // No playbackStarted/Failed: the DJ status is stuck on ready.
        guard case .ready(afterTrack: 0, _, _) = r.dj.state else { return XCTFail("precondition: still ready") }
        XCTAssertFalse(r.studio.isBreakPrepared, "boundary passed: no longer coming")
        r.studio.songStarted(index: 1)
        XCTAssertFalse(r.studio.isBreakPrepared, "next song playing: still false")
        r.recorder.cancel()
    }

    func testStaleReadyIsFalseOnceALaterSongPlaysEvenWithoutABoundaryReport() async {
        let r = await readyRig()
        _ = await r.session.naturalBoundary(afterTrack: 0)   // handed out; boundary not reported
        r.studio.songStarted(index: 1)
        guard case .ready(afterTrack: 0, _, _) = r.dj.state else { return XCTFail("precondition: still ready") }
        XCTAssertFalse(r.studio.isBreakPrepared, "a later song is playing")
        r.recorder.cancel()
    }

    func testReadyBreakBeforeItsBoundaryStaysTrue() async {
        let r = await readyRig()
        r.studio.songBoundaryReached(afterTrack: -1)        // an earlier boundary changes nothing
        XCTAssertTrue(r.studio.isBreakPrepared)
        r.studio.songStarted(index: 0)                       // same song re-reported
        XCTAssertTrue(r.studio.isBreakPrepared, "still before its boundary")
        r.recorder.cancel()
    }

    func testFailsClosedWithoutAPlaybackPosition() async {
        let r = await rig()
        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item))
        await r.session.songStarted(index: 0, remaining: .seconds(180))   // position never reported
        await until(r.dj, isReady)
        XCTAssertFalse(r.studio.isBreakPrepared, "can't correlate: false")
        r.studio.songStarted(index: 0)
        XCTAssertTrue(r.studio.isBreakPrepared, "correlated: true")
        r.recorder.cancel()
    }

    func testNewQueueResetsAPassedBoundary() async {
        let r = await readyRig()
        _ = await boundary(r, 0)
        XCTAssertFalse(r.studio.isBreakPrepared)
        await r.session.queueStarted(djTracks(8))           // new queue: a routine break after song 0
        await play(r, 0)
        await until(r.dj) { if case .ready(afterTrack: 0, includesBriefing: false, _) = $0 { true } else { false } }
        XCTAssertTrue(r.studio.isBreakPrepared, "the new queue's break 0 is coming")
        r.recorder.cancel()
    }

    /// The stuck state is remembered by value; a new break that happens to be equal (same
    /// boundary, briefing flag and length) is coming again once it went through preparing.
    func testAnEqualNewReadyBreakAfterAStaleOneIsTrueAgain() async {
        let studio = await StudioPresentationModel.preview()
        let ready = DJPresentationEvent.breakReady(afterTrack: 0, includesBriefing: true, seconds: 4)
        studio.dj.send(.breakPreparing(afterTrack: 0, includesBriefing: true))
        studio.dj.send(ready)
        studio.songStarted(index: 0)
        XCTAssertTrue(studio.isBreakPrepared)
        studio.songBoundaryReached(afterTrack: 0)            // handed out, never plays
        XCTAssertFalse(studio.isBreakPrepared)
        studio.songStarted(index: 0)                         // new queue, song 0
        XCTAssertFalse(studio.isBreakPrepared, "the stuck break is still the same value")
        studio.dj.send(.breakSkipped(afterTrack: 0, .cancelled))
        studio.dj.send(.breakPreparing(afterTrack: 0, includesBriefing: true))
        studio.dj.send(ready)
        for _ in 0..<1000 where !studio.isBreakPrepared { await Task.yield() }
        XCTAssertTrue(studio.isBreakPrepared, "a new break, equal by value, is coming")
    }
    /// `songBoundaryReached` only marks the Studio flag stale. It must never stop a speaking
    /// break (no `onBreakMustStop` / `requestStop`). Stops stay with purge, queue change, and
    /// PlayerView's handOut / reportUnplayed path (#88).
    func testSongBoundaryReachedNeverFiresAStop() async {
        let r = await readyRig()
        var stops: [(InterludeStopReason, Int?)] = []
        r.session.onBreakMustStop = { reason, tag in stops.append((reason, tag)) }
        r.studio.songBoundaryReached(afterTrack: 0)
        XCTAssertFalse(r.studio.isBreakPrepared, "boundary passed: flag clears")
        XCTAssertEqual(stops.count, 0, "songBoundaryReached must not fire onBreakMustStop")
        r.studio.songStarted(index: 1)
        XCTAssertEqual(stops.count, 0, "songStarted must not fire onBreakMustStop either")
        r.recorder.cancel()
    }

}
