import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
import XCTest
@testable import AeroDJCore

// 18+ gate for the cloud voice (Orion + owner, 2026-10-29: Pro voice is 18+, the app stays 13+).
// The cloud route is reachable only on a cue where the "Are you 18 or older?" answer is yes AND
// consent is given AND Pro is active; until then no install session read and no proxy call.
// All providers, storage and transports are in-process fakes: no network, no proxy, no paid
// service, no Keychain. -Fry

/// A fixed age answer (also used by PaidVoiceRouteSplitTests).
struct FixedAge: PaidVoiceAgeProviding {
    let answer: PaidVoiceAgeAnswer
    init(_ answer: PaidVoiceAgeAnswer) { self.answer = answer }
    func paidVoiceAgeAnswer() -> PaidVoiceAgeAnswer { answer }
}

/// Counts proxy requests; answers with fake audio, or with `status` (a failing proxy).
private final class AgeSpyTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let status: Int
    private let onSend: @Sendable () -> Void
    init(status: Int = 200, onSend: @escaping @Sendable () -> Void = {}) { self.status = status; self.onSend = onSend }
    var calls: Int { lock.withLock { count } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        onSend()
        let headers = ["Content-Type": "audio/wav", "X-Audio-Duration": "1.5", "X-Billed-Characters": "20"]
        return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

/// Install-session fake that counts reads; `credentials` can be changed per test.
private final class AgeFakeSession: PaidVoiceInstallSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var value: PremiumProxyCredentials?
    init(_ value: PremiumProxyCredentials? = PremiumProxyCredentials(
        endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "fake-install-session")) { self.value = value }
    var reads: Int { lock.withLock { count } }
    func installSessionCredentials() -> PremiumProxyCredentials? {
        lock.withLock { count += 1; return value }
    }
}

/// Counts consent reads, to prove a missing age answer never even asks for consent.
private final class CountingConsent: PaidVoiceConsentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let granted: Bool
    init(_ granted: Bool) { self.granted = granted }
    var reads: Int { lock.withLock { count } }
    func hasPaidVoiceConsent() async -> Bool { lock.withLock { count += 1 }; return granted }
}

private final class AgeSwitchableEntitlement: ProEntitlementProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ProEntitlementState
    init(_ state: ProEntitlementState) { current = state }
    func set(_ state: ProEntitlementState) { lock.withLock { current = state } }
    func currentProEntitlement() async -> ProEntitlementState { lock.withLock { current } }
}

/// On-device voice that runs `onRender` while it renders (a listener answering between cues).
private struct HookedDeviceVoice: VoiceProvider {
    let onRender: @Sendable () -> Void
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        onRender()
        return try await DJFakeVoice().synthesize(text, voice: voice, context: context)
    }
}

