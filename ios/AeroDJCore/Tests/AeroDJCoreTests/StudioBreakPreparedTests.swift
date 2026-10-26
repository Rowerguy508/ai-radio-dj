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
        return Rig(studio: studio, session: session, connections: connections, dj: dj, clock: clock, item: item,
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

    /// Queue started with the item's note in break 0, song 0 playing, break 0 rendered and waiting.
    private func readyRig(voice: BPVoice = .init(), expiresIn: TimeInterval? = nil) async -> Rig {
        let r = await rig(voice: voice, expiresIn: expiresIn)
        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
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

        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item))
        XCTAssertFalse(r.studio.isBreakPrepared, "idle: false")
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until(r.dj, isPreparing)
        XCTAssertFalse(r.studio.isBreakPrepared, "preparing: false")

        await gate.open()
        await until(r.dj, isReady)
        XCTAssertTrue(r.studio.isBreakPrepared, "ready: true")

        let handed = await r.session.naturalBoundary(afterTrack: 0)
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
        _ = await r.session.naturalBoundary(afterTrack: 0)
        r.session.playbackFailed(afterTrack: 0)
        XCTAssertFalse(r.studio.isBreakPrepared, "failed: false")
        r.recorder.cancel()
    }

    func testRenderFailureNeverBecomesTrue() async {
        let r = await rig(voice: BPVoice(fails: true))
        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until(r.dj) { if case .unavailable(.voiceFailed) = $0 { true } else { false } }
        XCTAssertFalse(r.studio.isBreakPrepared, "render failure: false")
        XCTAssertFalse(r.seen().contains(true), "never true")
        r.recorder.cancel()
    }

    func testBreakStillRenderingAtTheBoundaryIsDroppedAndNeverTrue() async {
        let gate = Gate()
        let r = await rig(voice: BPVoice(gate: gate))
        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await gate.arrived()
        let outcome = await r.session.naturalBoundary(afterTrack: 0)   // missed its deadline: dropped
        XCTAssertNil(outcome, "music never waits")
        XCTAssertFalse(r.studio.isBreakPrepared, "dropped: false")
        await gate.open()
        await r.session.songStarted(index: 1, remaining: .seconds(180))
        _ = await r.session.naturalBoundary(afterTrack: 1)
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
        await r.session.songStarted(index: 1, remaining: .seconds(180))
        await until(r.dj) { !self.isReady($0) }
        XCTAssertFalse(r.studio.isBreakPrepared, "skip: false")
        let none = await r.session.naturalBoundary(afterTrack: 1)
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
        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome)
        r.recorder.cancel()
    }

    func testRevokeWhileReadyTurnsItFalseImmediately() async {
        let r = await readyRig()
        let result = await r.connections.perform(.revoke, on: r.item)
        XCTAssertNoThrow(try result.get())
        XCTAssertFalse(r.studio.isBreakPrepared, "revoked while ready: false")
        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome)
        XCTAssertFalse(r.studio.isBreakPrepared)
        r.recorder.cancel()
    }

    func testExpiryOfItsSourceTurnsItFalse() async {
        let r = await readyRig(expiresIn: 600)
        r.clock.advance(601)
        await r.connections.refresh()   // expired items are purged here (boundary-time recheck: #73)
        XCTAssertFalse(r.studio.isBreakPrepared, "expired: false")
        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome)
        r.recorder.cancel()
    }

    func testRevokeDuringPreparationNeverBecomesTrue() async {
        let gate = Gate()
        let r = await rig(voice: BPVoice(gate: gate))
        await r.session.queueStarted(djTracks(8), briefing: briefing(r.item))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await gate.arrived()                                        // rendering now
        _ = await r.connections.perform(.revoke, on: r.item)
        XCTAssertFalse(r.studio.isBreakPrepared)
        await gate.open()                                           // the render finishes after the revoke
        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome, "revoked break never plays")
        for k in 1..<3 {   // the next planned break (3) has no personal item and may be prepared
            await r.session.songStarted(index: k, remaining: .seconds(180))
            _ = await r.session.naturalBoundary(afterTrack: k)
            XCTAssertFalse(r.studio.isBreakPrepared)
        }
        XCTAssertFalse(r.seen().contains(true), "never ready/true for the revoked break")
        r.recorder.cancel()
    }
}
