import XCTest
@testable import AeroDJCore

// Echo's finding on #258 (rule from #267: a break never switches voices). `VoiceRenderer.render`
// falls back per cue, so a refused cloud write, a provider failure or the per-cue paid gate
// denying mid-break used to leave one break in two voices. The preparer now re-renders the whole
// break once on the standard on-device route, shared with the over-cap fallback (at most one
// whole-break retry), and skips it if that fails or doesn't fit. Fakes only, no sleeps on the
// passing paths. -Nova

private struct HTTP429: Error {}

/// Cloud voice. `onCall(n)` runs inside synthesis for call n (1-based) and may throw.
private final class ScriptedCloud: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    let seconds: Double
    let onCall: @Sendable (Int) async throws -> Void
    init(seconds: Double = 2, onCall: @escaping @Sendable (Int) async throws -> Void = { _ in }) {
        self.seconds = seconds; self.onCall = onCall
    }
    var calls: Int { lock.withLock { n } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let call = lock.withLock { n += 1; return n }
        try await onCall(call)
        return VoiceArtifact(data: Data("cloud:\(text)".utf8), durationSeconds: seconds, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

/// On-device voice. Calls after `hangAfter` never answer in time (the route times out).
private final class CountingDevice: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    let seconds: Double
    let hangAfter: Int?
    init(seconds: Double = 2, hangAfter: Int? = nil) { self.seconds = seconds; self.hangAfter = hangAfter }
    var calls: Int { lock.withLock { n } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let call = lock.withLock { n += 1; return n }
        if let hangAfter, call > hangAfter { try await Task.sleep(for: .seconds(5)) }
        return VoiceArtifact(data: Data("device:\(text)".utf8), durationSeconds: seconds, billableUnits: 0,
                             provider: "device", cacheKey: nil)
    }
}

/// Consent that is given for the first `grants` asks, then withdrawn.
private final class ConsentFor: PaidVoiceConsentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    init(grants: Int) { left = grants }
    func hasPaidVoiceConsent() async -> Bool { lock.withLock { left -= 1; return left >= 0 } }
}

private struct LivePro: ProEntitlementProviding {
    func currentProEntitlement() async -> ProEntitlementState { .pro(productID: ProSubscriptionConfig.monthlyProductID, expiresAt: .distantFuture) }
}

private let cloudVoice = VoiceProfile(id: "cloud-voice", name: "Cloud")
private let standardVoice = VoiceProfile(id: "standard", name: "Standard")

final class BreakOneVoiceTests: XCTestCase {
    private var dirs: [URL] = []
    override func tearDown() { dirs.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }

