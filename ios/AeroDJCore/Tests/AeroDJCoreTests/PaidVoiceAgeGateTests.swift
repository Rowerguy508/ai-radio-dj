import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

// 18+ gate for the cloud voice (Orion + owner, 2026-10-29: Pro voice is 18+, the app stays 12+).
// The cloud route is reachable only with an "Are you 18 or older?" yes AND consent (and Pro).
// All providers and transports are in-process fakes: no network, no proxy, no paid service. -Fry

/// A fixed age answer (also used by PaidVoiceRouteSplitTests).
struct FixedAge: PaidVoiceAgeProviding {
    let answer: PaidVoiceAgeAnswer
    init(_ answer: PaidVoiceAgeAnswer) { self.answer = answer }
    func paidVoiceAgeAnswer() -> PaidVoiceAgeAnswer { answer }
}

/// Counts proxy requests and answers with fake audio.
private final class AgeSpyTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        let headers = ["Content-Type": "audio/wav", "X-Audio-Duration": "1.5", "X-Billed-Characters": "20"]
        return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

/// Install-session fake that counts reads.
private final class AgeFakeSession: PaidVoiceInstallSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func installSessionCredentials() -> PremiumProxyCredentials? {
        lock.withLock { count += 1 }
        return PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "fake-install-session")
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
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    private func freshDefaults() -> UserDefaults {
        let name = "PaidVoiceAgeGateTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func base() -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(), revocations: NarrationRevocations())
    }

    private func store(_ answer: PaidVoiceAgeAnswer, _ d: UserDefaults) -> PaidVoiceAgeStore {
        let s = PaidVoiceAgeStore(defaults: d)
        switch answer {
        case .unanswered: break
        case .adult: s.record(isAdult: true)
        case .notAdult: s.record(isAdult: false)
        }
        return s
    }

    private func liveBreak(after k: Int = 0) -> DJBreak {
        let c = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "A live presenter line here",
                             estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        return DJBreak(afterTrack: k, cues: [c], attributions: [c.id: .presenter])
    }

    private func providers(_ outcome: DJBreakOutcome?) -> [String] {
        guard case .ready(let p)? = outcome else { return [] }
        return p.clips.map(\.audio.providerID)
    }

    // MARK: Store (on-device, three states, no default)

    func testAgeStoreHasNoDefaultAndPersistsAcrossReloads() {
        let d = freshDefaults()
        XCTAssertEqual(PaidVoiceAgeStore(defaults: d).answer, .unanswered, "no default answer")
        XCTAssertFalse(PaidVoiceAgeStore(defaults: d).isAdultConfirmed, "unanswered is not confirmed")
        PaidVoiceAgeStore(defaults: d).record(isAdult: true)
        XCTAssertEqual(PaidVoiceAgeStore(defaults: d).answer, .adult, "survives a new store (reload)")
        XCTAssertTrue(PaidVoiceAgeStore(defaults: d).isAdultConfirmed)
        PaidVoiceAgeStore(defaults: d).record(isAdult: false)
        XCTAssertEqual(PaidVoiceAgeStore(defaults: d).answer, .notAdult, "a no survives a reload too")
        XCTAssertFalse(PaidVoiceAgeStore(defaults: d).isAdultConfirmed)
        d.set("YES", forKey: PaidVoiceAgeStore.key)
        XCTAssertEqual(PaidVoiceAgeStore(defaults: d).answer, .unanswered, "an unknown stored value is not a yes")
        d.set(true, forKey: PaidVoiceAgeStore.key)
        XCTAssertEqual(PaidVoiceAgeStore(defaults: d).answer, .unanswered, "a bool is not a yes")
        PaidVoiceAgeStore(defaults: d).record(isAdult: true)
        PaidVoiceAgeStore(defaults: d).clear()
        XCTAssertNil(d.object(forKey: PaidVoiceAgeStore.key), "clear removes the answer")
        XCTAssertEqual(PaidVoiceAgeStore(defaults: d).answer, .unanswered)
        PaidVoiceAgeStore(defaults: d).record(isAdult: true)
        XCTAssertEqual(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("AeroDJ.paidVoice") },
                       [PaidVoiceAgeStore.key], "one key, nothing else stored")
        XCTAssertEqual(NoPaidVoiceAgeAnswer().paidVoiceAgeAnswer(), .unanswered)
        XCTAssertEqual(PaidVoiceAgeAnswer.allCases.filter(\.isAdultConfirmed), [.adult])
    }

    // MARK: The six combinations (age x consent): only yes + consent reaches the cloud route

    func testOnlyAgeYesWithConsentReachesTheCloudRoute() async {
        for answer in PaidVoiceAgeAnswer.allCases {
            for consent in [false, true] {
                let name = "age=\(answer.rawValue) consent=\(consent)"
                let d = freshDefaults()
                _ = store(answer, d)
                // A reload: the composition reads a NEW store over the same defaults.
                let age = PaidVoiceAgeStore(defaults: d)
                let t = AgeSpyTransport(), session = AgeFakeSession()
                let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(consent))
                let v = PaidVoice.publicComposition(base: base(), access: access, age: age, selectedVoiceID: voiceID,
                                                    session: session, routeCompiledIn: true, transport: t)
                let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
                await p.prepare(liveBreak(), deadline: .seconds(5), onDeviceOnly: false)
                let outcome = await readyOutcome(p, 0)
                let decision = await v.access.decision()
                if answer == .adult {
                    XCTAssertEqual(v.decision, .included(catalogIndex: 0), name)
                    XCTAssertEqual(session.reads, 1, name)
                } else {
                    XCTAssertEqual(v.decision, .omitted(.ageNotConfirmed), name)
                    XCTAssertEqual(v.renderer.routes.map(\.providerID), ["device"], "\(name): route left out")
                    XCTAssertEqual(session.reads, 0, "\(name): no session asked")
                    XCTAssertEqual(decision, .denied(.ageNotConfirmed), name)
                }
                if answer == .adult && consent {
                    XCTAssertEqual(decision, .allowed, name)
                    XCTAssertEqual(providers(outcome), [PremiumVoiceRoutes.providerID], name)
                    XCTAssertEqual(t.calls, 1, name)
                } else {
                    XCTAssertFalse(decision.permitsPaidVoice, name)
                    XCTAssertEqual(providers(outcome), ["device"], "\(name): on-device voice plays")
                    XCTAssertEqual(t.calls, 0, "\(name): zero proxy calls")
                }
            }
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

    // MARK: Withdrawal mid-show: the existing E1 drop/purge path applies

    func testClearingOrChangingTheAgeAnswerDropsAPreparedCloudBreak() async {
        for withdraw in ["clear", "no"] {
            let d = freshDefaults()
            let age = store(.adult, d)
            let t = AgeSpyTransport()
            let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true))
            let v = PaidVoice.publicComposition(base: base(), access: access, age: age, selectedVoiceID: voiceID,
                                                session: AgeFakeSession(), routeCompiledIn: true, transport: t)
            let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
            await p.prepare(liveBreak(after: 0), deadline: .seconds(5), onDeviceOnly: false)
            await p.prepare(liveBreak(after: 1), deadline: .seconds(5), onDeviceOnly: false)
            let r0 = await readyOutcome(p, 0)
            let r1 = await readyOutcome(p, 1)
            XCTAssertEqual(providers(r0), [PremiumVoiceRoutes.providerID], withdraw)
            XCTAssertEqual(providers(r1), [PremiumVoiceRoutes.providerID], withdraw)
            let before = t.calls
            XCTAssertGreaterThan(before, 0, "\(withdraw): the cloud route was used while confirmed")
            if withdraw == "clear" { PaidVoiceAgeStore(defaults: d).clear() } else { PaidVoiceAgeStore(defaults: d).record(isAdult: false) }
            let dropped = await p.dropPaidVoiceBreaks()
            XCTAssertEqual(dropped, [0, 1], "\(withdraw): prepared cloud breaks are dropped")
            await p.prepare(liveBreak(after: 0), deadline: .seconds(5), onDeviceOnly: false)
            let again = await readyOutcome(p, 0)
            XCTAssertEqual(providers(again), ["device"], "\(withdraw): re-prepared on-device")
            XCTAssertEqual(t.calls, before, "\(withdraw): no proxy call after the withdrawal")
        }
    }

    func testTakeRechecksTheAgeAnswer() async {
        let d = freshDefaults()
        let age = store(.adult, d)
        let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true))
        let v = PaidVoice.publicComposition(base: base(), access: access, age: age, selectedVoiceID: voiceID,
                                            session: AgeFakeSession(), routeCompiledIn: true, transport: AgeSpyTransport())
        let p = DJBreakPreparer(voice: v, userID: "u", stationID: "s", talkOverEnabled: { false })
        await p.prepare(liveBreak(), deadline: .seconds(5), onDeviceOnly: false)
        let r0 = await readyOutcome(p, 0)
        XCTAssertEqual(providers(r0), [PremiumVoiceRoutes.providerID])
        PaidVoiceAgeStore(defaults: d).record(isAdult: false)
        let taken = await p.takeCheckedBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked))
    }

    // MARK: Debug fixture mode (Test Station) never reaches the cloud route

    func testFixtureModeNeverReachesTheCloudRouteEvenForAnAdultWithConsent() async {
        let t = AgeSpyTransport()
        let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true))
        let v = PaidVoice.publicComposition(base: base(), access: access, age: FixedAge(.adult), selectedVoiceID: voiceID,
                                            session: AgeFakeSession(), routeCompiledIn: true, transport: t)
        XCTAssertEqual(v.renderer.routes.map(\.providerID), [PremiumVoiceRoutes.providerID, "device"], "precondition")
        // Even if a cloud route were handed to it, the fixture renderer keeps local, free routes only.
        let fixture = TestStation.makeRenderer(routes: v.renderer.routes, cache: InMemoryAudioCache())
        XCTAssertEqual(fixture.routes.map(\.providerID), ["device"])
        XCTAssertTrue(fixture.routes.allSatisfy(\.isLocalAndFree))
        let p = DJBreakPreparer(renderer: fixture, userID: TestStation.userID, stationID: TestStation.stationID,
                                cadence: TestStation.cadence, talkOverEnabled: { false })
        await p.prepare(liveBreak(), deadline: .seconds(5), onDeviceOnly: false)
        let outcome = await readyOutcome(p, 0)
        XCTAssertEqual(providers(outcome), ["device"])
        XCTAssertEqual(t.calls, 0, "fixture mode: zero proxy calls")
    }
}
