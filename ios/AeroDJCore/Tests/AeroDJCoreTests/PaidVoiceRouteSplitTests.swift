import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

// #174 blocker 9 split (-Echo): the paid-voice route and its per-cue Pro + consent gate are
// build-agnostic; only the owner trial is owner-only, and the public route is compiled OFF
// until #233 PRs 3-4. Plus E1 (#244 review): access ending after a break was prepared.
// All providers and transports are in-process fakes: no network, no proxy, no paid service.

/// Stands in for the ElevenLabs proxy transport: counts requests, answers with fake audio.
private final class SpyTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        let headers = ["Content-Type": "audio/wav", "X-Audio-Duration": "1.5", "X-Billed-Characters": "20"]
        return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

/// Per-install session fake: counts reads (the compiled-out route must not ask).
private final class FakeSession: PaidVoiceInstallSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func installSessionCredentials() -> PremiumProxyCredentials? {
        lock.withLock { count += 1 }
        return PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "fake-install-session")
    }
}

/// Entitlement that can change mid-test (expiry, refund, revocation).
private final class SwitchableEntitlement: ProEntitlementProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ProEntitlementState
    init(_ state: ProEntitlementState) { current = state }
    func set(_ state: ProEntitlementState) { lock.withLock { current = state } }
    func currentProEntitlement() async -> ProEntitlementState { lock.withLock { current } }
}

/// The Keychain service name the script and ios.yml look for (OwnerProxyAuth is owner-only).
private enum OwnerProxyAuthNeedle {
    static let value = "com.aerodj.owner-ab.tts-proxy"
}