private func readyOutcome(_ preparer: DJBreakPreparer, _ k: Int) async -> DJBreakOutcome? {
    for _ in 0..<500 {
        if let r = await preparer.testResult(afterTrack: k) { return r }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return nil
}

final class PaidVoiceAgeGateTests: XCTestCase {
    private let voiceID = PremiumVoiceCatalog.voices[0].id
    private var pro: ProEntitlementState { .pro(productID: ProSubscriptionConfig.monthlyProductID, expiresAt: .distantFuture) }

    private func base() -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(), revocations: NarrationRevocations())
    }

    private func store(_ answer: PaidVoiceAgeAnswer, _ storage: PaidVoiceAgeStorage = InMemoryPaidVoiceAgeStorage()) -> PaidVoiceAgeStore {
        let s = PaidVoiceAgeStore(storage: storage)
        switch answer {
        case .unanswered: break
        case .adult: s.record(isAdult: true)
        case .notAdult: s.record(isAdult: false)
        }
        return s
    }

    private func compose(_ access: ProVoiceAccess, age: any PaidVoiceAgeProviding, session: AgeFakeSession,
                         transport: AgeSpyTransport) -> PaidVoice {
        PaidVoice.publicComposition(base: base(), access: access, age: age, selectedVoiceID: voiceID,
                                    session: session, routeCompiledIn: true, transport: transport)
    }

    private func liveBreak(after k: Int = 0, text: String = "A live presenter line here") -> DJBreak {
        let c = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                             estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        return DJBreak(afterTrack: k, cues: [c], attributions: [c.id: .presenter])
    }

    private func providers(_ outcome: DJBreakOutcome?) -> [String] {
        guard case .ready(let p)? = outcome else { return [] }
        return p.clips.map(\.audio.providerID)
    }

    private func prepared(_ p: DJBreakPreparer, _ k: Int, text: String = "A live presenter line here") async -> [String] {
        await p.prepare(liveBreak(after: k, text: text), deadline: .seconds(5), onDeviceOnly: false)
        return providers(await readyOutcome(p, k))
    }

    // MARK: Store (this device only, three states, no default)

    func testAgeStoreHasNoDefaultAndPersistsAcrossReloads() {
        let storage = InMemoryPaidVoiceAgeStorage()
        XCTAssertEqual(PaidVoiceAgeStore(storage: storage).answer, .unanswered, "no default answer")
        XCTAssertFalse(PaidVoiceAgeStore(storage: storage).isAdultConfirmed, "unanswered is not confirmed")
        PaidVoiceAgeStore(storage: storage).record(isAdult: true)
        XCTAssertEqual(PaidVoiceAgeStore(storage: storage).answer, .adult, "survives a new store (reload)")
        XCTAssertTrue(PaidVoiceAgeStore(storage: storage).isAdultConfirmed)
        PaidVoiceAgeStore(storage: storage).record(isAdult: false)
        XCTAssertEqual(PaidVoiceAgeStore(storage: storage).answer, .notAdult, "a no survives a reload too")
        XCTAssertFalse(PaidVoiceAgeStore(storage: storage).isAdultConfirmed)
        storage.writeAnswer("YES")
        XCTAssertEqual(PaidVoiceAgeStore(storage: storage).answer, .unanswered, "an unknown stored value is not a yes")
        PaidVoiceAgeStore(storage: storage).record(isAdult: true)
        PaidVoiceAgeStore(storage: storage).clear()
        XCTAssertNil(storage.readAnswer(), "clear deletes the answer")
        XCTAssertEqual(PaidVoiceAgeStore(storage: storage).answer, .unanswered)
        XCTAssertEqual(NoPaidVoiceAgeAnswer().paidVoiceAgeAnswer(), .unanswered)
        XCTAssertEqual(PaidVoiceAgeAnswer.allCases.filter(\.isAdultConfirmed), [.adult])
    }

    /// Sentinel N2 (#267): the live answer is a Keychain item that is never backed up or synced.
    func testLiveStoreIsAThisDeviceOnlyKeychainItemAndNotUserDefaults() throws {
        XCTAssertEqual(PaidVoiceAgeKeychain.accessibilityName, "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly")
        XCTAssertTrue(PaidVoiceAgeKeychain.accessibilityName.hasSuffix("ThisDeviceOnly"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AeroDJCore/Purchases/PaidVoiceAgeGate.swift"),
                                encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("q[kSecAttrAccessible as String] = accessibility"))
        XCTAssertTrue(code.contains("{ kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }"))
        XCTAssertTrue(code.contains("kSecAttrSynchronizable as String: kCFBooleanFalse"))
        for banned in ["UserDefaults", "kSecAttrAccessibleAlways", "kSecAttrAccessibleAfterFirstUnlock ",
                       "kSecAttrAccessibleAfterFirstUnlock}", "kSecAttrAccessibleWhenUnlocked "] {
            XCTAssertFalse(code.contains(banned), banned)
        }
        #if canImport(Security)
        let attrs = KeychainPaidVoiceAgeStorage.addAttributes("yes")
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attrs[kSecAttrService as String] as? String, PaidVoiceAgeKeychain.service)
        XCTAssertEqual(attrs[kSecAttrSynchronizable as String] as? Bool, false)
        #endif
    }

    // MARK: The six combinations (age x consent): only yes + consent reaches the cloud route

    func testOnlyAgeYesWithConsentReachesTheCloudRoute() async {
        for answer in PaidVoiceAgeAnswer.allCases {
            for consent in [false, true] {
                let name = "age=\(answer.rawValue) consent=\(consent)"
                let storage = InMemoryPaidVoiceAgeStorage()
                _ = store(answer, storage)
                let age = PaidVoiceAgeStore(storage: storage)   // a reload: a new store, same storage
                let t = AgeSpyTransport(), session = AgeFakeSession()
                let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(consent))
                let v = compose(access, age: age, session: session, transport: t)
                XCTAssertEqual(session.reads, 0, "\(name): setup never asks for a session")
                XCTAssertEqual(v.decision, answer == .adult ? .included(catalogIndex: 0) : .omitted(.ageNotConfirmed), name)
                let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
                let used = await prepared(p, 0)
                let decision = await v.access.decision()
                if answer != .adult { XCTAssertEqual(decision, .denied(.ageNotConfirmed), name) }
                if answer == .adult && consent {
                    XCTAssertEqual(decision, .allowed, name)
                    XCTAssertEqual(used, [PremiumVoiceRoutes.providerID], name)
                    XCTAssertEqual(session.reads, 1, "\(name): the session is asked on the allowed cue")
                    XCTAssertEqual(t.calls, 1, name)
                } else {
                    XCTAssertFalse(decision.permitsPaidVoice, name)
                    XCTAssertEqual(used, ["device"], "\(name): on-device voice plays")
                    XCTAssertEqual(session.reads, 0, "\(name): no install session read")
                    XCTAssertEqual(t.calls, 0, "\(name): zero proxy calls")
                }
            }
        }
    }

    /// Sentinel (#267): nothing is asked of the session, and nothing is sent, before the first
    /// cue where age, consent AND Pro all allow it; that cue asks once and makes one call.
    func testNoSessionOrProxyCallBeforeTheFirstCueWhereAgeConsentAndProAllAllow() async {
        let storage = InMemoryPaidVoiceAgeStorage()
        let age = PaidVoiceAgeStore(storage: storage)
        let consent = SwitchableConsent(false)
        let entitlement = AgeSwitchableEntitlement(.free)
        let t = AgeSpyTransport(), session = AgeFakeSession()
        let v = compose(ProVoiceAccess(entitlement: entitlement, consent: consent), age: age, session: session, transport: t)
        let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
        // Each step opens one more gate; every cue before the last is on-device and silent.
        let steps: [(String, () -> Void)] = [
            ("nothing given", {}),
            ("age yes only", { age.record(isAdult: true) }),
            ("age + consent, free", { consent.set(true) }),
            ("age + consent, expired", { entitlement.set(.expired(productID: ProSubscriptionConfig.monthlyProductID,
                                                                  expiredAt: Date(timeIntervalSince1970: 0))) }),
            ("consent + Pro, age cleared", { entitlement.set(self.pro); age.clear() }),
            ("consent + Pro, age no", { age.record(isAdult: false) }),
        ]
        for (k, (name, step)) in steps.enumerated() {
            step()
            let used = await prepared(p, k, text: "Line number \(k) here")
            XCTAssertEqual(used, ["device"], name)
            XCTAssertEqual(session.reads, 0, "\(name): no install session read")
            XCTAssertEqual(t.calls, 0, "\(name): no proxy call")
        }
        age.record(isAdult: true)
        let used = await prepared(p, steps.count, text: "The first allowed line")
        XCTAssertEqual(used, [PremiumVoiceRoutes.providerID], "age + consent + Pro: the cloud voice")
        XCTAssertEqual(session.reads, 1)
        XCTAssertEqual(t.calls, 1)
    }

    /// The deferred provider re-checks the gate itself and applies compose's credential rules.
    func testDeferredProviderRefusesBeforeTheSessionAndPinsTheHost() async {
        let ctx = RequestContext(stationID: "s", isReusableGeneric: false)
        let allowed = ProVoiceAccess.proWithConsentForTests.requiringAdult(FixedAge(.adult))
        let cases: [(String, ProVoiceAccess, PremiumProxyCredentials?, InstallSessionProxyVoiceProvider.Refusal, Int)] = [
            ("age not confirmed", ProVoiceAccess.proWithConsentForTests.requiringAdult(FixedAge(.notAdult)),
             PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "t"), .notAllowed, 0),
            ("no session", allowed, nil, .noCredentials, 1),
            ("blank token", allowed, PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!,
                                                             token: " \n"), .emptyToken, 1),
            ("other host", allowed, PremiumProxyCredentials(endpoint: URL(string: "https://evil.example/api/tts")!, token: "t"),
             .endpointNotAllowed, 1),
            ("http", allowed, PremiumProxyCredentials(endpoint: URL(string: "http://aerodj-tts.vercel.app/api/tts")!, token: "t"),
             .endpointNotAllowed, 1),
        ]
        for (name, access, creds, refusal, reads) in cases {
            let t = AgeSpyTransport(), session = AgeFakeSession(creds)
            let provider = InstallSessionProxyVoiceProvider(session: session, access: access,
                                                            pinnedHosts: PremiumVoiceRoutes.allowedHosts, transport: t)
            do {
                _ = try await provider.synthesize("Hi", voice: VoiceProfile(id: voiceID, name: "v"), context: ctx)
                XCTFail("\(name): must refuse")
            } catch {
                XCTAssertEqual(error as? InstallSessionProxyVoiceProvider.Refusal, refusal, name)
            }
            XCTAssertEqual(session.reads, reads, name)
            XCTAssertEqual(t.calls, 0, "\(name): no proxy call")
        }
    }

    func testComposeOmitsWithTheNewReasonAndKeepsPaidDisabledFirst() {
        let creds = PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "t")
        let omitted = PremiumVoiceRoutes.compose(onDevice: base().routes, paidProvidersEnabled: true,
                                                 access: .denied(.ageNotConfirmed), selectedVoiceID: voiceID,
                                                 credentials: creds)
        XCTAssertEqual(omitted.decision, .omitted(.ageNotConfirmed))
        XCTAssertEqual(omitted.routes.map(\.providerID), ["device"])
        XCTAssertEqual(PremiumVoiceRoutes.compose(onDevice: [], paidProvidersEnabled: false, access: .denied(.ageNotConfirmed),
                                                  selectedVoiceID: voiceID, credentials: creds).decision,
                       .omitted(.paidDisabled), "the compiled-out switch still wins")
        XCTAssertEqual(PremiumVoiceRoutes.compose(onDevice: [], paidProvidersEnabled: true, access: .denied(.noConsent),
                                                  selectedVoiceID: voiceID, credentials: creds).decision,
                       .omitted(.notEntitled), "other denials are unchanged")
        XCTAssertEqual(PremiumVoiceRoutes.OmitReason.ageNotConfirmed.rawValue, "ageNotConfirmed", "log code")
        let off = PaidVoice.publicComposition(base: base(), access: .proWithConsentForTests, age: FixedAge(.adult),
                                              selectedVoiceID: voiceID, session: AgeFakeSession(), routeCompiledIn: false)
        XCTAssertEqual(off.decision, .omitted(.paidDisabled))
        XCTAssertEqual(off.renderer.routes.map(\.providerID), ["device"], "compiled out: no route at all")
    }

    func testAgeIsAskedFirstAndANoNeverReadsConsentOrPro() async {
        for answer in [PaidVoiceAgeAnswer.unanswered, .notAdult] {
            let consent = CountingConsent(true), entitlement = CountingEntitlement(pro)
            let access = ProVoiceAccess(entitlement: entitlement, consent: consent).requiringAdult(FixedAge(answer))
            let d = await access.decision()
            XCTAssertEqual(d, .denied(.ageNotConfirmed))
            XCTAssertEqual(consent.reads, 0)
            XCTAssertEqual(entitlement.reads, 0)
        }
        let consent = CountingConsent(false)
        let noConsent = await ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: consent)
            .requiringAdult(FixedAge(.adult)).decision()
        XCTAssertEqual(noConsent, .denied(.noConsent), "an adult without consent is still denied")
        XCTAssertEqual(consent.reads, 1)
        let none = await ProVoiceAccess.none.requiringAdult(FixedAge(.adult)).decision()
        XCTAssertFalse(none.permitsPaidVoice, "the fail-closed default stays closed")
    }

    // MARK: A yes mid-session (Nova, #267): no relaunch

    func testYesMidSessionPutsTheNextCueOnTheCloudRoute() async {
        let age = store(.unanswered)
        let t = AgeSpyTransport(), session = AgeFakeSession()
        let v = compose(ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true)),
                        age: age, session: session, transport: t)
        let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
        let before = await prepared(p, 0)
        XCTAssertEqual(before, ["device"])
        XCTAssertEqual(session.reads + t.calls, 0, "before the yes: no session, no proxy")
        age.record(isAdult: true)
        let after = await prepared(p, 1)
        XCTAssertEqual(after, [PremiumVoiceRoutes.providerID], "the same launch's next cue uses the cloud voice")
        XCTAssertEqual(session.reads, 1)
        XCTAssertEqual(t.calls, 1)
    }

    @MainActor
    private func session(_ voice: PaidVoice) async -> (DJBreakSession, DJBreakPreparer) {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let p = DJBreakPreparer(voice: voice, userID: "u", stationID: "s", cadence: config.cadence(),
                                talkOverEnabled: { false })
        let s = DJBreakSession(preparer: p, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await s.start()
        await s.queueStarted(djTracks(8))
        return (s, p)
    }

    /// The playing song's break was prepared on-device before the yes: `paidVoiceAccessChanged()`
    /// prepares it again, so the very next boundary plays the cloud voice.
    @MainActor
    func testYesThenAccessChangedPreparesThePlayingBreakAgainOnTheCloudRoute() async {
        let age = store(.unanswered)
        let t = AgeSpyTransport(), fake = AgeFakeSession()
        let v = compose(ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true)),
                        age: age, session: fake, transport: t)
        let (s, p) = await session(v)
        guard let k = s.plannedBoundaries.first else { return XCTFail("no break planned") }
        await s.songStarted(index: k, remaining: .seconds(180))
        let first = await readyOutcome(p, k)
        XCTAssertTrue(providers(first).allSatisfy { $0 == "device" } && !providers(first).isEmpty, "on-device before the yes")
        XCTAssertEqual(fake.reads + t.calls, 0)
        age.record(isAdult: true)
        await s.paidVoiceAccessChanged()
        let again = await readyOutcome(p, k)
        XCTAssertTrue(providers(again).contains(PremiumVoiceRoutes.providerID), "prepared again with the cloud voice")
        XCTAssertGreaterThan(t.calls, 0)
        let handed = await s.naturalBoundary(afterTrack: k)
        XCTAssertTrue(handed.map { $0.clips.contains { $0.audio.providerID == PremiumVoiceRoutes.providerID } } ?? false,
                      "the next boundary plays the cloud voice, no relaunch")
    }

    /// Too little time left for a cloud render: the on-device break is kept, never lost.
    @MainActor
    func testYesTooCloseToTheBoundaryKeepsTheOnDeviceBreak() async {
        let age = store(.unanswered)
        let t = AgeSpyTransport()
        let v = compose(ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true)),
                        age: age, session: AgeFakeSession(), transport: t)
        let (s, p) = await session(v)
        guard let k = s.plannedBoundaries.first else { return XCTFail("no break planned") }
        await s.songStarted(index: k, remaining: .seconds(15))
        let first = await readyOutcome(p, k)
        XCTAssertEqual(Set(providers(first)), ["device"])
        age.record(isAdult: true)
        await s.paidVoiceAccessChanged()
        let kept = await p.testResult(afterTrack: k)
        XCTAssertEqual(kept, first, "kept as prepared")
        XCTAssertEqual(t.calls, 0)
    }

    /// Only a break rendered under a denial is released; one that fell back because the proxy
    /// failed is kept (no second paid attempt), and nothing is released while still denied.
    func testReleaseOnlyAfterAGrantAndOnlyForABreakPreparedWhileDenied() async {
        let age = store(.unanswered)
        let v = compose(ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true)),
                        age: age, session: AgeFakeSession(), transport: AgeSpyTransport())
        let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
        _ = await prepared(p, 0)
        let stillDenied = await p.releaseBreakPreparedWhileDenied(afterTrack: 0)
        XCTAssertFalse(stillDenied, "no grant yet")
        age.record(isAdult: true)
        let released = await p.releaseBreakPreparedWhileDenied(afterTrack: 0)
        XCTAssertTrue(released)
        let cleared = await p.testResult(afterTrack: 0)
        XCTAssertNil(cleared, "ready to prepare again")

        let failing = AgeSpyTransport(status: 502)
        let w = compose(.proWithConsentForTests, age: FixedAge(.adult), session: AgeFakeSession(), transport: failing)
        let q = DJBreakPreparer(voice: w, userID: "u", stationID: "s", talkOverEnabled: { false })
        let fellBack = await prepared(q, 0)
        XCTAssertEqual(fellBack, ["device"])
        let releasedFallback = await q.releaseBreakPreparedWhileDenied(afterTrack: 0)
        XCTAssertFalse(releasedFallback, "a proxy failure is not a denial: no retry")
        XCTAssertEqual(failing.calls, 1)
    }

    // MARK: One voice per break: a yes between cues waits for the next break

    private func twoCues(after k: Int) -> DJBreak {
        let a = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "First live line of the break",
                             estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        let b = NarrationCue(id: UUID(), order: 1, group: -1, kind: .transition, text: "Second live line of the break",
                             estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        return DJBreak(afterTrack: k, cues: [a, b], attributions: [a.id: .presenter, b.id: .presenter])
    }

    func testAYesBetweenCuesNeverSwitchesVoicesMidBreak() async {
        let age = store(.unanswered)
        let t = AgeSpyTransport(), fake = AgeFakeSession()
        let device = VoiceRenderer(routes: [VoiceRoute(providerID: "device",
                                                       provider: HookedDeviceVoice { age.record(isAdult: true) },
                                                       voice: djVoice)],
                                   budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                                   revocations: NarrationRevocations())
        let v = PaidVoice.publicComposition(base: device, access: .proWithConsentForTests, age: age, selectedVoiceID: voiceID,
                                            session: fake, routeCompiledIn: true, transport: t)
        let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
        await p.prepare(twoCues(after: 0), deadline: .seconds(5), onDeviceOnly: false)
        let first = providers(await readyOutcome(p, 0))
        XCTAssertEqual(age.answer, .adult, "the yes landed while cue 1 rendered")
        XCTAssertEqual(first, ["device", "device"], "the break that started without a yes ends without the cloud voice")
        XCTAssertEqual(fake.reads + t.calls, 0, "no session read and no proxy call in that break")
        await p.prepare(twoCues(after: 1), deadline: .seconds(5), onDeviceOnly: false)
        let next = providers(await readyOutcome(p, 1))
        XCTAssertEqual(next, [PremiumVoiceRoutes.providerID, PremiumVoiceRoutes.providerID], "the next break: cloud throughout")
        XCTAssertEqual(t.calls, 2)
    }

    /// A "no" between cues is not deferred: the next cue is already on-device, and the take
    /// check then refuses the mixed break (no cloud clip plays after the no).
    func testANoBetweenCuesTakesEffectAtTheNextCue() async {
        let age = store(.adult)
        let t = AgeSpyTransport(onSend: { age.record(isAdult: false) })   // a no while cue 1 renders
        let v = compose(.proWithConsentForTests, age: age, session: AgeFakeSession(), transport: t)
        let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
        await p.prepare(twoCues(after: 0), deadline: .seconds(5), onDeviceOnly: false)
        let used = providers(await readyOutcome(p, 0))
        XCTAssertEqual(used, [PremiumVoiceRoutes.providerID, "device"], "cue 2 is already on-device")
        XCTAssertEqual(t.calls, 1, "no proxy call after the no")
        let taken = await p.takeCheckedBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked), "the cloud clip of that break never plays")
    }

    // MARK: Withdrawal mid-show: the existing E1 drop path applies

    func testClearingOrChangingTheAgeAnswerDropsAPreparedCloudBreak() async {
        for withdraw in ["clear", "no"] {
            let storage = InMemoryPaidVoiceAgeStorage()
            let age = store(.adult, storage)
            let t = AgeSpyTransport()
            let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true))
            let v = compose(access, age: age, session: AgeFakeSession(), transport: t)
            let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
            let r0 = await prepared(p, 0)
            let r1 = await prepared(p, 1)
            XCTAssertEqual(r0, [PremiumVoiceRoutes.providerID], withdraw)
            XCTAssertEqual(r1, [PremiumVoiceRoutes.providerID], withdraw)
            let before = t.calls
            XCTAssertGreaterThan(before, 0, "\(withdraw): the cloud route was used while confirmed")
            if withdraw == "clear" { PaidVoiceAgeStore(storage: storage).clear() }
            else { PaidVoiceAgeStore(storage: storage).record(isAdult: false) }
            let dropped = await p.dropPaidVoiceBreaks()
            XCTAssertEqual(dropped, [0, 1], "\(withdraw): prepared cloud breaks are dropped")
            let again = await prepared(p, 0)
            XCTAssertEqual(again, ["device"], "\(withdraw): re-prepared on-device")
            XCTAssertEqual(t.calls, before, "\(withdraw): no proxy call after the withdrawal")
        }
    }

    @MainActor
    func testNoAfterYesThroughTheSessionReplansOnDevice() async {
        let age = store(.adult)
        let t = AgeSpyTransport()
        let v = compose(ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true)),
                        age: age, session: AgeFakeSession(), transport: t)
        let (s, p) = await session(v)
        guard let k = s.plannedBoundaries.first else { return XCTFail("no break planned") }
        await s.songStarted(index: k, remaining: .seconds(180))
        let first = await readyOutcome(p, k)
        XCTAssertTrue(providers(first).contains(PremiumVoiceRoutes.providerID))
        let before = t.calls
        age.record(isAdult: false)
        await s.paidVoiceAccessChanged()
        let replanned = await readyOutcome(p, k)
        XCTAssertTrue(!providers(replanned).isEmpty && providers(replanned).allSatisfy { $0 == "device" })
        XCTAssertEqual(t.calls, before)
    }

    func testTakeRechecksTheAgeAnswer() async {
        let age = store(.adult)
        let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true))
        let v = compose(access, age: age, session: AgeFakeSession(), transport: AgeSpyTransport())
        let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
        let r0 = await prepared(p, 0)
        XCTAssertEqual(r0, [PremiumVoiceRoutes.providerID])
        age.record(isAdult: false)
        let taken = await p.takeCheckedBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked))
    }

    // MARK: Debug fixture mode (Test Station) never reaches the cloud route

    // `TestStation` is Debug-only, so this test is too; otherwise `swift test -c release`
    // (check-release-disables-paid-voice.sh) can't compile the test target (Echo B1, #267).
    #if DEBUG
    func testFixtureModeNeverReachesTheCloudRouteEvenForAnAdultWithConsent() async {
        let t = AgeSpyTransport(), fake = AgeFakeSession()
        let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true))
        let v = compose(access, age: FixedAge(.adult), session: fake, transport: t)
        XCTAssertEqual(v.renderer.routes.map(\.providerID), [PremiumVoiceRoutes.providerID, "device"], "precondition")
        let fixture = TestStation.makeRenderer(routes: v.renderer.routes, cache: InMemoryAudioCache())
        XCTAssertEqual(fixture.routes.map(\.providerID), ["device"])
        XCTAssertTrue(fixture.routes.allSatisfy(\.isLocalAndFree))
        let p = DJBreakPreparer(renderer: fixture, userID: TestStation.userID, stationID: TestStation.stationID,
                                cadence: TestStation.cadence, talkOverEnabled: { false })
        let used = await prepared(p, 0)
        XCTAssertEqual(used, ["device"])
        XCTAssertEqual(t.calls, 0, "fixture mode: zero proxy calls")
        XCTAssertEqual(fake.reads, 0, "fixture mode: no install session read")
    }
    #endif
}
