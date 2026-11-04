import XCTest
@testable import AeroDJCore

// Follow-up to #398 (tester cloud-voice off switch): Sentinel's N2 with Fry's nit 2 (a cloud
// render in flight at the decline must not leave its clip cached), Echo's N1 (no time-check
// state left behind by the take-time drop), Echo's N2 (counts-only row for a cloud-voice drop),
// Fry's nits 1 and 3. In-process fakes only: no network, no paid service. -Nova

/// A plain cache that can say which providers it holds, and can hold a write open (`holdWrites`)
/// until the test lets it land, to stage a decline (and its purge) during a write.
private actor ProviderCache: AudioCache {
    private var clips: [String: CachedAudio] = [:]
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var writesStarted = 0

    var providers: [String] { clips.values.map(\.providerID).sorted() }
    func holdWrites() { holding = true }
    func releaseWrites() { holding = false; held.forEach { $0.resume() }; held = [] }

    func audio(for key: String) -> CachedAudio? { clips[key] }
    func store(_ audio: CachedAudio, for key: String) async {
        writesStarted += 1
        if holding { await withCheckedContinuation { held.append($0) } }
        clips[key] = audio
    }
    func purge(sourceItemIDs: Set<UUID>) { clips = clips.filter { Set($0.value.sourceItemIDs).isDisjoint(with: sourceItemIDs) } }
    func purgeExpired() {}
    func purgeAllPersonal() { clips = clips.filter { $0.value.sourceItemIDs.isEmpty } }
    func purgeClips(keepingProviders providerIDs: Set<String>) { clips = clips.filter { providerIDs.contains($0.value.providerID) } }
}