/// Polls the preparer until boundary `k` has an outcome (bounded, ~1 s).
private func ready(_ preparer: DJBreakPreparer, _ k: Int) async -> DJBreakOutcome? {
    for _ in 0..<500 {
        if let r = await preparer.testResult(afterTrack: k) { return r }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return nil
}

final class PaidVoiceRouteSplitTests: XCTestCase {
    private let voiceID = PremiumVoiceCatalog.voices[0].id
    private let productID = ProSubscriptionConfig.monthlyProductID
    private var epoch: Date { Date(timeIntervalSince1970: 0) }
    private var pro: ProEntitlementState { .pro(productID: productID, expiresAt: nil) }
    private var presenterLine: String { EditorialTone.warm.continuation[0] }

    // MARK: fixtures

    private func base(cache: AudioCache = InMemoryAudioCache()) -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache, revocations: NarrationRevocations())
    }

    /// The public composition with the switch forced on (the flagged build), proxy faked.
    private func publicVoice(_ access: ProVoiceAccess, transport: SpyTransport,
                             cache: AudioCache = InMemoryAudioCache()) -> PaidVoice {
        PaidVoice.publicComposition(base: base(cache: cache), access: access, selectedVoiceID: voiceID,
                                    session: FakeSession(), routeCompiledIn: true, transport: transport)
    }

    private func bundled(_ access: ProVoiceAccess) -> BundledClipResolver {
        let h = BundledClipManifest.textHash(presenterLine)
        let manifest = BundledClipManifest(voiceID: voiceID, renderSettingsVersion: BundledClipManifest.currentRenderSettingsVersion,
                                           entries: [.init(id: "warm.continuation.0", tone: "warm", text: presenterLine,
                                                           textSHA256: h, file: "\(h).m4a", seconds: 2.5)])
        return BundledClipResolver(manifest: manifest, directory: URL(fileURLWithPath: "/bundle"), access: access,
                                   allowedTexts: BundledClipResolver.allowedTexts, readData: { _ in Data("m4a".utf8) })
    }

    private func cue(_ text: String, seconds: Int = 20) -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                     estimatedSeconds: 3, maxSeconds: seconds, sourceItemID: nil, source: nil, provenance: nil)
    }

    /// One bundled presenter line plus one live presenter line.
    private func twoCueBreak(after k: Int = 0) -> DJBreak {
        let a = cue(presenterLine), b = cue("A live presenter line here")
        return DJBreak(afterTrack: k, cues: [a, b], attributions: [a.id: .presenter, b.id: .presenter])
    }

    private func providers(_ outcome: DJBreakOutcome?) -> [String] {
        guard case .ready(let p)? = outcome else { return [] }
        return p.clips.map(\.audio.providerID)
    }

    private func preparer(_ voice: PaidVoice, bundledAccess: ProVoiceAccess) -> DJBreakPreparer {
        DJBreakPreparer(voice: voice, userID: "u", stationID: "s", bundledClips: bundled(bundledAccess))
    }

    // MARK: gate 2: compiled-out public route

    #if AERODJ_PUBLIC_PAID_ROUTE
    /// Positive control (check-release-disables-paid-voice.sh flagged build).
    func testFlaggedBuildCompilesThePublicRouteIn() {
        XCTAssertTrue(PublicPaidVoiceRoute.compiledIn)
        XCTAssertEqual(PublicPaidVoiceRoute.buildMarker, "AERODJ_PUBLIC_PAID_ROUTE_BUILD")
        let session = FakeSession()
        let v = PaidVoice.publicComposition(base: base(), access: .none, selectedVoiceID: voiceID, session: session)
        XCTAssertEqual(v.decision, .included(catalogIndex: 0))
        XCTAssertEqual(session.reads, 1)
    }
    #else
    func testPublicRouteIsCompiledOffAndNeverAsksForASession() {
        XCTAssertFalse(PublicPaidVoiceRoute.compiledIn)
        let session = FakeSession()
        for access in [ProVoiceAccess.proWithConsentForTests, .none] {
            let v = PaidVoice.publicComposition(base: base(), access: access, selectedVoiceID: voiceID, session: session)
            XCTAssertEqual(v.decision, .omitted(.paidDisabled))
            XCTAssertEqual(v.renderer.routes.map(\.providerID), ["device"])
        }
        XCTAssertEqual(session.reads, 0, "no session is asked while the route is compiled out")
    }
    #endif

    func testPublicCompositionNeedsSessionCredentialsAndCarriesTheGate() {
        let t = SpyTransport()
        let on = publicVoice(.none, transport: t)
        XCTAssertEqual(on.decision, .included(catalogIndex: 0))
        XCTAssertEqual(on.renderer.routes.map(\.providerID), [PremiumVoiceRoutes.providerID, "device"])
        let noSession = PaidVoice.publicComposition(base: base(), access: .none, selectedVoiceID: voiceID,
                                                    session: NoInstallSession(), routeCompiledIn: true)
        XCTAssertEqual(noSession.decision, .omitted(.noCredentials))
        XCTAssertEqual(PaidVoice.onDevice(base()).decision, .omitted(.paidDisabled))
    }

    // MARK: per-cue Pro + consent gate

    func testOnlyProWithConsentUsesTheRouteAndTheBundle() async {
        let t = SpyTransport()
        let access = ProVoiceAccess.proWithConsentForTests
        let outcome = await DJBreakPreparer.render(twoCueBreak(), renderer: publicVoice(access, transport: t).renderer,
                                                   userID: "u", stationID: "s", cap: .init(main: 15, closingCueID: nil, closing: 4),
                                                   bundled: bundled(access), paidVoice: access)
        XCTAssertEqual(providers(outcome), [BundledClipResolver.providerID, PremiumVoiceRoutes.providerID])
        XCTAssertEqual(t.calls, 1)
    }

    func testEveryDeniedEntitlementGetsNoRouteAndNoBundledClip() async {
        let denied: [(String, ProVoiceAccess)] = [
            ("free", .testing(.free, consent: true)),
            ("consent revoked", .testing(pro, consent: false)),
            ("unverified", .testing(.unverified(productID: productID), consent: true)),
            ("expired", .testing(.expired(productID: productID, expiredAt: epoch), consent: true)),
            ("revoked", .testing(.revoked(productID: productID, revokedAt: epoch), consent: true)),
            ("none", .none),
        ]
        for (name, access) in denied {
            let t = SpyTransport()
            // The bundle resolver gets an ALLOWING access on purpose: the preparer's gate alone must hold.
            let outcome = await DJBreakPreparer.render(twoCueBreak(), renderer: publicVoice(access, transport: t).renderer,
                                                       userID: "u", stationID: "s",
                                                       cap: .init(main: 15, closingCueID: nil, closing: 4),
                                                       bundled: bundled(.proWithConsentForTests), paidVoice: access)
            XCTAssertEqual(providers(outcome), ["device", "device"], name)
            XCTAssertEqual(t.calls, 0, "\(name): zero proxy calls")
        }
    }

    func testACachedPaidClipIsNotServedAfterAccessEnds() async {
        let t = SpyTransport(), cache = InMemoryAudioCache()
        let consent = SwitchableConsent(true)
        let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: consent)
        let renderer = publicVoice(access, transport: t, cache: cache).renderer
        let b = twoCueBreak()
        let first = await DJBreakPreparer.render(b, renderer: renderer, userID: "u", stationID: "s", cap: 15, paidVoice: access)
        XCTAssertEqual(providers(first), [PremiumVoiceRoutes.providerID, PremiumVoiceRoutes.providerID])
        consent.set(false)
        let again = await DJBreakPreparer.render(b, renderer: renderer, userID: "u", stationID: "s", cap: 15, paidVoice: access)
        XCTAssertEqual(providers(again), ["device", "device"], "the cache is reached only through the gated view")
        XCTAssertEqual(t.calls, 2)
    }

    func testOnDeviceFallbackKeepsTheBreakCaps() async {
        let access = ProVoiceAccess.none
        let voice = publicVoice(access, transport: SpyTransport())
        // DJFakeVoice: 0.4 s per word. Main cap 15 s (38 words over, 37 under); 6 s minimal (16 over, 15 under).
        func words(_ n: Int) -> String { Array(repeating: "word", count: n).joined(separator: " ") }
        for (main, fits, over) in [(15.0, 37, 38), (6.0, 15, 16)] {
            for (n, ok) in [(fits, true), (over, false)] {
                let c = cue(words(n), seconds: 60)
                let b = DJBreak(afterTrack: 0, cues: [c], attributions: [c.id: .presenter])
                let o = await DJBreakPreparer.render(b, renderer: voice.renderer, userID: "u", stationID: "s",
                                                     cap: .init(main: main, closingCueID: nil, closing: 4), paidVoice: access)
                if ok { XCTAssertEqual(providers(o), ["device"], "\(n) words under \(main) s") }
                else { XCTAssertEqual(o, .skipped(.overBreakBudget), "\(n) words over \(main) s") }
            }
        }
        // Closing cue: 4 s on its own (10 words fit, 11 do not).
        for (n, ok) in [(10, true), (11, false)] {
            let main = cue(words(5), seconds: 60), closing = cue(words(n), seconds: 60)
            let b = DJBreak(afterTrack: 0, cues: [main, closing], attributions: [main.id: .presenter, closing.id: .presenter])
            let o = await DJBreakPreparer.render(b, renderer: voice.renderer, userID: "u", stationID: "s",
                                                 cap: .init(main: 15, closingCueID: closing.id, closing: 4), paidVoice: access)
            if ok { XCTAssertEqual(providers(o), ["device", "device"]) } else { XCTAssertEqual(o, .skipped(.overBreakBudget)) }
        }
    }

    // MARK: E1: access ends after a break was prepared

    func testTakeRechecksAndSkipsAPaidBreakWithAReason() async {
        let consent = SwitchableConsent(true)
        let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: consent)
        let p = preparer(publicVoice(access, transport: SpyTransport()), bundledAccess: access)
        let events = DJEventLog()
        await p.observe { events.add($0) }
        await p.prepare(twoCueBreak(after: 0), deadline: .seconds(5), onDeviceOnly: false)
        let r0 = await ready(p, 0)
        XCTAssertEqual(providers(r0), [BundledClipResolver.providerID, PremiumVoiceRoutes.providerID])
        consent.set(false)
        let taken = await p.takeCheckedBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked))
        XCTAssertTrue(events.all.contains(.skipped(afterTrack: 0, .paidVoiceRevoked)))
    }

    func testTakeHandsOutAllowedAndOnDeviceBreaks() async {
        let entitlement = SwitchableEntitlement(pro)
        let access = ProVoiceAccess(entitlement: entitlement, consent: FixedConsent(true))
        let p = preparer(publicVoice(access, transport: SpyTransport()), bundledAccess: access)
        await p.prepare(twoCueBreak(after: 0), deadline: .seconds(5), onDeviceOnly: false)
        _ = await ready(p, 0)
        guard case .ready = await p.takeCheckedBreak(afterTrack: 0) else { return XCTFail("allowed break withheld") }
        // An on-device break is handed out after expiry: nothing paid in it.
        entitlement.set(.expired(productID: productID, expiredAt: epoch))
        await p.prepare(twoCueBreak(after: 2), deadline: .seconds(5), onDeviceOnly: false)
        let r2 = await ready(p, 2)
        XCTAssertEqual(providers(r2), ["device", "device"])
        guard case .ready = await p.takeCheckedBreak(afterTrack: 2) else { return XCTFail("on-device break withheld") }
    }

    func testDropOnRevocationClearsPaidBreaksOnly() async {
        let entitlement = SwitchableEntitlement(pro)
        let access = ProVoiceAccess(entitlement: entitlement, consent: FixedConsent(true))
        let p = preparer(publicVoice(access, transport: SpyTransport()), bundledAccess: access)
        await p.prepare(twoCueBreak(after: 0), deadline: .seconds(5), onDeviceOnly: false)
        _ = await ready(p, 0)
        let unchanged = await p.dropPaidVoiceBreaks()
        XCTAssertEqual(unchanged, [], "access still allowed: nothing dropped")
        entitlement.set(.revoked(productID: productID, revokedAt: epoch))
        let dropped = await p.dropPaidVoiceBreaks()
        XCTAssertEqual(dropped, [0])
        let after = await p.testResult(afterTrack: 0)
        XCTAssertNil(after)
    }

    // MARK: E1 through the session's re-plan path (#227)

    @MainActor
    private func session(_ access: ProVoiceAccess) async -> (DJBreakSession, DJBreakPreparer, SpyTransport) {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let t = SpyTransport()
        let p = DJBreakPreparer(voice: publicVoice(access, transport: t), userID: "u", stationID: "s",
                                cadence: config.cadence(), bundledClips: bundled(access))
        let s = DJBreakSession(preparer: p, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await s.start()
        await s.queueStarted(djTracks(8))
        return (s, p, t)
    }

    @MainActor
    func testAccessChangeReplansThePlayingSongsBreakOnDevice() async {
        let consent = SwitchableConsent(true)
        let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: consent)
        let (s, p, t) = await session(access)
        guard let k = s.plannedBoundaries.first else { return XCTFail("no break planned") }
        await s.songStarted(index: k, remaining: .seconds(180))
        _ = await ready(p, k)
        XCTAssertGreaterThan(t.calls, 0, "prepared with the paid route while allowed")
        let callsBefore = t.calls
        consent.set(false)
        await s.paidVoiceAccessChanged()
        XCTAssertEqual(s.plannedBoundaries.first, k, "the playing song keeps its boundary")
        let replanned = await ready(p, k)
        XCTAssertFalse(providers(replanned).isEmpty, "the break is prepared again")
        XCTAssertTrue(providers(replanned).allSatisfy { $0 == "device" }, "and on-device")
        XCTAssertEqual(t.calls, callsBefore)
        let handed = await s.naturalBoundary(afterTrack: k)
        XCTAssertTrue(handed.map { $0.clips.allSatisfy { $0.audio.providerID == "device" } } ?? false)
    }

    /// Even with no change notification, the boundary itself re-checks (takeCheckedBreak).
    @MainActor
    func testTheBoundaryRechecksWithoutANotification() async {
        let consent = SwitchableConsent(true)
        let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: consent)
        let (s, p, _) = await session(access)
        guard let k = s.plannedBoundaries.first else { return XCTFail("no break planned") }
        await s.songStarted(index: k, remaining: .seconds(180))
        _ = await ready(p, k)
        consent.set(false)
        let handed = await s.naturalBoundary(afterTrack: k)
        XCTAssertNil(handed, "a paid break is not played after consent is withdrawn")
        let outcome = await p.testResult(afterTrack: k)
        XCTAssertEqual(outcome, .skipped(.paidVoiceRevoked))
    }

    @MainActor
    func testAccessChangeNeverStopsABreakOnAir() async {
        let consent = SwitchableConsent(true)
        let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: consent)
        let (s, p, _) = await session(access)
        var stops = 0
        s.onBreakMustStop = { _, _ in stops += 1 }
        guard let k = s.plannedBoundaries.first else { return XCTFail("no break planned") }
        await s.songStarted(index: k, remaining: .seconds(180))
        _ = await ready(p, k)
        let onAir = await s.naturalBoundary(afterTrack: k)
        XCTAssertNotNil(onAir, "allowed paid break handed out")
        consent.set(false)
        await s.paidVoiceAccessChanged()
        XCTAssertEqual(stops, 0, "a break on air plays out")
        let stillTaken = await p.testTaken(afterTrack: k)
        XCTAssertTrue(stillTaken)
    }

    // MARK: source scans (gates 1 and 2)

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String { try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8) }

    func testThePublicRouteFlagIsCompileTimeOnlyAndSetNowhere() throws {
        // Set by no build setting, xcconfig, project.yml or workflow: only the checks' positive controls.
        for path in ["ios/project.yml", ".github/workflows/testflight.yml"] {
            XCTAssertFalse(try text(path).contains("AERODJ_PUBLIC_PAID_ROUTE"), path)
        }
        let config = try FileManager.default.contentsOfDirectory(atPath: repoRoot.appendingPathComponent("ios/Config").path)
        for file in config { XCTAssertFalse(try text("ios/Config/\(file)").contains("AERODJ_PUBLIC_PAID_ROUTE"), file) }
        let route = try text("ios/AeroDJCore/Sources/AeroDJCore/Voice/PaidVoiceRoute.swift")
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for runtime in ["UserDefaults", "Bundle.main", "infoDictionary", "ProcessInfo"] {
            XCTAssertFalse(route.contains(runtime), "the switch is not a runtime value: \(runtime)")
        }
    }

    /// Gate 1 + 2 needles stay in both Release checks, each with its positive control.
    func testBothReleaseChecksKeepTheSplitNeedlesAndControls() throws {
        let script = try text("ios/scripts/check-release-disables-paid-voice.sh")
        XCTAssertTrue(script.contains("split_needles=(com.aerodj.owner-ab.tts-proxy AERODJ_PUBLIC_PAID_ROUTE_BUILD)"))
        XCTAssertEqual(script.components(separatedBy: "\"${split_needles[@]}\"").count - 1, 2, "plain scan and control")
        XCTAssertTrue(script.contains("-Xswiftc -DAERODJ_OWNER_AB -Xswiftc -DAERODJ_PUBLIC_PAID_ROUTE"))
        XCTAssertTrue(script.contains("PaidVoiceRouteSplitTests.testFlaggedBuildCompilesThePublicRouteIn"))
        let yml = try text(".github/workflows/ios.yml")
        XCTAssertTrue(yml.contains("NEEDLES=(com.aerodj.owner-ab.tts-proxy AERODJ_PUBLIC_PAID_ROUTE_BUILD)"))
        XCTAssertEqual(yml.components(separatedBy: "\"${NEEDLES[@]}\"").count - 1, 2, "plain grep and control")
        XCTAssertTrue(yml.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) AERODJ_OWNER_AB AERODJ_PUBLIC_PAID_ROUTE'"))
        #if AERODJ_OWNER_AB
        XCTAssertEqual(OwnerProxyAuth.keychainService, OwnerProxyAuthNeedle.value)
        #endif
    }

    func testTheAppPreparesThroughThePaidVoiceGateAndOwnerAuthStaysOwnerOnly() throws {
        let deps = try text("ios/AeroDJ/AppDependencies.swift")
        XCTAssertTrue(deps.contains("DJBreakPreparer(voice: paidVoice"))
        XCTAssertTrue(deps.contains("access: paidVoice.access"))
        XCTAssertFalse(deps.contains("liveDefault"))
        let app = try text("ios/AeroDJ/PaidVoice+App.swift")
        let publicBranch = app.components(separatedBy: "#else").dropFirst().first?.components(separatedBy: "#endif").first ?? ""
        XCTAssertTrue(publicBranch.contains("publicComposition"))
        for owner in ["Owner", "owner", "Keychain"] { XCTAssertFalse(publicBranch.contains(owner), owner) }
        let auth = try text("ios/AeroDJCore/Sources/AeroDJCore/Voice/OwnerProxyAuth.swift")
        XCTAssertTrue(auth.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#if AERODJ_OWNER_AB"))
        XCTAssertTrue(auth.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
    }
}
