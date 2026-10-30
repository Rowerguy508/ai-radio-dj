import XCTest
@testable import AeroDJCore

// Fry's #258 blocker / Sentinel's ask: a cloud clip whose render overlaps a consent revoke or a
// cache purge is never stored. The cache keeps a consent generation, bumped by every purge; the
// renderer reads it when the render starts, and the write is an atomic check-and-store under the
// same lock (or actor turn) as the purge. Run against both shipping caches. Fakes only: no
// network, no paid service, no sleeps. -Nova

/// Cloud voice that runs `during` inside synthesis, before it returns (a revoke mid-render).
private final class HookedCloud: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var hook: (@Sendable () async -> Void)?
    private var n = 0
    var calls: Int { lock.withLock { n } }
    func during(_ h: @escaping @Sendable () async -> Void) { lock.withLock { hook = h } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let h = lock.withLock { n += 1; let h = hook; hook = nil; return h }
        await h?()
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

/// Wraps a shipping cache. `beforeWrite` runs once at the start of either store, after the
/// renderer's own post-synthesis consent check: a purge landing between render and write.
private actor WriteHookCache: AudioCache {
    let inner: any AudioCache
    private var beforeWrite: (@Sendable () async -> Void)?
    init(_ inner: any AudioCache) { self.inner = inner }
    func setBeforeWrite(_ h: @escaping @Sendable () async -> Void) { beforeWrite = h }
    private func runHook() async { let h = beforeWrite; beforeWrite = nil; await h?() }
    func audio(for key: String) async -> CachedAudio? { await inner.audio(for: key) }
    func store(_ audio: CachedAudio, for key: String) async { await runHook(); await inner.store(audio, for: key) }
    func store(_ audio: CachedAudio, for key: String, ifGeneration generation: UInt64,
               stillAllowed: @Sendable () -> Bool) async -> Bool {
        await runHook()
        return await inner.store(audio, for: key, ifGeneration: generation, stillAllowed: stillAllowed)
    }
    func consentGeneration() async -> UInt64 { await inner.consentGeneration() }
    func purge(sourceItemIDs: Set<UUID>) async { await inner.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await inner.purgeExpired() }
    func purgeAllPersonal() async { await inner.purgeAllPersonal() }
    func purgeClips(keepingProviders providerIDs: Set<String>) async { await inner.purgeClips(keepingProviders: providerIDs) }
}

final class CloudClipMidRenderPurgeTests: XCTestCase {
    private var dirs: [URL] = []
    override func tearDown() { dirs.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }

    /// One fresh in-memory cache and one fresh file cache.
    private func caches() -> [(name: String, cache: any AudioCache)] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("midrender-\(UUID().uuidString)")
        dirs.append(dir)
        return [("memory", InMemoryAudioCache()), ("file", FileAudioCache(directory: dir))]
    }

    private func cue() -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "That was Song 1 by Artist 1.",
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
    }

    private func renderer(_ cloud: HookedCloud, cache: any AudioCache, consent: CloudVoiceConsentStore) -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice,
                                          microdollarsPerThousandCharacters: 30_000, leavesDevice: true),
                               VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 1_000_000), cache: cache, cloudConsent: consent)
    }

    private func cloudKey(_ r: VoiceRenderer, _ line: NarrationCue) -> String {
        let route = r.routes[0]
        return VoiceRenderer.cacheKey(text: route.acceptsSSML ? SpeechDelivery.ssml(line.text) : SpeechDelivery.speakable(line.text),
                                      route: route)
    }

    /// No cloud clip in `cache`, the line was spoken on-device, and the cloud attempt says why.
    private func assertDropped(_ result: Result<RenderedClip, VoiceRenderer.Failure>, cache: any AudioCache,
                               key: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clip = try result.get()
        XCTAssertEqual(clip.audio.providerID, "device", "\(name): the on-device route speaks the line", file: file, line: line)
        XCTAssertEqual(clip.attempts.first?.result, .failed(VoiceRenderer.consentRevokedDiscard), "\(name)", file: file, line: line)
        let stored = await cache.audio(for: key)
        XCTAssertNil(stored, "\(name): no cloud clip survives", file: file, line: line)
    }

    /// Revoke (decline + the relay's purge) lands while the cloud voice is rendering.
    func testRevokeMidRenderLeavesNoClip() async throws {
        for (name, cache) in caches() {
            let consent = CloudVoiceConsentStore.inMemory(.accepted)
            let cloud = HookedCloud()
            let r = renderer(cloud, cache: cache, consent: consent)
            cloud.during { consent.decline(); await r.purgeCloudClips() }
            let line = cue()
            try await assertDropped(await r.render(line, userID: "u", stationID: "s", attribution: .presenter),
                                    cache: cache, key: cloudKey(r, line), name)
        }
    }

    /// Revoke, purge, then a re-grant, all while the cloud voice is rendering: consent reads
    /// granted again at the write, but the purge moved the generation, so the stale clip is dropped.
    func testPurgeThenRegrantMidRenderStillDropsTheStaleClip() async throws {
        for (name, cache) in caches() {
            let consent = CloudVoiceConsentStore.inMemory(.accepted)
            let cloud = HookedCloud()
            let r = renderer(cloud, cache: cache, consent: consent)
            cloud.during { consent.decline(); await r.purgeCloudClips(); consent.accept() }
            let line = cue()
            try await assertDropped(await r.render(line, userID: "u", stationID: "s", attribution: .presenter),
                                    cache: cache, key: cloudKey(r, line), name)
            XCTAssertTrue(consent.isGranted, "\(name): consent is granted again at the write")
        }
    }

    /// Fry's required case: the render has finished (its post-synthesis consent check passed) and
    /// the revoke and purge land before the write commits. The write is refused, not undone.
    func testPurgeBetweenRenderFinishingAndTheWriteStoresNothing() async throws {
        for (name, shipping) in caches() {
            let cache = WriteHookCache(shipping)
            let consent = CloudVoiceConsentStore.inMemory(.accepted)
            let r = renderer(HookedCloud(), cache: cache, consent: consent)
            await cache.setBeforeWrite { consent.decline(); await r.purgeCloudClips() }
            let line = cue()
            try await assertDropped(await r.render(line, userID: "u", stationID: "s", attribution: .presenter),
                                    cache: shipping, key: cloudKey(r, line), name)
        }
    }

    /// The same window with a purge and re-grant: consent is on at the write, the generation is not.
    func testPurgeAndRegrantBetweenRenderAndWriteStoresNothing() async throws {
        for (name, shipping) in caches() {
            let cache = WriteHookCache(shipping)
            let consent = CloudVoiceConsentStore.inMemory(.accepted)
            let r = renderer(HookedCloud(), cache: cache, consent: consent)
            await cache.setBeforeWrite { consent.decline(); await r.purgeCloudClips(); consent.accept() }
            let line = cue()
            try await assertDropped(await r.render(line, userID: "u", stationID: "s", attribution: .presenter),
                                    cache: shipping, key: cloudKey(r, line), name)
        }
    }

    /// Consent turned off between render and write with no purge yet: refused on consent alone.
    func testConsentOffAtTheWriteWithoutAPurgeStoresNothing() async throws {
        for (name, shipping) in caches() {
            let cache = WriteHookCache(shipping)
            let consent = CloudVoiceConsentStore.inMemory(.accepted)
            let r = renderer(HookedCloud(), cache: cache, consent: consent)
            await cache.setBeforeWrite { consent.decline() }
            let line = cue()
            try await assertDropped(await r.render(line, userID: "u", stationID: "s", attribution: .presenter),
                                    cache: shipping, key: cloudKey(r, line), name)
        }
    }

    /// No revoke: the cloud clip is rendered, cached, and replayed from cache, as before.
    func testRenderWithNoRevokeStillCaches() async throws {
        for (name, cache) in caches() {
            let cloud = HookedCloud()
            let r = renderer(cloud, cache: cache, consent: .inMemory(.accepted))
            let line = cue()
            let first = try await r.render(line, userID: "u", stationID: "s", attribution: .presenter).get()
            XCTAssertEqual(first.audio.providerID, "cloud", name)
            XCTAssertEqual(first.attempts.last?.result, .rendered, name)
            let stored = await cache.audio(for: cloudKey(r, line))
            XCTAssertEqual(stored?.providerID, "cloud", "\(name): cached")
            let again = try await r.render(line, userID: "u", stationID: "s", attribution: .presenter).get()
            XCTAssertEqual(again.attempts.last?.result, .cacheHit, name)
            XCTAssertEqual(cloud.calls, 1, name)
        }
    }

    // MARK: the caches' check-and-store

    private func clip() -> CachedAudio { CachedAudio(data: Data([1]), seconds: 1, providerID: "cloud", voiceID: "v") }

    func testEveryPurgeBumpsTheGenerationAndAStaleOrDisallowedWriteStoresNothing() async {
        for (name, cache) in caches() {
            let purges: [(String, () async -> Void)] = [
                ("purgeClips", { await cache.purgeClips(keepingProviders: ["device"]) }),
                ("purge(sourceItemIDs:)", { await cache.purge(sourceItemIDs: [UUID()]) }),
                ("purgeAllPersonal", { await cache.purgeAllPersonal() }),
                ("purgeExpired", { await cache.purgeExpired() }),
            ]
            for (purge, run) in purges {
                let before = await cache.consentGeneration()
                await run()
                let after = await cache.consentGeneration()
                XCTAssertNotEqual(before, after, "\(name): \(purge) bumps the generation")
                let stale = await cache.store(clip(), for: "k", ifGeneration: before, stillAllowed: { true })
                XCTAssertFalse(stale, "\(name): a write from before \(purge) is refused")
                let none = await cache.audio(for: "k")
                XCTAssertNil(none, "\(name): nothing stored after \(purge)")
            }
            let current = await cache.consentGeneration()
            let disallowed = await cache.store(clip(), for: "k", ifGeneration: current, stillAllowed: { false })
            XCTAssertFalse(disallowed, "\(name): consent off refuses the write")
            let none = await cache.audio(for: "k")
            XCTAssertNil(none, name)
            let ok = await cache.store(clip(), for: "k", ifGeneration: current, stillAllowed: { true })
            XCTAssertTrue(ok, name)
            let stored = await cache.audio(for: "k")
            XCTAssertNotNil(stored, "\(name): a current, allowed write stores")
        }
    }

    /// Two file caches on one directory share one lock and generation: a purge through one
    /// refuses a stale write through the other.
    func testFileCachesOnOneDirectoryShareTheGeneration() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("midrender-\(UUID().uuidString)")
        dirs.append(dir)
        let a = FileAudioCache(directory: dir), b = FileAudioCache(directory: dir)
        let before = await a.consentGeneration()
        await b.purgeClips(keepingProviders: [])
        let stale = await a.store(clip(), for: "k", ifGeneration: before, stillAllowed: { true })
        XCTAssertFalse(stale)
        let none = await a.audio(for: "k")
        XCTAssertNil(none)
    }
}