    private func caches() -> [(name: String, cache: any AudioCache)] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onevoice-\(UUID().uuidString)")
        dirs.append(dir)
        return [("memory", InMemoryAudioCache()), ("file", FileAudioCache(directory: dir))]
    }

    private func renderer(_ cloud: ScriptedCloud, _ device: CountingDevice, cache: any AudioCache = InMemoryAudioCache(),
                          deviceTimeout: Duration = .seconds(2)) -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: cloudVoice,
                                          microdollarsPerThousandCharacters: 30_000, leavesDevice: true),
                               VoiceRoute(providerID: "device", provider: device, voice: standardVoice, timeout: deviceTimeout)],
                      budget: VoiceBudget(dailyCapMicrodollars: 1_000_000), cache: cache,
                      revocations: NarrationRevocations(), cloudConsent: .inMemory(.accepted))
    }

    /// Three presenter transitions, each allowed to leave the device.
    private func threeCueBreak() -> DJBreak {
        let cues = (1...3).map { n in
            NarrationCue(id: UUID(), order: n, group: 1, kind: .transition, text: "Line \(n) before the next song.",
                         estimatedSeconds: 2, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        }
        return DJBreak(afterTrack: 0, cues: cues, attributions: Dictionary(uniqueKeysWithValues: cues.map { ($0.id, .presenter) }))
    }

    private func prepare(_ r: VoiceRenderer, cap: Double = 60, paidVoice: ProVoiceAccess? = nil) async -> DJBreakOutcome {
        await DJBreakPreparer.render(threeCueBreak(), renderer: r, userID: "u", stationID: "s", cap: cap, paidVoice: paidVoice)
    }

    /// One voice id (and one provider) for every clip and cue of the break.
    private func assertOneVoice(_ outcome: DJBreakOutcome, _ provider: String, _ voiceID: String, _ name: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .ready(let b) = outcome else { return XCTFail("\(name): expected a ready break, got \(outcome)", file: file, line: line) }
        XCTAssertEqual(b.clips.count, 3, name, file: file, line: line)
        XCTAssertEqual(Set(b.clips.map(\.audio.voiceID)), [voiceID], "\(name): one voiceID per break", file: file, line: line)
        XCTAssertEqual(Set(b.clips.map(\.audio.providerID)), [provider], "\(name): one provider per break", file: file, line: line)
        XCTAssertEqual(Set(b.cues.compactMap(\.voiceID)), [voiceID], name, file: file, line: line)
        XCTAssertTrue(DJBreakPreparer.speaksInOneVoice(b.clips), name, file: file, line: line)
    }

    // MARK: mixed first pass -> whole break on-device

    /// A retention sweep, or a consent purge, lands while cue 2 of 3 renders in the cloud: its
    /// write is refused (purge generation) and it falls to on-device, so the whole break is re-rendered there.
    func testRefusedCloudWriteOnCue2GivesAnAllOnDeviceBreak() async {
        for purge in ["sweep", "consent purge"] {
            for (name, cache) in caches() {   // fresh caches: no clip from the other variant
                let holder = RendererHolder()
                let cloud = ScriptedCloud(onCall: { n in
                    guard n == 2, let r = holder.renderer else { return }
                    if purge == "sweep" { await r.cache.purgeExpired() } else { await r.purgeCloudClips() }
                })
                let device = CountingDevice()
                let r = renderer(cloud, device, cache: cache)
                holder.renderer = r
                assertOneVoice(await prepare(r), "device", "standard", "\(name)/\(purge)")
                XCTAssertEqual(cloud.calls, 3, "\(name)/\(purge): no second cloud pass")
            }
        }
    }

    /// A 429 (or any provider failure) on one cue falls to on-device: the whole break is on-device.
    func testProviderFailureOnOneCueGivesAnAllOnDeviceBreak() async {
        for (name, cache) in caches() {
            let cloud = ScriptedCloud(onCall: { n in if n == 2 { throw HTTP429() } })
            let device = CountingDevice()
            let r = renderer(cloud, device, cache: cache)
            assertOneVoice(await prepare(r), "device", "standard", name)
            XCTAssertEqual(cloud.calls, 3, name)
        }
    }

    /// The per-cue paid gate allows cue 1 and denies cue 2 (consent withdrawn mid-break).
    func testPaidGateDenialMidBreakGivesAnAllOnDeviceBreak() async {
        for (name, cache) in caches() {
            let cloud = ScriptedCloud()
            let device = CountingDevice()
            let gate = ProVoiceAccess(entitlement: LivePro(), consent: ConsentFor(grants: 1))
            assertOneVoice(await prepare(renderer(cloud, device, cache: cache), paidVoice: gate), "device", "standard", name)
            XCTAssertEqual(cloud.calls, 1, "\(name): only cue 1 reached the cloud before the denial")
        }
    }

    // MARK: unchanged, skipped, one retry

    func testAllCloudBreakIsUnchangedWithNoRetry() async {
        for (name, cache) in caches() {
            let cloud = ScriptedCloud()
            let device = CountingDevice()
            let r = renderer(cloud, device, cache: cache)
            assertOneVoice(await prepare(r), "cloud", "cloud-voice", name)
            XCTAssertEqual(cloud.calls, 3, name)
            XCTAssertEqual(device.calls, 0, "\(name): no on-device retry")
        }
    }

    /// Mixed first pass (cue 2 falls to on-device), then the on-device retry times out on cue 1:
    /// skipped, with the retry's own reason.
    func testMixedFirstPassWhoseRetryFailsIsSkipped() async {
        let cloud = ScriptedCloud(onCall: { n in if n == 2 { throw HTTP429() } })
        let device = CountingDevice(hangAfter: 1)
        let outcome = await prepare(renderer(cloud, device, deviceTimeout: .milliseconds(50)))
        XCTAssertEqual(outcome, .skipped(.timedOut), "the retry's own skip reason")
        XCTAssertEqual(device.calls, 2, "first pass cue 2, then the retry's cue 1")
    }

    /// Mixed and over the cap: one whole-break retry, and when that is still over the cap the
    /// break is skipped, never retried again.
    func testMixedAndOverCapGetsOnlyOneRetry() async {
        let cloud = ScriptedCloud(seconds: 5, onCall: { n in if n == 2 { throw HTTP429() } })
        let device = CountingDevice(seconds: 5)
        // 5 + 5 + 5 = 15 s over a 12 s cap in both voices. A cache that keeps nothing, so every
        // pass reaches the provider and a second retry would show in the call count.
        let outcome = await prepare(renderer(cloud, device, cache: NoCache()), cap: 12)
        XCTAssertEqual(outcome, .skipped(.overBreakBudget))
        // First pass: cue 2 on-device (1 call). One retry: all 3 cues (3 calls). A second would be 3 more.
        XCTAssertEqual(device.calls, 4, "exactly one on-device retry")
        XCTAssertEqual(cloud.calls, 3)
    }

    /// Mixed and over the cap, with the on-device retry under it: ready, all on-device.
    func testMixedAndOverCapRetryThatFitsIsReady() async {
        let cloud = ScriptedCloud(seconds: 5, onCall: { n in if n == 2 { throw HTTP429() } })
        let device = CountingDevice(seconds: 3)
        assertOneVoice(await prepare(renderer(cloud, device), cap: 12), "device", "standard")
        XCTAssertEqual(device.calls, 3)
    }

    /// Mixed with no on-device route to fall back to (both routes leave the device): skipped.
    func testMixedWithNoOnDeviceRouteIsSkipped() async {
        let a = ScriptedCloud(onCall: { n in if n == 2 { throw HTTP429() } }), b = ScriptedCloud()
        let r = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: a, voice: cloudVoice,
                                                  microdollarsPerThousandCharacters: 30_000, leavesDevice: true),
                                       VoiceRoute(providerID: "cloud-b", provider: b, voice: standardVoice,
                                                  microdollarsPerThousandCharacters: 30_000, leavesDevice: true)],
                              budget: VoiceBudget(dailyCapMicrodollars: 1_000_000), cache: InMemoryAudioCache(),
                              revocations: NarrationRevocations(), cloudConsent: .inMemory(.accepted))
        let outcome = await prepare(r)
        XCTAssertEqual(outcome, .skipped(.renderFailed))
    }

    // MARK: what playback is handed (Fry, #258)

    private static func result(_ preparer: DJBreakPreparer, _ k: Int) async -> DJBreakOutcome? {
        for _ in 0..<1000 {
            if let r = await preparer.testResult(afterTrack: k) { return r }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    /// Fry reproduced cloud/device/cloud from a sweep on cue 2 of 3. Through `prepare` and the
    /// boundary's `takeCheckedBreak` (what the session hands to playback), the break is one voice.
    func testASweepOnCue2NeverReachesTheTakeAsAMixedBreak() async {
        for (name, cache) in caches() {
            let holder = RendererHolder()
            let cloud = ScriptedCloud(onCall: { n in if n == 2 { await holder.renderer?.cache.purgeExpired() } })
            let r = renderer(cloud, CountingDevice(), cache: cache)
            holder.renderer = r
            let preparer = DJBreakPreparer(renderer: r, userID: "u", stationID: "s")
            await preparer.prepare(threeCueBreak(), deadline: .seconds(10), onDeviceOnly: false)
            _ = await Self.result(preparer, 0)
            let taken = await preparer.takeCheckedBreak(afterTrack: 0)
            assertOneVoice(taken, "device", "standard", "\(name): the take")
            XCTAssertEqual(cloud.calls, 3, "\(name): precondition, the sweep landed on cue 2's cloud render")
        }
    }

    /// The same at the session level: every break `naturalBoundary` hands to playback speaks in
    /// one voice. A sweep lands on the first break's second cloud render (that break plays
    /// on-device); the next break has no sweep and plays all in the cloud voice.
    @MainActor
    func testEveryBreakTheSessionHandsToPlaybackIsOneVoiceAfterASweepMidBreak() async {
        for (name, cache) in caches() {
            let holder = RendererHolder()
            let cloud = ScriptedCloud(onCall: { n in if n == 2 { await holder.renderer?.cache.purgeExpired() } })
            let r = renderer(cloud, CountingDevice(), cache: cache)
            holder.renderer = r
            let config = StationConfiguration(commentary: .frequent)
            let station = StationConfigurationModel(
                store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
                consent: StaticIntegrationConsent([:]))
            await station.load()
            let preparer = DJBreakPreparer(renderer: r, userID: "u", stationID: "s", cadence: config.cadence())
            let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
            await session.start()
            await session.queueStarted(djTracks(8, origin: .catalog))   // every line may use the cloud voice
            let boundaries = Array(session.plannedBoundaries.prefix(2))
            guard boundaries.count == 2 else { return XCTFail("\(name): two breaks planned") }
            var voices: [Set<String>] = []
            for k in boundaries {
                await session.songStarted(index: k, remaining: .seconds(180))
                _ = await Self.result(preparer, k)
                guard let played = await session.naturalBoundary(afterTrack: k) else {
                    return XCTFail("\(name): break \(k) handed to playback")
                }
                XCTAssertGreaterThanOrEqual(played.clips.count, 2, "\(name): precondition, a break that could mix")
                XCTAssertEqual(Set(played.clips.map(\.audio.voiceID)).count, 1, "\(name): one voiceID per break played")
                XCTAssertTrue(DJBreakPreparer.speaksInOneVoice(played.clips), name)
                voices.append(Set(played.clips.map(\.audio.providerID)))
            }
            XCTAssertEqual(voices, [["device"], ["cloud"]], "\(name): the swept break on-device, the next one in the cloud")
        }
    }

    // MARK: what counts as one voice

    private func clip(_ provider: String, _ voiceID: String) -> RenderedClip {
        RenderedClip(cueID: UUID(), audio: CachedAudio(data: Data([1]), seconds: 1, providerID: provider, voiceID: voiceID),
                     cacheKey: "k", attempts: [])
    }

    func testABundledClipMatchesTheLiveElevenLabsVoiceWithTheSameVoiceID() {
        let bundled = BundledClipResolver.providerID, live = PremiumVoiceRoutes.providerID
        XCTAssertTrue(DJBreakPreparer.speaksInOneVoice([clip(bundled, "v1"), clip(live, "v1"), clip(bundled, "v1")]))
        XCTAssertFalse(DJBreakPreparer.speaksInOneVoice([clip(bundled, "v1"), clip(live, "v2")]), "another voice id")
        XCTAssertFalse(DJBreakPreparer.speaksInOneVoice([clip(bundled, "v1"), clip("avspeech", "v1")]), "on-device is another voice")
        XCTAssertFalse(DJBreakPreparer.speaksInOneVoice([clip("cloud", "host"), clip("device", "host")]), "same voice id, other provider")
        XCTAssertTrue(DJBreakPreparer.speaksInOneVoice([]))
    }
}

/// Keeps nothing: every render reaches its provider.
private struct NoCache: AudioCache {
    func audio(for key: String) async -> CachedAudio? { nil }
    func store(_ audio: CachedAudio, for key: String) async {}
    func purge(sourceItemIDs: Set<UUID>) async {}
    func purgeExpired() async {}
    func purgeAllPersonal() async {}
}

/// Lets a provider reach the renderer it belongs to (set after the renderer is built).
private final class RendererHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var r: VoiceRenderer?
    var renderer: VoiceRenderer? {
        get { lock.withLock { r } }
        set { lock.withLock { r = newValue } }
    }
}