/// Off-device fake whose renders wait at a gate until `release()`, so a decline can land while
/// a cloud render is in flight. `started` counts renders that reached the gate.
private final class GatedCloud: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var reached = 0
    var started: Int { lock.withLock { reached } }
    func close() { lock.withLock { open = false } }
    func release() { lock.withLock { open = true } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { reached += 1 }
        while !lock.withLock({ open }) { try await Task.sleep(for: .milliseconds(2)) }
        return VoiceArtifact(data: Data("cloud:\(text)".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class DropLog: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [(Int, ExcludedCueCounts)] = []
    var all: [(Int, ExcludedCueCounts)] { lock.withLock { rows } }
    func add(_ k: Int, _ c: ExcludedCueCounts) { lock.withLock { rows.append((k, c)) } }
}

final class TesterVoiceOffNitsTests: XCTestCase {
    private var made: [DJBreakPreparer] = []

    override func tearDown() async throws {
        for p in made { await p.cancelAll() }
        made = []
        try await super.tearDown()
    }

    private struct Rig {
        let preparer: DJBreakPreparer
        let consent: CloudVoiceConsentStore
        let cloud: GatedCloud
        let cache: ProviderCache
        let renderer: VoiceRenderer
    }

    private func rig(sleepUntil: (@Sendable (ContinuousClock.Instant) async throws -> Void)? = nil) -> Rig {
        let cloud = GatedCloud(), cache = ProviderCache()
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice, leavesDevice: true),
                                              VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache,
                                     revocations: NarrationRevocations())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", talkOverEnabled: { true },
                                       cloudVoiceConsent: { @Sendable in store.isGranted }, sleepUntil: sleepUntil)
        made.append(preparer)
        return Rig(preparer: preparer, consent: store, cloud: cloud, cache: cache, renderer: renderer)
    }

    private func line(_ text: String, order: Int = 0, kind: BriefingScriptSegment.Kind = .transition, source: UUID? = nil) -> NarrationCue {
        NarrationCue(id: UUID(), order: order, group: -1, kind: kind, text: text, estimatedSeconds: 3, maxSeconds: 20,
                     sourceItemID: source, source: nil, provenance: nil)
    }

    private func presenterBreak(afterTrack k: Int, _ text: String = "That was Song 1 by Artist 1.") -> DJBreak {
        let cue = line(text)
        return DJBreak(afterTrack: k, cues: [cue], attributions: [cue.id: .presenter])
    }

    private func outcome(_ p: DJBreakPreparer, afterTrack k: Int) async -> DJBreakOutcome? {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if let result = await p.testResult(afterTrack: k) { return result }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    private func eventually(_ check: @escaping @Sendable () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await check()
    }

    /// What the app does on a decline (`TesterCloudVoice.record(accepted: false)`): record it,
    /// then drop prepared cloud breaks and purge cached cloud clips through the launch renderer.
    private func decline(_ r: Rig) async {
        r.consent.decline()
        await r.preparer.dropCloudVoiceBreaks()
        await r.renderer.purgeCloudClips()
    }

    // MARK: 1. Sentinel's N2 / Fry's nit 2: a late cloud render's clip does not stay cached

    /// The render is still at the cloud provider when the listener declines; the decline's purge
    /// runs (nothing to purge yet); then the render finishes. Before this follow-up its clip was
    /// written after the purge and stayed on disk until the 7-day sweep.
    func testACloudRenderFinishingAfterTheDeclineLeavesNoClipAfterTheTakeTimeDrop() async {
        let r = rig()
        r.cloud.close()
        await r.preparer.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        let cloud = r.cloud
        let reached = await eventually { cloud.started == 1 }
        XCTAssertTrue(reached, "the cloud render is in flight")
        await decline(r)
        r.cloud.release()
        guard case .ready(let late)? = await outcome(r.preparer, afterTrack: 0) else { return XCTFail("the late render finishes") }
        XCTAssertEqual(late.clips.map(\.audio.providerID), ["cloud"])
        let taken = await r.preparer.takeBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked), "kept off air, as before")
        await r.preparer.testAwaitCloudClipPurge()
        let left = await r.cache.providers
        XCTAssertEqual(left, [], "no cloud clip stays in the cache")
    }

    /// The write itself is under way when the decline and its purge land (the purge runs first):
    /// the consent cache sees the decline once the write is done and purges again.
    func testACloudWriteInFlightAtTheDeclineIsPurgedOnceItLands() async {
        let base = ProviderCache()
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let cache = CloudVoiceConsentCache(base: base, localProviders: ["device"], isGranted: { @Sendable in store.isGranted })
        await base.holdWrites()
        let write = Task { await cache.store(CachedAudio(data: Data("c".utf8), seconds: 1, providerID: "cloud", voiceID: "host"), for: "k") }
        let started = await eventually { await base.writesStarted == 1 }
        XCTAssertTrue(started)
        store.decline()
        await base.purgeClips(keepingProviders: ["device"])   // the decline's purge, before the write lands
        await base.releaseWrites()
        await write.value
        let left = await base.providers
        XCTAssertEqual(left, [], "the clip written after the purge is purged again")
    }

    /// After the decline, a cloud clip is not written, not read back, and on-device clips are
    /// untouched. While consent is granted the cache is the base cache.
    func testTheConsentCacheOnlyGatesCloudClips() async {
        let base = ProviderCache()
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let cache = CloudVoiceConsentCache(base: base, localProviders: ["device"], isGranted: { @Sendable in store.isGranted })
        let cloudClip = CachedAudio(data: Data("c".utf8), seconds: 1, providerID: "cloud", voiceID: "host")
        let deviceClip = CachedAudio(data: Data("d".utf8), seconds: 1, providerID: "device", voiceID: "host")
        await cache.store(cloudClip, for: "c1")
        var read = await cache.audio(for: "c1")
        XCTAssertEqual(read, cloudClip, "granted: written and read")
        store.decline()
        read = await cache.audio(for: "c1")
        XCTAssertNil(read, "withdrawn: a stale cloud clip is not read back")
        await cache.store(cloudClip, for: "c2")
        let writes = await base.writesStarted
        XCTAssertEqual(writes, 1, "withdrawn: a new cloud clip is not written")
        await cache.store(deviceClip, for: "d1")
        read = await cache.audio(for: "d1")
        XCTAssertEqual(read, deviceClip, "on-device clips pass through")
    }

    /// The take-time drop purges cached cloud clips again on its own, even ones this preparer
    /// did not write (another renderer on the same cache), and keeps on-device clips.
    func testTheTakeTimeDropPurgesCachedCloudClipsAgain() async {
        let r = rig()
        await r.preparer.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        guard case .ready? = await outcome(r.preparer, afterTrack: 0) else { return XCTFail("prepared") }
        r.consent.decline()   // no eager drop, no app purge: only the take sees it
        await r.cache.store(CachedAudio(data: Data("o".utf8), seconds: 1, providerID: "cloud", voiceID: "host"), for: "other")
        await r.cache.store(CachedAudio(data: Data("d".utf8), seconds: 1, providerID: "device", voiceID: "host"), for: "dev")
        let taken = await r.preparer.takeBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked))
        await r.preparer.testAwaitCloudClipPurge()
        let left = await r.cache.providers
        XCTAssertEqual(left, ["device"])
    }

    /// While consent is granted, cloud clips are cached as before and the take purges nothing.
    func testWhileGrantedCloudClipsAreCachedAndKept() async {
        let r = rig()
        await r.preparer.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        guard case .ready? = await outcome(r.preparer, afterTrack: 0) else { return XCTFail("prepared") }
        guard case .ready = await r.preparer.takeBreak(afterTrack: 0) else { return XCTFail("plays") }
        await r.preparer.testAwaitCloudClipPurge()
        let left = await r.cache.providers
        XCTAssertEqual(left, ["cloud"])
    }

    // MARK: 2. Echo's N1: the take-time drop leaves no time-check state

    /// A cloud break whose time-check line is still waiting for its window when the take finds
    /// consent withdrawn: the wait is cancelled, its bookkeeping is gone, nothing is in flight,
    /// and no separate time-check drop is reported (the whole break is the drop).
    func testTheTakeTimeDropClearsTheTimeCheckState() async {
        let cancelled = Flag()
        let r = rig(sleepUntil: { _ in
            do { try await Task.sleep(for: .seconds(3600)) } catch { cancelled.set(); throw error }
        })
        let time = line("It's 9:40.", order: 1)
        let closing = line("Up next, Song 1 by Artist 1.", order: 2)
        var b = DJBreak(afterTrack: 0, cues: [time, closing], attributions: [time.id: .presenter, closing.id: .presenter])
        b.talkOverCueID = closing.id
        b.shape = .timeCheckIntro
        b.timeCheck = DJPlannedTimeCheck(cueID: time.id, plannedAt: Date(timeIntervalSince1970: 0),
                                         templates: [.on: "It's {time}.", .comingUp: "Almost {time}.", .justAfter: "Just after {time}."],
                                         calendar: Calendar(identifier: .gregorian), style: .twelveHour)
        let timeCheckDrops = DropLog()
        await r.preparer.observeTimeCheckDrops { k, _ in timeCheckDrops.add(k, ExcludedCueCounts()) }
        await r.preparer.prepare(b, deadline: .seconds(600), onDeviceOnly: false)
        guard case .ready? = await outcome(r.preparer, afterTrack: 0) else { return XCTFail("rest prepared") }
        var hasState = await r.preparer.testHasTimeCheckState(afterTrack: 0)
        XCTAssertTrue(hasState, "the time check is planned and waiting")
        r.consent.decline()
        let taken = await r.preparer.takeBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked))
        hasState = await r.preparer.testHasTimeCheckState(afterTrack: 0)
        XCTAssertFalse(hasState, "timeChecks, timeCheckDrops and timeCheckDeadlines cleared")
        let inFlight = await r.preparer.testInFlight
        XCTAssertFalse(inFlight.contains(0))
        let waitCancelled = await eventually { cancelled.isSet }
        XCTAssertTrue(waitCancelled, "the late line's wait is cancelled")
        let drop = await r.preparer.testTimeCheckDrop(afterTrack: 0)
        XCTAssertNil(drop)
        XCTAssertTrue(timeCheckDrops.all.isEmpty)
    }

    // MARK: 5. Echo's N2: counts by kind for a cloud-voice drop

    func testACloudVoiceDropReportsItsCuesByKind() async {
        let r = rig()
        let log = DropLog()
        await r.preparer.observeCloudVoiceDrops { k, counts in log.add(k, counts) }
        let item = line("Your dentist is at three.", kind: .upcomingEvent, source: UUID())
        let closing = line("Up next, Song 2 by Artist 2.", order: 1)
        let b2 = DJBreak(afterTrack: 2, cues: [item, closing], attributions: [item.id: .presenter, closing.id: .presenter])
        await r.preparer.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        await r.preparer.prepare(b2, deadline: .seconds(10), onDeviceOnly: false)
        guard case .ready? = await outcome(r.preparer, afterTrack: 0),
              case .ready(let p2)? = await outcome(r.preparer, afterTrack: 2) else { return XCTFail("prepared") }
        XCTAssertEqual(p2.cues.count, 2)
        r.consent.decline()
        let dropped = await r.preparer.dropCloudVoiceBreaks()   // eager: boundaries 0 and 2
        XCTAssertEqual(dropped, [0, 2])
        let rows = log.all
        XCTAssertEqual(rows.map(\.0), [0, 2])
        XCTAssertEqual(rows.first?.1, ExcludedCueCounts(timeChecks: 0, briefing: 0, other: 1, kept: 0))
        XCTAssertEqual(rows.last?.1, ExcludedCueCounts(timeChecks: 0, briefing: 1, other: 1, kept: 0))
        XCTAssertEqual(rows.last?.1.dropped, 2)
    }

    func testTheTakeTimeDropReportsCountsToo() async {
        let r = rig()
        let log = DropLog()
        await r.preparer.observeCloudVoiceDrops { k, counts in log.add(k, counts) }
        await r.preparer.prepare(presenterBreak(afterTrack: 1), deadline: .seconds(10), onDeviceOnly: false)
        guard case .ready? = await outcome(r.preparer, afterTrack: 1) else { return XCTFail("prepared") }
        r.consent.decline()
        _ = await r.preparer.takeBreak(afterTrack: 1)
        XCTAssertEqual(log.all.map(\.0), [1])
        XCTAssertEqual(log.all.first?.1, ExcludedCueCounts(other: 1, kept: 0))
    }

    #if DEBUG || AERODJ_P0_DIAG
    func testTheCloudVoiceDropRowIsCodesAndCountsOnly() {
        var trace = P0EventTrace()
        let row = trace.cloudVoiceDropped(ExcludedCueCounts(timeChecks: 1, briefing: 2, other: 1, kept: 0), afterTrack: 4, at: 5)
        XCTAssertEqual(row.event, .breakInterruption)
        XCTAssertEqual(row.detail, "kind=breakDropped reason=paidVoiceRevoked after=4 dropped=4 timeChecks=1 otherCues=1 briefingCues=2 kept=0")
        let codes = Set(P0TraceCode.allCases.map(\.rawValue))
        for pair in row.detail.split(separator: " ") {
            let value = String(pair.split(separator: "=", maxSplits: 1)[1])
            XCTAssertTrue(Int(value) != nil || codes.contains(value), "\(pair) is a number or a code")
        }
    }
    #endif

    // MARK: App wiring (source checks; the app target does not build on Linux)

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Fry's nit 1: the tester Cloud voice card is outside Tune's blocked group, and only "on"
    /// waits for a blocked Tune.
    func testTheCloudVoiceOffSwitchIsOutsideTheBlockedGroup() throws {
        let tune = try appSource("TuneForm.swift")
        guard let blocked = tune.range(of: ".disabled(blockedMessage != nil)"),
              let card = tune.range(of: "TesterCloudVoiceToggleCard(settingsBlocked: blockedMessage != nil)") else {
            return XCTFail("both present")
        }
        XCTAssertLessThan(blocked.lowerBound, card.lowerBound, "the card is not inside the disabled group")
        XCTAssertEqual(tune.components(separatedBy: "TesterCloudVoiceToggleCard(").count - 1, 1)
        let toggle = try appSource("TesterVoiceConsent+App.swift")
        XCTAssertTrue(toggle.contains(".disabled(settingsBlocked && !granted)"))
    }

    /// Echo's N2: the app writes the counts-only row for a cloud-voice drop.
    func testTheAppTracesCloudVoiceDrops() throws {
        let deps = try appSource("AppDependencies.swift")
        XCTAssertTrue(deps.contains("await preparer.observeCloudVoiceDrops { k, counts in"))
        XCTAssertTrue(deps.contains("trace.cloudVoiceDropped(counts, afterTrack: k, at: t)"))
    }
}
