import XCTest
@testable import AeroDJCore

// P2(b): a purge that lands while a voice render is in flight must win, at the cache-write
// boundary. Deterministic: barriers, no sleeps. -Fry

/// One-shot barrier: `wait()` suspends until `open()`; `arrived()` reports the first waiter.
private actor Barrier {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var arrivedCount = 0
    func wait() async {
        arrivedCount += 1
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    /// Returns once someone has reached `wait()`.
    func arrived() async {
        if arrivedCount > 0 { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
}

/// Device voice that blocks inside synthesis until the test opens the barrier.
private struct BlockingVoice: VoiceProvider {
    let barrier: Barrier
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        await barrier.wait()
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: 2, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

/// Cache whose `store` blocks before writing, after the renderer's pre-write check.
private actor BlockingStoreCache: AudioCache {
    let inner = InMemoryAudioCache()
    let barrier: Barrier
    init(barrier: Barrier) { self.barrier = barrier }
    func audio(for key: String) async -> CachedAudio? { await inner.audio(for: key) }
    func store(_ audio: CachedAudio, for key: String) async {
        await barrier.wait()
        await inner.store(audio, for: key)
    }
    func purge(sourceItemIDs: Set<UUID>) async { await inner.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await inner.purgeExpired() }
    func clips() async -> Int { await inner.count }
}

final class InFlightRenderRevocationTests: XCTestCase {
    private func cue(_ id: UUID) -> NarrationCue {
        NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "From your notes: water the plants.",
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: id, source: .obsidian, provenance: "test:n1")
    }

    func testPurgeDuringSynthesisLeavesNothingCachedOrReturned() async {
        let item = UUID()
        let gate = Barrier()
        let cache = InMemoryAudioCache()
        let revocations = NarrationRevocations()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: BlockingVoice(barrier: gate), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache, revocations: revocations)
        let c = cue(item)
        let render = Task { await renderer.render(c, userID: "u", stationID: "s") }
        await gate.arrived()                              // synthesis is in flight
        await NarrationPurger(cache: cache, preparer: nil, revocations: revocations).purge(sourceItemIDs: [item])
        await gate.open()
        let result = await render.value
        guard case .failure(let f) = result else { return XCTFail("a revoked item's render must not succeed") }
        XCTAssertEqual(f.attempts.last?.result, .cancelled)
        let count = await cache.count
        XCTAssertEqual(count, 0, "nothing cached for the revoked item")
    }

    func testPurgeBetweenPreWriteCheckAndCacheStoreIsUndoneAtTheWriteBoundary() async {
        let item = UUID()
        let synth = Barrier(); await synth.open()          // synthesis returns immediately
        let storeGate = Barrier()
        let cache = BlockingStoreCache(barrier: storeGate)
        let revocations = NarrationRevocations()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: BlockingVoice(barrier: synth), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache, revocations: revocations)
        let c = cue(item)
        let render = Task { await renderer.render(c, userID: "u", stationID: "s") }
        await storeGate.arrived()                         // past the pre-write check, write not yet done
        await NarrationPurger(cache: cache, preparer: nil, revocations: revocations).purge(sourceItemIDs: [item])
        await storeGate.open()                            // the stale write now lands after the purge
        let result = await render.value
        guard case .failure = result else { return XCTFail("a revoked item's render must not succeed") }
        let count = await cache.clips()
        XCTAssertEqual(count, 0, "the write that raced the purge was removed")
    }

    func testReapprovalAfterPurgeRendersAndCachesAgain() async {
        let item = UUID()
        let open = Barrier(); await open.open()
        let cache = InMemoryAudioCache()
        let revocations = NarrationRevocations()
        revocations.revoke([item])                         // purged earlier, then re-approved
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: BlockingVoice(barrier: open), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache, revocations: revocations)
        let result = await renderer.render(cue(item), userID: "u", stationID: "s")
        guard case .success = result else { return XCTFail("an old tombstone must not block a new render") }
        let count = await cache.count
        XCTAssertEqual(count, 1)
    }
}
