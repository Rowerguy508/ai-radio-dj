import XCTest
@testable import AeroDJCore

// #176 (Sentinel): the renderer decides per cue, before any cache lookup, budget reservation or
// provider call, whether a `leavesDevice` route may hear it. Only an explicitly attributed,
// non-personal DJ transition may; everything else is local-only and fails closed.
// All providers are in-process fakes: no network, no paid service.

/// Off-device spy: records every text it is handed, and renders it (so, without the gate, a
/// render would succeed on this route and the test would see it).
private final class OffDeviceSpy: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var received: [String] { lock.withLock { texts } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

/// One-shot barrier (no sleeps): `wait()` suspends until `open()`; `arrived()` returns once someone waits.
private actor Gate {
    private var isOpen = false, arrivedCount = 0
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

private struct GatedDeviceVoice: VoiceProvider {
    let gate: Gate
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        await gate.wait()
        return VoiceArtifact(data: Data("device".utf8), durationSeconds: 1, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

/// Cache that records every key the renderer looks up or writes.
private actor KeyRecordingCache: AudioCache {
    let inner = InMemoryAudioCache()
    private(set) var touched: [String] = []
    func audio(for key: String) async -> CachedAudio? { touched.append(key); return await inner.audio(for: key) }
    func store(_ audio: CachedAudio, for key: String) async { touched.append(key); await inner.store(audio, for: key) }
    func purge(sourceItemIDs: Set<UUID>) async { await inner.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await inner.purgeExpired() }
    func purgeAllPersonal() async { await inner.purgeAllPersonal() }
    func seed(_ audio: CachedAudio, for key: String) async { await inner.store(audio, for: key) }
    var clipCount: Int { get async { await inner.count } }
}

final class PerCueLocalOnlyRoutingTests: XCTestCase {
    private let personalText = "From your calendar: dentist at 3 with Dr. Example."

    private func personalCue(_ item: UUID = UUID(), source: ContextSourceKind = .calendar) -> NarrationCue {
        NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent, text: personalText,
                     estimatedSeconds: 4, maxSeconds: 20, sourceItemID: item, source: source, provenance: "test:item")
    }

    private func transitionCue(_ text: String = "That was Song 1 by Artist 1.") -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
    }

    private func cloudRoute(_ spy: OffDeviceSpy) -> VoiceRoute {
        VoiceRoute(providerID: "cloud", provider: spy, voice: djVoice, leavesDevice: true)
    }

    private func deviceRoute(_ provider: any VoiceProvider = DJFakeVoice()) -> VoiceRoute {
        VoiceRoute(providerID: "device", provider: provider, voice: djVoice)
    }

    private func renderer(_ routes: [VoiceRoute], cache: any AudioCache = InMemoryAudioCache(),
                          revocations: NarrationRevocations = NarrationRevocations()) -> VoiceRenderer {
        VoiceRenderer(routes: routes, budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache, revocations: revocations)
    }

    private func outcome(_ preparer: DJBreakPreparer, afterTrack k: Int) async -> DJBreakOutcome {
        while true {
            if let result = await preparer.testResult(afterTrack: k) { return result }
            await Task.yield()
        }
    }

    // 1. Catalog-only station (onDeviceOnly: false), approved personal briefing cue, off-device spy first.
    func testCatalogStationPersonalBriefingCueNeverReachesTheOffDeviceSpy() async {
        let spy = OffDeviceSpy()
        let preparer = DJBreakPreparer(renderer: renderer([cloudRoute(spy), deviceRoute()]), userID: "u", stationID: "s")
        let item = UUID()
        let cue = personalCue(item)
        let djBreak = DJBreak(afterTrack: 0, cues: [cue],
                              attributions: [cue.id: .personalContext(itemID: item, source: .calendar, provenance: "test:item")])
        await preparer.prepare(djBreak, deadline: .seconds(10), onDeviceOnly: false)
        let result = await outcome(preparer, afterTrack: 0)
        XCTAssertTrue(spy.received.isEmpty, "personal cue text reached an off-device route")
        guard case .ready(let prepared) = result else { return XCTFail("the on-device route should speak it: \(result)") }
        XCTAssertEqual(prepared.clips.map(\.audio.providerID), ["device"])
    }

    // 1b. In a mixed break, presenter/metadata lines may go off-device; the personal line may not.
    func testMixedBreakSendsOnlyTheNonPersonalLinesOffDevice() async {
        let spy = OffDeviceSpy()
        let preparer = DJBreakPreparer(renderer: renderer([cloudRoute(spy), deviceRoute()]), userID: "u", stationID: "s")
        let item = UUID()
        let lead = transitionCue("Here's what's coming up today.")
        let cue = personalCue(item)
        let intro = transitionCue("Next up, Song 2 by Artist 2.")
        let djBreak = DJBreak(afterTrack: 0, cues: [lead, cue, intro],
                              attributions: [lead.id: .presenter,
                                             cue.id: .personalContext(itemID: item, source: .calendar, provenance: "test:item"),
                                             intro.id: .trackMetadata(trackIDs: ["t2"])])
        await preparer.prepare(djBreak, deadline: .seconds(10), onDeviceOnly: false)
        let result = await outcome(preparer, afterTrack: 0)
        XCTAssertFalse(spy.received.contains { $0.contains("dentist") }, "personal cue text reached an off-device route")
        XCTAssertEqual(spy.received.count, 2)
        guard case .ready(let prepared) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(prepared.clips.map(\.audio.providerID), ["cloud", "device", "cloud"])
    }

    // 2. Missing attribution: local only, on the direct path, the handoff path and the break path.
    func testMissingAttributionIsLocalOnly() async {
        let spy = OffDeviceSpy()
        let r = renderer([cloudRoute(spy), deviceRoute()])
        let cue = transitionCue()
        let direct = await r.render(cue, userID: "u", stationID: "s")
        XCTAssertEqual(try? direct.get().audio.providerID, "device")
        let handoff = await r.render(NarrationHandoff(cues: [transitionCue("Good morning.")], maxSpokenSeconds: 60,
                                                      experienceSeconds: 600), userID: "u", stationID: "s")
        XCTAssertEqual(handoff.clips.values.map(\.audio.providerID), ["device"])

        let preparer = DJBreakPreparer(renderer: r, userID: "u", stationID: "s")
        let unattributed = transitionCue("Another line.")
        await preparer.prepare(DJBreak(afterTrack: 0, cues: [unattributed], attributions: [:]),
                               deadline: .seconds(10), onDeviceOnly: false)
        guard case .ready(let prepared) = await outcome(preparer, afterTrack: 0) else { return XCTFail("should speak on-device") }
        XCTAssertEqual(prepared.clips.map(\.audio.providerID), ["device"])
        XCTAssertTrue(spy.received.isEmpty, "a cue with no attribution reached an off-device route")
    }

    // 3. Control: an attributed, generic metadata or presenter line may use the off-device route.
    func testGenericMetadataAndPresenterCuesMayUseTheOffDeviceRoute() async {
        let spy = OffDeviceSpy()
        let r = renderer([cloudRoute(spy), deviceRoute()])
        let meta = await r.render(transitionCue(), userID: "u", stationID: "s", attribution: .trackMetadata(trackIDs: ["t1"]))
        XCTAssertEqual(try? meta.get().audio.providerID, "cloud")
        let presenter = await r.render(transitionCue("Good afternoon."), userID: "u", stationID: "s", attribution: .presenter)
        XCTAssertEqual(try? presenter.get().audio.providerID, "cloud")
        XCTAssertEqual(spy.received.count, 2)
    }

    // 4. Personal cue, only off-device routes: fails closed, spy never called, nothing cached.
    func testPersonalCueWithOnlyOffDeviceRoutesFailsClosed() async {
        let spy = OffDeviceSpy()
        let cache = KeyRecordingCache()
        let r = renderer([cloudRoute(spy)], cache: cache)
        let item = UUID()
        let result = await r.render(personalCue(item), userID: "u", stationID: "s",
                                    attribution: .personalContext(itemID: item, source: .calendar, provenance: "test:item"))
        guard case .failure(let f) = result else { return XCTFail("must fail closed, never fall back to cloud") }
        XCTAssertEqual(f.reason, .renderFailed)
        XCTAssertEqual(f.attempts, [VoiceAttempt(providerID: "cloud", result: .failed(VoiceRenderer.localOnlySkip))])
        XCTAssertFalse(f.attempts.contains { "\($0)".contains("dentist") }, "attempt details never carry cue text")
        XCTAssertTrue(spy.received.isEmpty)
        let touched = await cache.touched, clips = await cache.clipCount
        XCTAssertTrue(touched.isEmpty, "no cache key was derived for an off-device route")
        XCTAssertEqual(clips, 0)

        // Through the break path: skipped as renderFailed, not spoken anywhere.
        let preparer = DJBreakPreparer(renderer: renderer([cloudRoute(spy)]), userID: "u", stationID: "s")
        let cue = personalCue(item)
        await preparer.prepare(DJBreak(afterTrack: 0, cues: [cue],
                                       attributions: [cue.id: .personalContext(itemID: item, source: .calendar, provenance: "p")]),
                               deadline: .seconds(10), onDeviceOnly: false)
        let outcome = await outcome(preparer, afterTrack: 0)
        XCTAssertEqual(outcome, .skipped(.renderFailed))
        XCTAssertTrue(spy.received.isEmpty)
    }

    // 4b. Echo: a paid route built without `leavesDevice` is not local. A personal cue never
    // reaches it, reserves no budget, derives no cache key; with only that route it fails closed.
    func testPaidRouteWithoutLeavesDeviceNeverHearsAPersonalCue() async {
        let spy = OffDeviceSpy()
        let paid = VoiceRoute(providerID: "paid", provider: spy, voice: djVoice,
                              microdollarsPerThousandCharacters: 30_000, leavesDevice: false)
        XCTAssertFalse(paid.leavesDevice)
        XCTAssertFalse(paid.isLocalAndFree)
        let budget = VoiceBudget(dailyCapMicrodollars: 1_000_000)
        let cache = KeyRecordingCache()
        let device = deviceRoute()
        let r = VoiceRenderer(routes: [paid, device], budget: budget, cache: cache, revocations: NarrationRevocations())
        let item = UUID()
        let attribution = SpokenAttribution.personalContext(itemID: item, source: .calendar, provenance: "test:item")
        let result = await r.render(personalCue(item), userID: "u", stationID: "s", attribution: attribution)
        guard case .success(let clip) = result else { return XCTFail("the local, free route should speak it") }
        XCTAssertEqual(clip.audio.providerID, "device")
        XCTAssertEqual(clip.attempts.first, VoiceAttempt(providerID: "paid", result: .failed(VoiceRenderer.localOnlySkip)))
        XCTAssertTrue(spy.received.isEmpty, "personal cue text reached a paid route")
        let spent = await budget.committed(userID: "u")
        XCTAssertEqual(spent, 0, "no reservation for a skipped paid route")
        let touched = await cache.touched
        XCTAssertFalse(touched.contains(VoiceRenderer.cacheKey(text: SpeechDelivery.speakable(personalText), route: paid)))

        let paidOnly = VoiceRenderer(routes: [paid], budget: budget, cache: InMemoryAudioCache(), revocations: NarrationRevocations())
        let closed = await paidOnly.render(personalCue(item), userID: "u", stationID: "s", attribution: attribution)
        guard case .failure(let f) = closed else { return XCTFail("must fail closed, never fall back to a paid voice") }
        XCTAssertEqual(f.reason, .renderFailed)
        XCTAssertTrue(spy.received.isEmpty)

        // Control: an eligible generic line may still use the paid route.
        let generic = await r.render(transitionCue(), userID: "u", stationID: "s", attribution: .trackMetadata(trackIDs: ["t1"]))
        XCTAssertEqual(try? generic.get().audio.providerID, "paid")
    }

    // 5a. An attribution that disagrees with the cue (sourced cue labelled presenter) is local-only.
    func testSourcedCueMislabelledAsPresenterStaysLocal() async {
        for source in [ContextSourceKind.calendar, .userShared, .obsidian, .emailShared, .messagesShared] {
            let spy = OffDeviceSpy()
            let r = renderer([cloudRoute(spy), deviceRoute()])
            let result = await r.render(personalCue(source: source), userID: "u", stationID: "s", attribution: .presenter)
            XCTAssertEqual(try? result.get().audio.providerID, "device", "\(source)")
            XCTAssertTrue(spy.received.isEmpty, "\(source) text reached an off-device route")
        }
        // A non-transition briefing framing line (opener/closer) is not eligible either.
        let opener = NarrationCue(id: UUID(), order: 0, group: 0, kind: .opener, text: "Here's your morning.",
                                  estimatedSeconds: 2, maxSeconds: 10, sourceItemID: nil, source: nil, provenance: nil)
        XCTAssertFalse(VoiceRenderer.mayLeaveDevice(opener, attribution: .presenter))
        XCTAssertFalse(VoiceRenderer.mayLeaveDevice(transitionCue(), attribution: nil))
        XCTAssertTrue(VoiceRenderer.mayLeaveDevice(transitionCue(), attribution: .presenter))
    }

    // 5b. Cache isolation: a clip already stored under the off-device key for the same text is
    // never looked up or returned for a local-only cue; only device-route keys are touched.
    func testLocalOnlyCueNeverTouchesTheOffDeviceCacheKey() async {
        let spy = OffDeviceSpy()
        let cache = KeyRecordingCache()
        let cloud = cloudRoute(spy), device = deviceRoute()
        let cloudKey = VoiceRenderer.cacheKey(text: SpeechDelivery.speakable(personalText), route: cloud)
        await cache.seed(CachedAudio(data: Data("cloud".utf8), seconds: 1, providerID: "cloud", voiceID: djVoice.id), for: cloudKey)
        let r = renderer([cloud, device], cache: cache)
        let item = UUID()
        let result = await r.render(personalCue(item), userID: "u", stationID: "s",
                                    attribution: .personalContext(itemID: item, source: .calendar, provenance: "test:item"))
        guard case .success(let clip) = result else { return XCTFail("on-device route should speak it") }
        XCTAssertEqual(clip.audio.providerID, "device")
        XCTAssertNotEqual(clip.cacheKey, cloudKey)
        let touched = await cache.touched
        XCTAssertFalse(touched.contains(cloudKey), "the off-device route's cache key was used for a local-only cue")
        XCTAssertEqual(Set(touched), [VoiceRenderer.cacheKey(text: SpeechDelivery.speakable(personalText), route: device)])
        XCTAssertTrue(spy.received.isEmpty)
    }

    // 5c. Revocation during the on-device render: fails closed, nothing cached, and the cloud
    // route is never tried as a fallback.
    func testRevocationMidRenderFailsClosedWithoutCloudFallback() async {
        let spy = OffDeviceSpy()
        let gate = Gate()
        let cache = InMemoryAudioCache()
        let revocations = NarrationRevocations()
        let r = renderer([cloudRoute(spy), deviceRoute(GatedDeviceVoice(gate: gate))], cache: cache, revocations: revocations)
        let item = UUID()
        let cue = personalCue(item)
        let render = Task {
            await r.render(cue, userID: "u", stationID: "s",
                           attribution: .personalContext(itemID: item, source: .calendar, provenance: "test:item"))
        }
        await gate.arrived()
        await NarrationPurger(cache: cache, preparer: nil, revocations: revocations).purge(sourceItemIDs: [item])
        await gate.open()
        let result = await render.value
        guard case .failure(let f) = result else { return XCTFail("a revoked item's render must not succeed") }
        XCTAssertEqual(f.attempts.last?.result, .cancelled)
        XCTAssertTrue(spy.received.isEmpty, "revocation must not fall back to an off-device route")
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }
}
