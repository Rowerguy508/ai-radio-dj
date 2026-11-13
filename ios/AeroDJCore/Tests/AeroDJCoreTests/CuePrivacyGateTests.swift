import XCTest
@testable import AeroDJCore

// #400 (-Sentinel): each DJ cue has one privacy class (`CuePrivacy.classify`), and one choke point
// (`VoiceRenderer.mayUse(_:for:)`, live consent scope) is checked right before an off-device
// route's cache lookup, its provider call (TTS) and its cache write, and before a segment reaches
// an off-device rewriter (generation). Each gate test withdraws consent at exactly the step it
// guards. In-process fakes only: no network, no paid service. No cue text is logged.

/// Off-device fake that records the texts it is asked to voice and can run a hook mid-call.
private final class RecordingCloud: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var duringCall: @Sendable () -> Void = {}
    var received: [String] { lock.withLock { texts } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        duringCall()
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

/// A consent scope the test can flip, and can script per read (the n-th read and later).
private final class ScopeSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var scope: CloudVoiceScope
    /// From this read on (1-based), `.noLines` is returned. Nil: never by count.
    var withdrawAtRead: Int?
    init(_ scope: CloudVoiceScope) { self.scope = scope }
    func withdraw() { lock.withLock { scope = .noLines } }
    func read() -> CloudVoiceScope {
        lock.withLock {
            reads += 1
            if let n = withdrawAtRead, reads >= n { return .noLines }
            return scope
        }
    }
}

/// Cache that records every store and can run a hook during one.
private actor RecordingCache: AudioCache {
    let base = InMemoryAudioCache()
    private(set) var storedProviders: [String] = []
    private var duringStore: (@Sendable () -> Void)?
    func setDuringStore(_ hook: @escaping @Sendable () -> Void) { duringStore = hook }
    func audio(for key: String) async -> CachedAudio? { await base.audio(for: key) }
    func store(_ audio: CachedAudio, for key: String) async {
        storedProviders.append(audio.providerID)
        await base.store(audio, for: key)
        duringStore?()
    }
    func purge(sourceItemIDs: Set<UUID>) async { await base.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await base.purgeExpired() }
    func purgeAllPersonal() async { await base.purgeAllPersonal() }
    func purgeClips(keepingProviders providerIDs: Set<String>) async { await base.purgeClips(keepingProviders: providerIDs) }
    func providersHeld(for key: String) async -> String? { await base.audio(for: key)?.providerID }
}

/// Cache whose read of one key parks after fetching the clip and before returning it, so a test
/// can withdraw consent while `audio(for:)` is in flight, then let the read finish.
private final class SuspendingReadCache: AudioCache, @unchecked Sendable {
    let base = InMemoryAudioCache()
    private let lock = NSLock()
    private var key: String?
    private var parked: CheckedContinuation<Void, Never>?
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var arrived = false
    private var released = false
    func suspendReads(of key: String) { lock.withLock { self.key = key } }
    func audio(for key: String) async -> CachedAudio? {
        let hit = await base.audio(for: key)
        let shouldPark = lock.withLock { () -> Bool in
            guard key == self.key, !arrived else { return false }
            arrived = true
            return true
        }
        guard shouldPark else { return hit }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let (waiter, resumeNow) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, Bool) in
                let w = arrivalWaiter
                arrivalWaiter = nil
                if released { return (w, true) }
                parked = c
                return (w, false)
            }
            waiter?.resume()
            if resumeNow { c.resume() }
        }
        return hit
    }
    /// Returns once a read of the key is parked.
    func untilReadIsSuspended() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if parked != nil { return true }
                arrivalWaiter = c
                return false
            }
            if ready { c.resume() }
        }
    }
    func finishRead() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { parked = nil }
            return parked
        }
        c?.resume()
    }
    func store(_ audio: CachedAudio, for key: String) async { await base.store(audio, for: key) }
    func purge(sourceItemIDs: Set<UUID>) async { await base.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await base.purgeExpired() }
    func purgeAllPersonal() async { await base.purgeAllPersonal() }
    func purgeClips(keepingProviders providerIDs: Set<String>) async { await base.purgeClips(keepingProviders: providerIDs) }
}

