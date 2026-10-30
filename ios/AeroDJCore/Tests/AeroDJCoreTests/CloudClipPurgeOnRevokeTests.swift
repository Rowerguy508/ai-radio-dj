import XCTest
@testable import AeroDJCore

// N4 (Fry on #258): revoking cloud-voice consent deletes cached cloud clips, so a later render
// (or a re-grant) never replays cloud audio from cache. On-device clips stay. Fakes only: no
// network, no paid service. -Nova

private final class CloudCounter: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var calls: Int { lock.withLock { n } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { n += 1 }
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

@MainActor private final class Calls { var log: [String] = [] }

@MainActor
final class CloudClipPurgeOnRevokeTests: XCTestCase {
    private func clip(_ provider: String) -> CachedAudio {
        CachedAudio(data: Data([1]), seconds: 1, providerID: provider, voiceID: "v")
    }

    private func cue() -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "That was Song 1 by Artist 1.",
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
    }

    private func renderer(_ cloud: CloudCounter, cache: any AudioCache, consent: CloudVoiceConsentStore) -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice,
                                          microdollarsPerThousandCharacters: 30_000, leavesDevice: true),
                               VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 1_000_000), cache: cache, cloudConsent: consent)
    }

    func testInMemoryCacheKeepsOnlyTheNamedProviders() async {
        let cache = InMemoryAudioCache()
        await cache.store(clip("cloud"), for: "a")
        await cache.store(clip("paid"), for: "b")
        await cache.store(clip("device"), for: "c")
        await cache.purgeClips(keepingProviders: ["device"])
        let a = await cache.audio(for: "a"), b = await cache.audio(for: "b"), c = await cache.audio(for: "c")
        XCTAssertNil(a); XCTAssertNil(b)
        XCTAssertEqual(c?.providerID, "device")
    }

    func testFileCacheKeepsOnlyTheNamedProvidersAndDropsUnattributableFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("n4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FileAudioCache(directory: dir)
        await cache.store(clip("cloud"), for: "a")
        await cache.store(clip("device"), for: "c")
        try Data([0]).write(to: dir.appendingPathComponent("orphan.caf"))   // no metadata: cannot be attributed
        await cache.purgeClips(keepingProviders: ["device"])
        let a = await cache.audio(for: "a"), c = await cache.audio(for: "c")
        XCTAssertNil(a)
        XCTAssertEqual(c?.providerID, "device")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("orphan.caf").path))
    }

    func testRendererPurgeKeepsItsOnDeviceRoutesOnly() async {
        let cache = InMemoryAudioCache()
        await cache.store(clip("cloud"), for: "a")
        await cache.store(clip("device"), for: "c")
        await renderer(CloudCounter(), cache: cache, consent: .inMemory(.accepted)).purgeCloudClips()
        let a = await cache.audio(for: "a"), c = await cache.audio(for: "c")
        XCTAssertNil(a)
        XCTAssertNotNil(c)
    }

    func testRevokePurgesBeforeItNotifiesAndGrantDoesNot() async {
        let store = CloudVoiceConsentStore.inMemory()
        let calls = Calls()
        let signals = PaidVoiceConsentSignals(store: store, notify: { calls.log.append("notify") },
                                              purgeCloudAudio: { calls.log.append("purge") })
        await signals.accept()?.value
        XCTAssertEqual(calls.log, ["notify"], "a grant does not purge")
        await signals.decline()?.value
        XCTAssertEqual(calls.log, ["notify", "purge", "notify"], "a revoke purges, then notifies")
        XCTAssertNil(signals.decline(), "declining again is no change: no purge")
        XCTAssertEqual(calls.log.filter { $0 == "purge" }.count, 1)
    }

    func testDecliningWhenNeverGrantedDoesNotPurge() async {
        let calls = Calls()
        let signals = PaidVoiceConsentSignals(store: .inMemory(), notify: {}, purgeCloudAudio: { calls.log.append("purge") })
        XCTAssertNil(signals.decline())
        XCTAssertTrue(calls.log.isEmpty)
    }

    /// End to end: a cloud clip cached while granted is gone after a revoke, so after a
    /// re-grant the same line is rendered again by the cloud provider, not replayed from cache.
    func testARevokedCloudClipIsNotReplayedFromCache() async throws {
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let cloud = CloudCounter()
        let cache = InMemoryAudioCache()
        let r = renderer(cloud, cache: cache, consent: store)
        let line = cue()
        let first = try await r.render(line, userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(first.audio.providerID, "cloud")
        let cached = try await r.render(line, userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(cached.attempts.last?.result, .cacheHit, "cached while granted")
        XCTAssertEqual(cloud.calls, 1)

        let signals = PaidVoiceConsentSignals(store: store, notify: {}, purgeCloudAudio: { await r.purgeCloudClips() })
        await signals.decline()?.value
        let count = await cache.count
        XCTAssertEqual(count, 0, "the cloud clip is deleted on revoke")

        await signals.accept()?.value
        let again = try await r.render(line, userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(again.attempts.last?.result, .rendered, "rendered fresh, not from cache")
        XCTAssertEqual(cloud.calls, 2)
    }

    /// The default purge reaches the registered renderer (AppDependencies.live() sets it).
    func testDefaultPurgeGoesThroughTheRelay() async {
        let cache = InMemoryAudioCache()
        await cache.store(clip("cloud"), for: "a")
        let r = renderer(CloudCounter(), cache: cache, consent: .inMemory(.accepted))
        PaidVoiceAccessRelay.purgeCloudAudio = { await r.purgeCloudClips() }
        defer { PaidVoiceAccessRelay.purgeCloudAudio = nil }
        await PaidVoiceConsentSignals(store: .inMemory(.accepted), notify: {}).decline()?.value
        let a = await cache.audio(for: "a")
        XCTAssertNil(a)
    }
}
