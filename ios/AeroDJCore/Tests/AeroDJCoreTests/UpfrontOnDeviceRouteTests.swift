import XCTest
@testable import AeroDJCore

// Paid-voice release blocker (Orion, Echo, Sentinel, on #258). A break that cannot play in the
// cloud voice must never render a cloud first pass that is charged and then thrown away.
// `ProxyLedger` counts the way services/aerodj-tts does (handler.ts at integration 2a2b09a,
// unchanged at 2b748bd): one atomic reserve before the upstream call (handler.ts:445-490) charges
// one render (the Pro allowance: 40 breaks x 4 = 160, pro-allowance.ts:61-63) and its characters
// (the subscriber's cap and the global 9k ceiling). A refusal (429, global ceiling first, then the
// Pro render allowance) changes no counter. An upstream non-2xx is refunded (handler.ts:523-530).
// A timeout (504) or network error (handler.ts:533-535) and bad audio after a 2xx
// (handler.ts:543-544) KEEP the charge: the failed cue itself may be billed. The client `VoiceBudget` is checked as well, on a
// route priced like a paid voice. Fakes only, no sleeps. -Nova

private struct ProxyRefused: Error {}
/// 504/502 after the reservation: the charge is kept.
private struct ProxyChargedFailure: Error {}

/// The proxy, as the app sees it: one voice, counted per accepted request.
private final class ProxyLedger: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    private var charged: [String] = []
    private var refused: [String] = []
    let globalCharCap: Int
    /// Pro renders left today (PRO_DAILY_RENDER_ALLOWANCE, 160).
    let proRenderAllowance: Int
    let seconds: Double
    /// Requests (1-based) that fail upstream with a non-2xx: refunded, so nothing is charged.
    let failing: Set<Int>
    /// Requests (1-based) that time out (504), drop (network) or return bad audio after a 2xx:
    /// the reservation is kept, so the failed request is charged.
    let chargedFailing: Set<Int>
    init(globalCharCap: Int = 9_000, proRenderAllowance: Int = 160, seconds: Double = 2,
         failing: Set<Int> = [], chargedFailing: Set<Int> = []) {
        self.globalCharCap = globalCharCap; self.proRenderAllowance = proRenderAllowance; self.seconds = seconds
        self.failing = failing; self.chargedFailing = chargedFailing
    }
    /// Which limit refused each refused request: "global" or "proRenders".
    var refusals: [String] { lock.withLock { refused } }
    /// Every request that reached the proxy, accepted or not.
    var sent: [String] { lock.withLock { requests } }
    /// Renders charged to the Pro daily render allowance (PRO_DAILY_RENDER_ALLOWANCE, 160 a UTC
    /// day = PRO_DAILY_BREAKS 40 x MAX_CLOUD_RENDERS_PER_BREAK 4, pro-allowance.ts).
    var proRenders: Int { lock.withLock { charged.count } }
    /// ElevenLabs characters charged to the subscriber's cap and the global 9k ceiling.
    var elevenLabsChars: Int { lock.withLock { charged.reduce(0) { $0 + $1.count } } }
    var chargedTexts: [String] { lock.withLock { charged } }

    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        try lock.withLock {
            requests.append(text)
            // Global ceiling first, then the Pro render allowance; a refusal changes no counter.
            guard charged.reduce(0, { $0 + $1.count }) + text.count <= globalCharCap else {
                refused.append("global"); throw ProxyRefused()
            }
            guard charged.count < proRenderAllowance else { refused.append("proRenders"); throw ProxyRefused() }
            guard !failing.contains(requests.count) else { throw ProxyRefused() }   // reserved, then refunded
            charged.append(text)
            if chargedFailing.contains(requests.count) { throw ProxyChargedFailure() }   // reservation kept
        }
        return VoiceArtifact(data: Data("cloud:\(text)".utf8), durationSeconds: seconds, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

private final class DeviceVoice: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    let seconds: Double
    init(seconds: Double = 2) { self.seconds = seconds }
    var calls: Int { lock.withLock { n } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { n += 1 }
        return VoiceArtifact(data: Data("device:\(text)".utf8), durationSeconds: seconds, billableUnits: 0,
                             provider: "device", cacheKey: nil)
    }
}

