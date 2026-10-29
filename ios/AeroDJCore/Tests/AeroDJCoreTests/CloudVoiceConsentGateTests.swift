import XCTest
@testable import AeroDJCore

// Cloud-voice consent gate (docs/privacy/disclosure-copy.md §1, #174). The renderer reads the
// stored consent per cue, before any cache lookup, budget reservation or provider call. All
// providers are in-process fakes: no network, no paid service. -Nova

/// Off-device spy: records every text it receives, then renders it.
private final class CloudSpy: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var onSynthesize: (@Sendable () -> Void)?
    var received: [String] { lock.withLock { texts } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        onSynthesize?()
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

private actor RecordingCache: AudioCache {
    let inner = InMemoryAudioCache()
    private(set) var touched: [String] = []
    func audio(for key: String) async -> CachedAudio? { touched.append(key); return await inner.audio(for: key) }
    func store(_ audio: CachedAudio, for key: String) async { touched.append(key); await inner.store(audio, for: key) }
    func purge(sourceItemIDs: Set<UUID>) async { await inner.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await inner.purgeExpired() }
    func purgeAllPersonal() async { await inner.purgeAllPersonal() }
}

final class CloudVoiceConsentGateTests: XCTestCase {
    private func transitionCue(_ text: String = "That was Song 1 by Artist 1.") -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
    }

    private func routes(_ spy: CloudSpy) -> [VoiceRoute] {
        [VoiceRoute(providerID: "cloud", provider: spy, voice: djVoice,
                    microdollarsPerThousandCharacters: 30_000, leavesDevice: true),
         VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)]
    }

    private func renderer(_ spy: CloudSpy, consent: CloudVoiceConsentStore,
                          cache: any AudioCache = InMemoryAudioCache(),
                          budget: VoiceBudget = VoiceBudget(dailyCapMicrodollars: 1_000_000)) -> VoiceRenderer {
        VoiceRenderer(routes: routes(spy), budget: budget, cache: cache, cloudConsent: consent)
    }

    // 1. No consent: no remote render. The text never reaches the cloud route, its cache keys or
    //    budget, and the on-device voice speaks the line (music never waits on the cloud).
    func testNoConsentMeansNoRemoteRender() async throws {
        for consent in [CloudVoiceConsentStore.inMemory(.undecided), .inMemory(.declined)] {
            let spy = CloudSpy()
            let cache = RecordingCache()
            let budget = VoiceBudget(dailyCapMicrodollars: 1_000_000)
            let r = renderer(spy, consent: consent, cache: cache, budget: budget)
            let clip = try await r.render(transitionCue(), userID: "u", stationID: "s", attribution: .presenter).get()
            XCTAssertEqual(clip.audio.providerID, "device")
            XCTAssertTrue(spy.received.isEmpty, "script text left the device without consent")
            let keys = await cache.touched
            XCTAssertFalse(keys.contains { $0.contains("cloud") }, "cloud cache key touched without consent: \(keys)")
            XCTAssertEqual(clip.attempts.first?.result, .failed(VoiceRenderer.noConsentSkip))
            let spent = await budget.committed(userID: "u")
            XCTAssertEqual(spent, 0)
        }
    }

    // 1b. A paid route not marked leavesDevice is gated too (paid voices are third-party).
    func testNoConsentAlsoSkipsAPaidRouteNotMarkedLeavesDevice() async throws {
        let spy = CloudSpy()
        let r = VoiceRenderer(routes: [VoiceRoute(providerID: "paid", provider: spy, voice: djVoice,
                                                  microdollarsPerThousandCharacters: 30_000),
                                       VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                              budget: VoiceBudget(dailyCapMicrodollars: 1_000_000), cache: InMemoryAudioCache(),
                              cloudConsent: .inMemory())
        let clip = try await r.render(transitionCue(), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(clip.audio.providerID, "device")
        XCTAssertTrue(spy.received.isEmpty)
    }

    // 2. Consent: the existing path, unchanged (eligible cue goes to the cloud route first).
    func testConsentUsesTheExistingCloudPath() async throws {
        let spy = CloudSpy()
        let r = renderer(spy, consent: .inMemory(.accepted))
        let clip = try await r.render(transitionCue(), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(clip.audio.providerID, "cloud")
        XCTAssertEqual(spy.received.count, 1)
        // The #176 per-cue gate still applies on top: an unattributed cue stays local.
        let local = try await r.render(transitionCue("Good morning."), userID: "u", stationID: "s").get()
        XCTAssertEqual(local.audio.providerID, "device")
        XCTAssertEqual(spy.received.count, 1)
    }

    // 3. Revoking takes effect on the very next render, with no new renderer or relaunch.
    func testRevokeTakesEffectImmediately() async throws {
        let consent = CloudVoiceConsentStore.inMemory(.accepted)
        let spy = CloudSpy()
        let r = renderer(spy, consent: consent)
        let first = try await r.render(transitionCue("One."), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(first.audio.providerID, "cloud")
        consent.decline()
        let second = try await r.render(transitionCue("Two."), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(second.audio.providerID, "device")
        XCTAssertEqual(spy.received.count, 1)
        // Accepting again applies at once too.
        consent.accept()
        let third = try await r.render(transitionCue("Three."), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(third.audio.providerID, "cloud")
    }

    // 3b. Revoked while a cloud request is in flight: the cloud clip is dropped, never cached or
    //     played, and the on-device voice speaks the line.
    func testRevokeMidRenderDropsTheCloudClip() async throws {
        let consent = CloudVoiceConsentStore.inMemory(.accepted)
        let spy = CloudSpy()
        spy.onSynthesize = { consent.decline() }
        let cache = InMemoryAudioCache()
        let r = renderer(spy, consent: consent, cache: cache)
        let clip = try await r.render(transitionCue(), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(clip.audio.providerID, "device")
        XCTAssertTrue(clip.attempts.contains { $0.result == .failed(VoiceRenderer.consentRevokedDiscard) })
        let count = await cache.count
        XCTAssertEqual(count, 1, "only the on-device clip is cached")
    }

    // 4. Pre-consent state is fail-closed: a fresh store, a default renderer, unknown or stale
    //    stored values all read as not granted.
    func testPreConsentStateIsFailClosed() async throws {
        XCTAssertEqual(CloudVoiceConsentStore.inMemory().state, .undecided)
        XCTAssertFalse(CloudVoiceConsentStore.inMemory().isGranted)

        let suite = "CloudVoiceConsentGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudVoiceConsentStore(defaults: defaults)
        XCTAssertEqual(store.state, .undecided)
        defaults.set("maybe", forKey: CloudVoiceConsentStore.stateKey)
        XCTAssertFalse(store.isGranted, "unknown value must not grant")
        defaults.set("accepted", forKey: CloudVoiceConsentStore.stateKey)
        defaults.set(CloudVoiceConsentStore.currentVersion - 1, forKey: CloudVoiceConsentStore.versionKey)
        XCTAssertEqual(store.state, .undecided, "an older copy version must ask again")
        store.accept()
        XCTAssertTrue(CloudVoiceConsentStore(defaults: defaults).isGranted, "persists across store instances")
        store.decline()
        XCTAssertEqual(CloudVoiceConsentStore(defaults: defaults).state, .declined)

        // A renderer built without naming consent uses the persisted store: in a clean test
        // process that is undecided, so the cloud route is skipped.
        let spy = CloudSpy()
        let unnamed = VoiceRenderer(routes: routes(spy), budget: VoiceBudget(dailyCapMicrodollars: 1_000_000),
                                    cache: InMemoryAudioCache(),
                                    cloudConsent: CloudVoiceConsentStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite + ".empty"))))
        let clip = try await unnamed.render(transitionCue(), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(clip.audio.providerID, "device")
        XCTAssertTrue(spy.received.isEmpty)
        // Narrowed views keep the gate.
        XCTAssertEqual(unnamed.lastRouteOnly?.cloudConsent.isGranted, false)
        XCTAssertEqual(unnamed.onDeviceOnly?.cloudConsent.isGranted, false)
    }

    func testPromptShowsOnlyWhenACloudVoiceIsOfferedAndUnanswered() {
        XCTAssertTrue(CloudVoiceConsentPrompt.isCloudVoiceOffered(paidProvidersEnabled: true, selectedVoiceID: "v"))
        XCTAssertFalse(CloudVoiceConsentPrompt.isCloudVoiceOffered(paidProvidersEnabled: false, selectedVoiceID: "v"))
        XCTAssertFalse(CloudVoiceConsentPrompt.isCloudVoiceOffered(paidProvidersEnabled: true, selectedVoiceID: nil))
        XCTAssertTrue(CloudVoiceConsentPrompt.shouldPresent(cloudVoiceOffered: true, state: .undecided))
        XCTAssertFalse(CloudVoiceConsentPrompt.shouldPresent(cloudVoiceOffered: true, state: .accepted))
        XCTAssertFalse(CloudVoiceConsentPrompt.shouldPresent(cloudVoiceOffered: true, state: .declined))
        XCTAssertFalse(CloudVoiceConsentPrompt.shouldPresent(cloudVoiceOffered: false, state: .undecided))
    }

    func testCopyNamesTheAppThroughTheSingleConstant() {
        XCTAssertEqual(AppName.display, "OnAirly")
        XCTAssertTrue(CloudVoiceConsentCopy.intro.contains("OnAirly sends the words"))
        XCTAssertFalse(CloudVoiceConsentCopy.intro.contains("AeroDJ"))
        for line in [CloudVoiceConsentCopy.sent, CloudVoiceConsentCopy.neverSent, CloudVoiceConsentCopy.stored, CloudVoiceConsentCopy.footer] {
            XCTAssertFalse(line.contains("["), "owner placeholder leaked into copy: \(line)")
        }
    }
}