final class CuePrivacyGateTests: XCTestCase {
    private let item = UUID()
    private var calendarCue: NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .upcomingEvent, text: "From your calendar: dentist at 3.",
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .calendar, provenance: "calendar:1")
    }
    private var calendarAttribution: SpokenAttribution { .personalContext(itemID: item, source: .calendar, provenance: "calendar:1") }

    private func transition(_ text: String = "Here's the next one.", provenance: String? = nil) -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: provenance)
    }

    private func renderer(_ cloud: RecordingCloud, cache: any AudioCache = InMemoryAudioCache(),
                          scope: ScopeSwitch) -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice, leavesDevice: true),
                               VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache,
                      revocations: NarrationRevocations(), cloudScope: { scope.read() })
    }

    private func cloudKey(_ cue: NarrationCue, _ r: VoiceRenderer) -> String {
        VoiceRenderer.cacheKey(text: SpeechDelivery.speakable(cue.text), route: r.routes[0])
    }

    // MARK: classification

    func testClassificationIsFailClosedAndCoversEveryAttribution() {
        XCTAssertEqual(CuePrivacy.classify(transition(), attribution: nil), .onDeviceOnly)
        XCTAssertEqual(CuePrivacy.classify(calendarCue, attribution: calendarAttribution), .personal)
        XCTAssertEqual(CuePrivacy.classify(transition(), attribution: .stationName), .personal)
        XCTAssertEqual(CuePrivacy.classify(transition(), attribution: .trackMetadata(trackIDs: ["l"], origin: .library)), .personal)
        XCTAssertEqual(CuePrivacy.classify(transition(), attribution: .trackMetadata(trackIDs: ["u"], origin: .unknown)), .personal)
        XCTAssertEqual(CuePrivacy.classify(transition(), attribution: .trackMetadata(trackIDs: ["c"], origin: .catalog)), .public)
        XCTAssertEqual(CuePrivacy.classify(transition(), attribution: .presenter), .public)
        let news = transition(provenance: FactProvenance.make(kind: .localNews, id: UUID(), provider: "gdelt"))
        XCTAssertEqual(CuePrivacy.classify(news, attribution: .presenter), .personal, "a fact line is never public")
        // The calendar cue's text under a presenter attribution is still personal (sourced cue).
        XCTAssertEqual(CuePrivacy.classify(calendarCue, attribution: .presenter), .personal)
    }

    func testEligibilityMatrix() {
        let expected: [CuePrivacyClass: [CloudVoiceScope: Bool]] = [
            .onDeviceOnly: [.noLines: false, .transitionsOnly: false, .allLines: false],
            .personal: [.noLines: false, .transitionsOnly: false, .allLines: true],
            .public: [.noLines: false, .transitionsOnly: true, .allLines: true],
        ]
        for (privacy, row) in expected {
            for (scope, allowed) in row {
                XCTAssertEqual(privacy.mayLeaveDevice(scope: scope), allowed, "\(privacy) under \(scope)")
            }
        }
    }

    /// `mayLeaveDevice` (#176 / #432) now reads the class; its answers are unchanged.
    func testMayLeaveDeviceAgreesWithTheClassForEveryCueAndScope() {
        let cues = [transition(), calendarCue, transition(provenance: "x")]
        let attributions: [SpokenAttribution?] = [nil, .presenter, .stationName, calendarAttribution,
                                                  .trackMetadata(trackIDs: ["c"], origin: .catalog),
                                                  .trackMetadata(trackIDs: ["l"], origin: .library)]
        for cue in cues {
            for a in attributions {
                for scope in [CloudVoiceScope.noLines, .transitionsOnly, .allLines] {
                    XCTAssertEqual(VoiceRenderer.mayLeaveDevice(cue, attribution: a, scope: scope),
                                   CuePrivacy.classify(cue, attribution: a).mayLeaveDevice(scope: scope))
                }
            }
        }
    }

    // MARK: gate 1: cache lookup

    func testLookupGateNeverServesACachedCloudClipAfterConsentIsWithdrawn() async {
        let cloud = RecordingCloud(), cache = InMemoryAudioCache()
        let scope = ScopeSwitch(.allLines)
        let r = renderer(cloud, cache: cache, scope: scope)
        let cue = calendarCue
        await cache.store(CachedAudio(data: Data("old-cloud".utf8), seconds: 1, providerID: "cloud", voiceID: djVoice.id,
                                      sourceItemIDs: [item, VoiceRenderer.allLinesClipTag]), for: cloudKey(cue, r))
        scope.withdrawAtRead = 2   // read 1: the cue's start; read 2: the lookup gate
        let result = await r.render(cue, userID: "u", stationID: "s", attribution: calendarAttribution)
        guard case .success(let clip) = result else { return XCTFail("falls through to the on-device voice") }
        XCTAssertEqual(clip.audio.providerID, "device", "the cached cloud clip must not be served")
        XCTAssertTrue(cloud.received.isEmpty)
        XCTAssertTrue(clip.attempts.contains { $0.result == .failed(VoiceRenderer.privacyGateSkip) })
    }

    /// Atlas's B1 on #498: a plain decline (no item revoked) that lands while the cache read is in
    /// flight must not hand back the cached cloud clip; the cue falls through to the on-device voice.
    func testLookupGateDoesNotServeACachedCloudClipWhenConsentIsWithdrawnDuringTheRead() async {
        let cloud = RecordingCloud(), cache = SuspendingReadCache()
        let scope = ScopeSwitch(.allLines)
        let r = renderer(cloud, cache: cache, scope: scope)
        let cue = calendarCue
        let key = cloudKey(cue, r)
        await cache.store(CachedAudio(data: Data("old-cloud".utf8), seconds: 1, providerID: "cloud", voiceID: djVoice.id,
                                      sourceItemIDs: [item, VoiceRenderer.allLinesClipTag]), for: key)
        cache.suspendReads(of: key)
        let attribution = calendarAttribution
        let rendering = Task { await r.render(cue, userID: "u", stationID: "s", attribution: attribution) }
        await cache.untilReadIsSuspended()   // gate 1 passed under `.allLines`; the read is in flight
        scope.withdraw()                      // plain decline: no revoke, no purge
        cache.finishRead()
        let result = await rendering.value
        guard case .success(let clip) = result else { return XCTFail("falls through to the on-device voice") }
        XCTAssertEqual(clip.audio.providerID, "device", "the cached cloud clip must not be served after the decline")
        XCTAssertFalse(clip.attempts.contains { $0.result == .cacheHit && $0.providerID == "cloud" })
        XCTAssertTrue(clip.attempts.contains { $0.providerID == "cloud" && $0.result == .failed(VoiceRenderer.privacyGateSkip) })
        XCTAssertTrue(cloud.received.isEmpty, "no cue text reaches the cloud voice either")
    }

    // MARK: gate 2: TTS call

    func testTTSGateSendsNoTextWhenConsentIsWithdrawnJustBeforeTheCall() async {
        let cloud = RecordingCloud()
        let scope = ScopeSwitch(.allLines)
        let r = renderer(cloud, scope: scope)
        scope.withdrawAtRead = 3   // 1: start; 2: lookup gate; 3: inside the timed task, before synthesize
        let result = await r.render(calendarCue, userID: "u", stationID: "s", attribution: calendarAttribution)
        XCTAssertTrue(cloud.received.isEmpty, "no cue text may reach the cloud voice after a withdrawal")
        guard case .success(let clip) = result else { return XCTFail("falls through to the on-device voice") }
        XCTAssertEqual(clip.audio.providerID, "device")
        XCTAssertTrue(clip.attempts.contains { $0.providerID == "cloud" && $0.result == .failed(VoiceRenderer.privacyGateSkip) })
    }

    func testTTSGateReleasesAPaidReservation() async {
        let cloud = RecordingCloud()
        let scope = ScopeSwitch(.allLines)
        let budget = VoiceBudget(dailyCapMicrodollars: 1_000_000)
        let r = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice,
                                                  microdollarsPerThousandCharacters: 1000, leavesDevice: true),
                                       VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                              budget: budget, cache: InMemoryAudioCache(), revocations: NarrationRevocations(),
                              cloudScope: { scope.read() })
        scope.withdrawAtRead = 3
        _ = await r.render(calendarCue, userID: "u", stationID: "s", attribution: calendarAttribution)
        XCTAssertTrue(cloud.received.isEmpty)
        let reserved = await budget.reserve(userID: "u", microdollars: 1_000_000)
        XCTAssertNotNil(reserved, "the refused call's reservation was released, nothing billed")
    }

    // MARK: gate 3: cache write

    func testCacheWriteGateDoesNotCacheOrReturnACloudClipWhenConsentIsWithdrawnDuringTTS() async {
        let cloud = RecordingCloud(), cache = RecordingCache()
        let scope = ScopeSwitch(.allLines)
        cloud.duringCall = { scope.withdraw() }   // the decline lands while the provider runs
        let r = renderer(cloud, cache: cache, scope: scope)
        let cue = calendarCue
        let result = await r.render(cue, userID: "u", stationID: "s", attribution: calendarAttribution)
        let stored = await cache.storedProviders
        XCTAssertFalse(stored.contains("cloud"), "a cloud clip is never written after the withdrawal")
        guard case .success(let clip) = result else { return XCTFail("falls through to the on-device voice") }
        XCTAssertEqual(clip.audio.providerID, "device", "the cloud clip is not returned either")
        let held = await cache.providersHeld(for: cloudKey(cue, r))
        XCTAssertNil(held)
    }

    func testCacheWriteGateRemovesACloudClipWhenConsentIsWithdrawnDuringTheWrite() async {
        let cloud = RecordingCloud(), cache = RecordingCache()
        let scope = ScopeSwitch(.allLines)
        await cache.setDuringStore { scope.withdraw() }
        let r = renderer(cloud, cache: cache, scope: scope)
        let cue = calendarCue
        let result = await r.render(cue, userID: "u", stationID: "s", attribution: calendarAttribution)
        let held = await cache.providersHeld(for: cloudKey(cue, r))
        XCTAssertNil(held, "the clip written during the withdrawal is purged again")
        guard case .success(let clip) = result else { return XCTFail("falls through to the on-device voice") }
        XCTAssertEqual(clip.audio.providerID, "device", "and it is not returned")
    }

    /// With consent steady, nothing changes: the cloud route voices and caches the line.
    func testSteadyConsentStillUsesAndCachesTheCloudVoice() async {
        let cloud = RecordingCloud(), cache = RecordingCache()
        let r = renderer(cloud, cache: cache, scope: ScopeSwitch(.allLines))
        let result = await r.render(calendarCue, userID: "u", stationID: "s", attribution: calendarAttribution)
        guard case .success(let clip) = result else { return XCTFail("renders") }
        XCTAssertEqual(clip.audio.providerID, "cloud")
        XCTAssertEqual(cloud.received.count, 1)
        let stored = await cache.storedProviders
        XCTAssertEqual(stored, ["cloud"])
    }

    // MARK: generation gate (rewrite step)

    private struct RecordingRewriter: BriefingRewriter {
        let calls: CallBox
        let leavesDevice: Bool
        func rewrite(_ segment: BriefingScriptSegment, style: BriefingStyle) async throws -> String {
            calls.add(); return segment.text
        }
    }

    private final class CallBox: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func add() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    private func segment(_ kind: BriefingScriptSegment.Kind, item: UUID? = nil) -> BriefingScriptSegment {
        BriefingScriptSegment(id: UUID(), kind: kind, text: "Some line.", title: nil, detail: nil, timePhrase: nil,
                              sourceItemID: item, source: item == nil ? nil : .calendar,
                              provenance: item == nil ? nil : "calendar:1", estimatedSpokenSeconds: 2)
    }

    private func script(_ segments: [BriefingScriptSegment]) -> BriefingScript {
        BriefingScript(segments: segments, excluded: [:], unavailableSources: [], experienceSeconds: 300)
    }

    func testGenerationGateKeepsPersonalSegmentsFromAnOffDeviceRewriterWithoutAllLinesConsent() async {
        let personal = script([segment(.upcomingEvent, item: UUID())])
        for scope in [CloudVoiceScope.noLines, .transitionsOnly] {
            let calls = CallBox()
            let result = await BriefingRewriteGuard().restyle(personal, with: RecordingRewriter(calls: calls, leavesDevice: true),
                                                              cloudScope: { scope })
            XCTAssertEqual(calls.count, 0, "\(scope)")
            XCTAssertEqual(result.script, personal)
            XCTAssertEqual(result.fallbacks, 1)
        }
        // Default (no consent check wired): nothing goes off the device.
        let calls = CallBox()
        _ = await BriefingRewriteGuard().restyle(personal, with: RecordingRewriter(calls: calls, leavesDevice: true))
        XCTAssertEqual(calls.count, 0)
    }

    func testGenerationGateAllowsEligibleSegmentsAndOnDeviceRewriters() async {
        let personal = script([segment(.upcomingEvent, item: UUID())])
        let calls = CallBox()
        _ = await BriefingRewriteGuard().restyle(personal, with: RecordingRewriter(calls: calls, leavesDevice: true),
                                                 cloudScope: { .allLines })
        XCTAssertEqual(calls.count, 1, "v3 consent lets a personal segment go")
        let plain = script([segment(.transition)])
        let plainCalls = CallBox()
        _ = await BriefingRewriteGuard().restyle(plain, with: RecordingRewriter(calls: plainCalls, leavesDevice: true),
                                                 cloudScope: { .transitionsOnly })
        XCTAssertEqual(plainCalls.count, 1, "a public transition is eligible under transitions-only")
        let localCalls = CallBox()
        _ = await BriefingRewriteGuard().restyle(personal, with: RecordingRewriter(calls: localCalls, leavesDevice: false))
        XCTAssertEqual(localCalls.count, 1, "an on-device rewriter is not gated")
    }

    func testGenerationGateReadsConsentBeforeEachSegment() async {
        let s = script([segment(.upcomingEvent, item: UUID()), segment(.upcomingEvent, item: UUID())])
        let scope = ScopeSwitch(.allLines)
        scope.withdrawAtRead = 2
        let calls = CallBox()
        _ = await BriefingRewriteGuard().restyle(s, with: RecordingRewriter(calls: calls, leavesDevice: true),
                                                 cloudScope: { scope.read() })
        XCTAssertEqual(calls.count, 1, "the second segment sees the withdrawal")
    }

    /// A rewriter that does not declare where it runs is treated as leaving the device.
    func testRewriterDefaultsToLeavingTheDevice() {
        struct Unspecified: BriefingRewriter {
            func rewrite(_ segment: BriefingScriptSegment, style: BriefingStyle) async throws -> String { segment.text }
        }
        XCTAssertTrue(Unspecified().leavesDevice)
    }

    // MARK: bundled clips use the same choke point

    func testBundledCloudClipIsNotServedWhenConsentIsWithdrawn() {
        let line = EditorialTone.warm.continuation[0]
        let hash = BundledClipManifest.textHash(line)
        let manifest = BundledClipManifest(voiceID: "voice-A", renderSettingsVersion: BundledClipManifest.currentRenderSettingsVersion,
                                           entries: [.init(id: "warm.continuation.0", tone: "warm", text: line, textSHA256: hash,
                                                           file: "\(hash).m4a", seconds: 2.5)])
        let resolver = BundledClipResolver(manifest: manifest, directory: URL(fileURLWithPath: "/bundle"),
                                           access: .proWithConsentForTests, readData: { _ in Data("m4a".utf8) })
        let cue = transition(line)
        func renderer(_ scope: CloudVoiceScope) -> VoiceRenderer {
            VoiceRenderer(routes: [VoiceRoute(providerID: PremiumVoiceRoutes.providerID, provider: RecordingCloud(),
                                              voice: VoiceProfile(id: "voice-A", name: "Paid"), leavesDevice: true),
                                   VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                          budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                          revocations: NarrationRevocations(), cloudScope: { scope })
        }
        XCTAssertNotNil(resolver.clip(for: cue, attribution: .presenter, renderer: renderer(.transitionsOnly)))
        XCTAssertNil(resolver.clip(for: cue, attribution: .presenter, renderer: renderer(.noLines)))
    }
}