/// Consent withheld for the first `denials` asks, then given.
private final class ConsentAfter: PaidVoiceConsentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    init(denials: Int) { left = denials }
    func hasPaidVoiceConsent() async -> Bool { lock.withLock { left -= 1; return left < 0 } }
}

private struct LivePro: ProEntitlementProviding {
    func currentProEntitlement() async -> ProEntitlementState { .pro(productID: ProSubscriptionConfig.monthlyProductID, expiresAt: .distantFuture) }
}

/// Keeps nothing: every render reaches its provider.
private struct NoCache: AudioCache {
    func audio(for key: String) async -> CachedAudio? { nil }
    func store(_ audio: CachedAudio, for key: String) async {}
    func purge(sourceItemIDs: Set<UUID>) async {}
    func purgeExpired() async {}
    func purgeAllPersonal() async {}
}

private let cloudVoice = VoiceProfile(id: "cloud-voice", name: "Cloud")
private let standardVoice = VoiceProfile(id: "standard", name: "Standard")
/// Microdollars per 1,000 characters on the cloud route: 30 per character.
private let pricePerThousand = 30_000

final class UpfrontOnDeviceRouteTests: XCTestCase {
    private func renderer(_ proxy: ProxyLedger, _ device: DeviceVoice, budget: VoiceBudget = VoiceBudget(dailyCapMicrodollars: 10_000_000))
        -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: proxy, voice: cloudVoice,
                                          microdollarsPerThousandCharacters: pricePerThousand, leavesDevice: true),
                               VoiceRoute(providerID: "device", provider: device, voice: standardVoice)],
                      budget: budget, cache: NoCache(), revocations: NarrationRevocations(), cloudConsent: .inMemory(.accepted))
    }

    private func line(_ text: String) -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                     estimatedSeconds: 2, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
    }

    /// Presenter lines, every one allowed in the cloud voice.
    private func cloudBreak(_ texts: [String] = ["Good evening, this is the late show.", "That one never gets old.",
                                                 "Here's the next one."]) -> DJBreak {
        let cues = texts.map(line)
        return DJBreak(afterTrack: 0, cues: cues, attributions: Dictionary(uniqueKeysWithValues: cues.map { ($0.id, .presenter) }))
    }

    private func render(_ djBreak: DJBreak, _ r: VoiceRenderer, cap: Double = 60, paidVoice: ProVoiceAccess? = nil) async -> DJBreakOutcome {
        await DJBreakPreparer.render(djBreak, renderer: r, userID: "u", stationID: "s", cap: cap, paidVoice: paidVoice)
    }

    private func assertAll(_ outcome: DJBreakOutcome, _ provider: String, count: Int, _ name: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
        guard case .ready(let b) = outcome else { return XCTFail("\(name): expected ready, got \(outcome)", file: file, line: line) }
        XCTAssertEqual(b.clips.map(\.audio.providerID), Array(repeating: provider, count: count), name, file: file, line: line)
    }

    // MARK: 1. a local-only line known up front: zero cloud calls

    func testAnUpfrontLocalOnlyBreakMakesZeroCloudCalls() async {
        let library = line("That was Private Song by Private Artist.")
        let variants: [(String, SpokenAttribution?)] = [
            ("library track", .trackMetadata(trackIDs: ["p1"], origin: .library)),
            ("unknown-origin track", .trackMetadata(trackIDs: ["p1"], origin: .unknown)),
            ("personal context", .personalContext(itemID: UUID(), source: .calendar, provenance: "test:item")),
            ("no attribution", nil),
        ]
        for (name, attribution) in variants {
            var djBreak = cloudBreak()
            var attributions = djBreak.attributions
            attributions[library.id] = attribution
            djBreak = DJBreak(afterTrack: 0, cues: [djBreak.cues[0], library, djBreak.cues[2]], attributions: attributions)
            XCTAssertEqual(DJBreakPreparer.upfrontOnDevice(djBreak), .localOnlyLine, name)
            let proxy = ProxyLedger(), device = DeviceVoice()
            let budget = VoiceBudget(dailyCapMicrodollars: 10_000_000)
            let gate = ProVoiceAccess(entitlement: LivePro(), consent: ConsentAfter(denials: 0))
            assertAll(await render(djBreak, renderer(proxy, device, budget: budget), paidVoice: gate), "device", count: 3, name)
            XCTAssertEqual(proxy.sent.count, 0, "\(name): exactly 0 cloud calls, for any line of the break")
            XCTAssertEqual(proxy.proRenders, 0, "\(name): nothing on the Pro 160/day render allowance")
            XCTAssertEqual(proxy.elevenLabsChars, 0, "\(name): no ElevenLabs characters")
            XCTAssertEqual(device.calls, 3, "\(name): one on-device pass, no retry")
            let committed = await budget.committed(userID: "u")
            XCTAssertEqual(committed, 0, name)
        }
    }

    /// No on-device route to route to: skipped before any cloud request, never sent off the device.
    func testAnUpfrontLocalOnlyBreakWithNoOnDeviceRouteIsSkippedWithoutACloudCall() async {
        let proxy = ProxyLedger()
        let r = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: proxy, voice: cloudVoice, leavesDevice: true)],
                              budget: VoiceBudget(dailyCapMicrodollars: 0), cache: NoCache(),
                              revocations: NarrationRevocations(), cloudConsent: .inMemory(.accepted))
        let private_ = line("That was Private Song.")
        var djBreak = cloudBreak()
        djBreak = DJBreak(afterTrack: 0, cues: djBreak.cues + [private_],
                          attributions: djBreak.attributions.merging([private_.id: .trackMetadata(trackIDs: ["p"], origin: .library)]) { $1 })
        let outcome = await render(djBreak, r)
        XCTAssertEqual(outcome, .skipped(.renderFailed))
        XCTAssertEqual(proxy.sent, [])
    }

    // MARK: 2. briefings go on-device

    func testABriefingGoesOnDevice() async {
        let item = UUID()
        let briefing = NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent, text: "At four, the dentist.",
                                    estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .calendar, provenance: "test:item")
        let lead = line("Here's what's coming up today."), outro = line("That's your afternoon.")
        let djBreak = DJBreak(afterTrack: 0, cues: [lead, briefing, outro],
                              attributions: [lead.id: .presenter, outro.id: .presenter,
                                             briefing.id: .personalContext(itemID: item, source: .calendar, provenance: "test:item")])
        XCTAssertTrue(djBreak.hasBriefing, "precondition")
        // The briefing rule is its own guard, checked first, not a side effect of the local-only rule.
        XCTAssertEqual(DJBreakPreparer.upfrontOnDevice(djBreak), .briefing)
        let proxy = ProxyLedger(), device = DeviceVoice()
        let gate = ProVoiceAccess(entitlement: LivePro(), consent: ConsentAfter(denials: 0))
        assertAll(await render(djBreak, renderer(proxy, device), cap: 45, paidVoice: gate), "device", count: 3)
        XCTAssertEqual(proxy.sent.count, 0, "exactly 0 cloud calls: the briefing's presenter lines stay on-device too")
        XCTAssertEqual(proxy.proRenders, 0, "nothing on the Pro 160/day render allowance (before: up to 3 a briefing)")
        XCTAssertEqual(proxy.elevenLabsChars, 0, "no ElevenLabs characters")
    }

    /// A plain break of presenter and catalog lines is not routed up front.
    func testABreakWithOnlyCloudEligibleLinesIsNotRoutedUpFront() {
        var djBreak = cloudBreak()
        let catalog = line("That was Open Song by Open Artist.")
        djBreak = DJBreak(afterTrack: 0, cues: djBreak.cues + [catalog],
                          attributions: djBreak.attributions.merging([catalog.id: .trackMetadata(trackIDs: ["c"], origin: .catalog)]) { $1 })
        XCTAssertNil(DJBreakPreparer.upfrontOnDevice(djBreak))
    }

    // MARK: 3. a discarded pass leaves the daily count unchanged

    /// Cue 1's cloud request fails upstream (refunded, nothing charged) and it falls to on-device.
    /// Before: cues 2 and 3 still went to the cloud, were charged, and the mixed pass was thrown
    /// away. Now the rest of the break stays on-device: the daily count does not move.
    func testADiscardedPassLeavesTheDailyCountUnchanged() async {
        let proxy = ProxyLedger(failing: [1]), device = DeviceVoice()
        let budget = VoiceBudget(dailyCapMicrodollars: 10_000_000)
        assertAll(await render(cloudBreak(), renderer(proxy, device, budget: budget)), "device", count: 3)
        XCTAssertEqual(proxy.sent.count, 1, "only cue 1 reached the proxy")
        XCTAssertEqual(proxy.proRenders, 0, "no render charged to the daily allowance")
        XCTAssertEqual(proxy.elevenLabsChars, 0, "no character charged to the global cap")
        let committed = await budget.committed(userID: "u")
        XCTAssertEqual(committed, 0)
        XCTAssertEqual(device.calls, 3, "one on-device pass, no retry")
    }

    /// The per-cue paid gate denies cue 1 (Pro or consent not ready yet) and allows cue 2.
    /// Before: cues 2 and 3 were rendered in the cloud and discarded. Now: none.
    func testAGateDenialOnCue1ChargesNothingForTheRestOfTheBreak() async {
        let proxy = ProxyLedger(), device = DeviceVoice()
        let gate = ProVoiceAccess(entitlement: LivePro(), consent: ConsentAfter(denials: 1))
        assertAll(await render(cloudBreak(), renderer(proxy, device), paidVoice: gate), "device", count: 3)
        XCTAssertEqual(proxy.sent, [])
        XCTAssertEqual(proxy.proRenders, 0)
    }

    /// Cue 1 is charged in the cloud, cue 2 fails upstream: the pass is mixed, so it stops there
    /// and cue 3 is never sent. Cue 1's render was billed upstream and stays charged (the proxy
    /// keeps a reservation after a 2xx); nothing more is.
    func testAFailureMidBreakSendsNoFurtherCloudRequest() async {
        let proxy = ProxyLedger(failing: [2]), device = DeviceVoice()
        let djBreak = cloudBreak()
        assertAll(await render(djBreak, renderer(proxy, device)), "device", count: 3)
        XCTAssertEqual(proxy.sent.count, 2, "cue 3 never reached the proxy")
        XCTAssertEqual(proxy.chargedTexts, [SpeechDelivery.speakable(djBreak.cues[0].text)])
    }

    /// Sentinel N1: cue 1 times out at the proxy (504) after its reservation, so it is charged
    /// (handler.ts:533-535 keeps it). The break falls to on-device; cues 2 and 3 make no cloud
    /// call and cost nothing. Exactly 1 Pro render plus cue 1's characters.
    func testACue1TimeoutKeepsItsChargeAndTheRestOfTheBreakCostsNothing() async {
        let proxy = ProxyLedger(chargedFailing: [1]), device = DeviceVoice()
        let djBreak = cloudBreak()
        let cue1 = SpeechDelivery.speakable(djBreak.cues[0].text)
        assertAll(await render(djBreak, renderer(proxy, device)), "device", count: 3)
        XCTAssertEqual(proxy.sent, [cue1], "cues 2 and 3: no cloud call")
        XCTAssertEqual(proxy.proRenders, 1, "exactly 1 Pro render: the failed cue 1 itself")
        XCTAssertEqual(proxy.elevenLabsChars, cue1.count, "exactly cue 1's characters")
        XCTAssertEqual(device.calls, 3, "one on-device pass, no retry")
    }

    // MARK: 4. over-cap fallback doesn't charge

    /// The global character ceiling refuses cue 1 (too long for what is left) but would accept
    /// the shorter cues 2 and 3. Before: they were charged and the mixed pass discarded.
    func testProxyOverCapFallbackDoesNotCharge() async {
        let long = String(repeating: "A long opening line. ", count: 6), short = ["Next.", "Here it is."]
        let proxy = ProxyLedger(globalCharCap: 40), device = DeviceVoice()
        assertAll(await render(cloudBreak([long] + short), renderer(proxy, device)), "device", count: 3)
        XCTAssertEqual(proxy.sent.count, 1, "only the refused cue 1 reached the proxy")
        XCTAssertEqual(proxy.refusals, ["global"])
        XCTAssertEqual(proxy.proRenders, 0)
        XCTAssertEqual(proxy.elevenLabsChars, 0)
    }

    /// Echo N1: the Pro 160-render allowance is spent (429 `pro_renders`, its own refusal, not
    /// the global 9k one). Cue 1 is refused without a charge and the break falls back exactly
    /// like the global refusal: all on-device, no further cloud request.
    func testProRenderAllowance429ChargesNothingAndFallsBackOnDevice() async {
        let proxy = ProxyLedger(proRenderAllowance: 0), device = DeviceVoice()
        assertAll(await render(cloudBreak(), renderer(proxy, device)), "device", count: 3)
        XCTAssertEqual(proxy.sent.count, 1, "only the refused cue 1 reached the proxy")
        XCTAssertEqual(proxy.refusals, ["proRenders"], "refused by the Pro render allowance, not the global ceiling")
        XCTAssertEqual(proxy.proRenders, 0)
        XCTAssertEqual(proxy.elevenLabsChars, 0)
        XCTAssertEqual(device.calls, 3, "one on-device pass, no retry")
    }

    /// The client budget refuses cue 1 (`.overCostCap`) but has room for the shorter cues.
    func testClientBudgetOverCapFallbackDoesNotCharge() async {
        let long = String(repeating: "A long opening line. ", count: 6), short = ["Next.", "Here it is."]
        let budget = VoiceBudget(dailyCapMicrodollars: 30 * 40)   // 40 characters
        let proxy = ProxyLedger(), device = DeviceVoice()
        assertAll(await render(cloudBreak([long] + short), renderer(proxy, device, budget: budget)), "device", count: 3)
        XCTAssertEqual(proxy.sent, [], "the budget refused cue 1 before any request; cues 2 and 3 stayed on-device")
        let committed = await budget.committed(userID: "u")
        XCTAssertEqual(committed, 0)
    }

    /// Build 20's over-cap fallback: each cloud clip fits its cue, the break does not. Once the
    /// clips so far are over the cap the pass can only be discarded, so no further cue is sent.
    /// The renders before that point were billed upstream and stay charged.
    func testOverTheBreakCapStopsRequestingOnceTheBreakCannotFit() async {
        let proxy = ProxyLedger(seconds: 5), device = DeviceVoice(seconds: 2)
        assertAll(await render(cloudBreak(), renderer(proxy, device), cap: 8), "device", count: 3)
        XCTAssertEqual(proxy.sent.count, 2, "5 + 5 s is over 8 s after cue 2: cue 3 never sent")
        XCTAssertEqual(device.calls, 3, "one on-device retry")
    }

    // MARK: 5. an all-cloud break still charges exactly once

    /// Sentinel N2: a break of presenter and CATALOG track lines (the attributions the script
    /// writer gives a catalog queue) is not routed up front and keeps the cloud voice on every
    /// cue, so a regression that sends every break on-device fails here.
    func testAnAllCatalogBreakUsesTheCloudVoiceForEveryCue() async {
        let opener = line("Good evening."), was = line("That was Open Song by Open Artist."),
            next = line("Next, Open Tune by Open Band.")
        let djBreak = DJBreak(afterTrack: 0, cues: [opener, was, next],
                              attributions: [opener.id: .presenter,
                                             was.id: .trackMetadata(trackIDs: ["c1"], origin: .catalog),
                                             next.id: .trackMetadata(trackIDs: ["c2"], origin: .catalog)])
        XCTAssertNil(DJBreakPreparer.upfrontOnDevice(djBreak))
        let proxy = ProxyLedger(), device = DeviceVoice()
        let gate = ProVoiceAccess(entitlement: LivePro(), consent: ConsentAfter(denials: 0))
        assertAll(await render(djBreak, renderer(proxy, device), paidVoice: gate), "cloud", count: 3)
        XCTAssertEqual(proxy.sent.count, 3, "every catalog and presenter line reached the cloud voice")
        XCTAssertEqual(proxy.proRenders, 3)
        XCTAssertEqual(device.calls, 0)
    }

    /// Sentinel N3 / Echo N3: on a Pro build the routes are [ElevenLabs] + the on-device routes
    /// in order (PremiumVoiceCatalog.swift:163; on the app, Phonon if enabled, then the best
    /// Enhanced/Premium voice, then the standard voice). An up-front break uses `onDeviceOnly`,
    /// all of them in order, so it plays the PRIMARY on-device voice, not the standard
    /// `lastRouteOnly` voice the old discard-and-retry landed on.
    func testAnUpfrontBreakOnAProBuildUsesThePrimaryOnDeviceVoice() async {
        let proxy = ProxyLedger(), primary = DeviceVoice(), standard = DeviceVoice()
        let r = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: proxy, voice: cloudVoice, leavesDevice: true),
                                       VoiceRoute(providerID: "device", provider: primary, voice: VoiceProfile(id: "enhanced", name: "Host")),
                                       VoiceRoute(providerID: "device", provider: standard, voice: standardVoice)],
                              budget: VoiceBudget(dailyCapMicrodollars: 0), cache: NoCache(),
                              revocations: NarrationRevocations(), cloudConsent: .inMemory(.accepted))
        let library = line("That was Private Song.")
        var djBreak = cloudBreak()
        djBreak = DJBreak(afterTrack: 0, cues: djBreak.cues + [library],
                          attributions: djBreak.attributions.merging([library.id: .trackMetadata(trackIDs: ["p"], origin: .library)]) { $1 })
        let outcome = await render(djBreak, r)
        guard case .ready(let b) = outcome else { return XCTFail("expected ready, got \(outcome)") }
        XCTAssertEqual(b.clips.map(\.audio.voiceID), Array(repeating: "enhanced", count: 4), "the primary on-device voice")
        XCTAssertEqual(primary.calls, 4)
        XCTAssertEqual(standard.calls, 0)
        XCTAssertEqual(proxy.sent.count, 0)
    }

    func testAnAllCloudBreakStillChargesExactlyOnce() async {
        let proxy = ProxyLedger(), device = DeviceVoice()
        let budget = VoiceBudget(dailyCapMicrodollars: 10_000_000)
        let djBreak = cloudBreak()
        let gate = ProVoiceAccess(entitlement: LivePro(), consent: ConsentAfter(denials: 0))
        assertAll(await render(djBreak, renderer(proxy, device, budget: budget), paidVoice: gate), "cloud", count: 3)
        let texts = djBreak.cues.map { SpeechDelivery.speakable($0.text) }
        XCTAssertEqual(proxy.sent, texts, "each line sent once, in order, no second pass")
        XCTAssertEqual(proxy.chargedTexts, texts, "each line charged once")
        XCTAssertEqual(proxy.proRenders, 3, "one render per line on the Pro 160/day allowance")
        XCTAssertEqual(proxy.elevenLabsChars, texts.reduce(0) { $0 + $1.count }, "ElevenLabs characters charged once")
        XCTAssertEqual(device.calls, 0)
        let committed = await budget.committed(userID: "u")
        XCTAssertEqual(committed, texts.reduce(0) { $0 + ($1.count * pricePerThousand + 999) / 1000 }, "client budget charged once")
    }
}
