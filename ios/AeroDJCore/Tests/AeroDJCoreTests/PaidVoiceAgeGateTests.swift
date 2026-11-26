import Foundation
#if canImport(Security)
import Security
#endif
import XCTest
@testable import AeroDJCore

// 18+ gate for the cloud voice (Orion + owner, 2026-10-29: Pro voice is 18+, the app stays 13+).
// Re-cut of #267's intent onto current integration: the Keychain store, ProVoiceAccess.requiringAdult,
// compose's `.ageNotConfirmed`, the preparer's drop/take/re-prepare path, and one voice per break.
// The live app is not wired (no age on the tester/owner renderer or preparerConsent) until #281's
// age step lands; nil age is no gate, not `NoPaidVoiceAgeAnswer`. All providers and storage are
// in-process fakes: no network, no proxy, no Keychain writes. -Atlas

struct FixedAge: PaidVoiceAgeProviding {
    let answer: PaidVoiceAgeAnswer
    init(_ answer: PaidVoiceAgeAnswer) { self.answer = answer }
    func paidVoiceAgeAnswer() -> PaidVoiceAgeAnswer { answer }
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

private final class CountingEntitlementForAge: ProEntitlementProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let state: ProEntitlementState
    init(_ state: ProEntitlementState) { self.state = state }
    var reads: Int { lock.withLock { count } }
    func currentProEntitlement() async -> ProEntitlementState { lock.withLock { count += 1 }; return state }
}

/// Off-device fake: renders every text it is handed as "cloud" audio, and counts the calls.
private final class AgeCloudFake: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var onRender: (@Sendable () -> Void)?
    var calls: Int { lock.withLock { count } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        onRender?()
        lock.withLock { count += 1 }
        return VoiceArtifact(data: Data("cloud:\(text)".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

private struct HookedDeviceVoice: VoiceProvider {
    let onRender: @Sendable () -> Void
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        onRender()
        return try await DJFakeVoice().synthesize(text, voice: voice, context: context)
    }
}

/// Injected `DJBreakSession` clock. Starts at a fixed instant so elapsed-time tests are deterministic.
private final class AdjustableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_000_000)) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

private func readyOutcome(_ preparer: DJBreakPreparer, _ k: Int) async -> DJBreakOutcome? {
    for _ in 0..<500 {
        if let r = await preparer.testResult(afterTrack: k) { return r }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return nil
}

private func providers(_ outcome: DJBreakOutcome?) -> [String] {
    guard case .ready(let ready)? = outcome else { return [] }
    return ready.clips.map(\.audio.providerID)
}

final class PaidVoiceAgeGateTests: XCTestCase {
    private let voiceID = PremiumVoiceCatalog.voices[0].id
    private let creds = PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!,
                                                token: "fake-token")
    private var pro: ProEntitlementState {
        .pro(productID: ProSubscriptionConfig.monthlyProductID, expiresAt: .distantFuture)
    }

    private func store(_ answer: PaidVoiceAgeAnswer) -> PaidVoiceAgeStore {
        let stored: String? = switch answer {
        case .adult: "yes"
        case .notAdult: "no"
        case .unanswered: nil
        }
        return PaidVoiceAgeStore(storage: InMemoryPaidVoiceAgeStorage(stored))
    }

    private func device() -> [VoiceRoute] {
        [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)]
    }

    private func compose(_ access: ProVoiceGate.Decision) -> PremiumVoiceRoutes.Composition {
        PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, access: access,
                                   selectedVoiceID: voiceID, credentials: creds)
    }

    private func presenterBreak(afterTrack k: Int, lines: Int = 1,
                                onFirstDeviceCue: (@Sendable () -> Void)? = nil) -> DJBreak {
        let cues = (0..<lines).map { i in
            NarrationCue(id: UUID(), order: i, group: -1, kind: .transition,
                         text: "Line \(i) of break \(k).", estimatedSeconds: 3, maxSeconds: 20,
                         sourceItemID: nil, source: nil, provenance: nil)
        }
        var attributions: [UUID: SpokenAttribution] = [:]
        for cue in cues { attributions[cue.id] = .presenter }
        return DJBreak(afterTrack: k, cues: cues, attributions: attributions)
    }

    private func rig(age: PaidVoiceAgeStore, consent: CloudVoiceConsentState = .accepted,
                     onCloudRender: (@Sendable () -> Void)? = nil,
                     onDeviceRender: (@Sendable () -> Void)? = nil) -> (DJBreakPreparer, AgeCloudFake) {
        let cloud = AgeCloudFake()
        cloud.onRender = onCloudRender
        let deviceProvider: any VoiceProvider = onDeviceRender.map { HookedDeviceVoice(onRender: $0) } ?? DJFakeVoice()
        let renderer = VoiceRenderer(
            routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice, leavesDevice: true),
                     VoiceRoute(providerID: "device", provider: deviceProvider, voice: djVoice)],
            budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
            cloudScope: {
                PaidVoiceAgeGate.allowsCloudVoice(age) && consent == .accepted ? .transitionsOnly : .noLines
            })
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", talkOverEnabled: { false },
                                       cloudVoiceConsent: { consent == .accepted && age.isAdultConfirmed },
                                       age: age)
        return (preparer, cloud)
    }

    // MARK: Store

    func testAgeStoreHasNoDefaultAndPersistsAcrossReloads() {
        let storage = InMemoryPaidVoiceAgeStorage()
        let first = PaidVoiceAgeStore(storage: storage)
        XCTAssertEqual(first.answer, .unanswered)
        XCTAssertFalse(first.isAdultConfirmed)
        first.record(isAdult: true)
        XCTAssertEqual(first.answer, .adult)
        XCTAssertTrue(first.isAdultConfirmed)
        XCTAssertEqual(PaidVoiceAgeStore(storage: storage).answer, .adult, "the same storage reloads as a yes")
        first.record(isAdult: false)
        XCTAssertEqual(PaidVoiceAgeStore(storage: storage).answer, .notAdult)
        first.clear()
        XCTAssertEqual(PaidVoiceAgeStore(storage: storage).answer, .unanswered)
        XCTAssertFalse(PaidVoiceAgeStore(storage: storage).isAdultConfirmed)
        storage.writeAnswer("maybe")
        XCTAssertEqual(PaidVoiceAgeStore(storage: storage).answer, .unanswered, "unknown values are not a yes")
    }

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

    // MARK: requiringAdult / compose

    func testAgeIsAskedFirstAndANoNeverReadsConsentOrPro() async {
        for answer in [PaidVoiceAgeAnswer.unanswered, .notAdult] {
            let consent = CountingConsent(true)
            let entitlement = CountingEntitlementForAge(pro)
            let access = ProVoiceAccess(entitlement: entitlement, consent: consent).requiringAdult(FixedAge(answer))
            let decision = await access.decision()
            XCTAssertEqual(decision, .denied(.ageNotConfirmed), "\(answer)")
            XCTAssertEqual(consent.reads, 0, "\(answer): consent is not asked")
            XCTAssertEqual(entitlement.reads, 0, "\(answer): Pro is not asked")
        }
    }

    func testOnlyAgeYesWithConsentAndProIsAllowed() async {
        let access = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true))
            .requiringAdult(FixedAge(.adult))
        let _got1 = await access.decision()
        XCTAssertEqual(_got1, .allowed)
        let noConsent = ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(false))
            .requiringAdult(FixedAge(.adult))
        let _got2 = await noConsent.decision()
        XCTAssertEqual(_got2, .denied(.noConsent))
        let free = ProVoiceAccess(entitlement: FixedEntitlement(.free), consent: FixedConsent(true))
            .requiringAdult(FixedAge(.adult))
        let _got3 = await free.decision()
        XCTAssertEqual(_got3, .denied(.notPro))
    }

    func testComposeOmitsWithTheNewReasonAndKeepsPaidDisabledFirst() async {
        let denied = await ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true))
            .requiringAdult(FixedAge(.unanswered)).decision()
        XCTAssertEqual(denied, .denied(.ageNotConfirmed))
        let omitted = compose(denied)
        XCTAssertEqual(omitted.decision, .omitted(.ageNotConfirmed))
        XCTAssertEqual(omitted.routes.map(\.providerID), ["device"])
        let disabled = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: false,
                                                  access: denied, selectedVoiceID: voiceID, credentials: creds)
        XCTAssertEqual(disabled.decision, .omitted(.paidDisabled), "paidDisabled still wins first")
        let allowed = compose(.allowed)
        XCTAssertEqual(allowed.decision, .included(catalogIndex: 0))
        XCTAssertEqual(allowed.routes.first?.providerID, PremiumVoiceRoutes.providerID)
    }

    // MARK: Per-break render, drop, take, re-prepare

    func testUnansweredOrNoKeepsTheBreakOnDevice() async {
        for answer in [PaidVoiceAgeAnswer.unanswered, .notAdult] {
            let age = store(answer)
            let (p, cloud) = rig(age: age)
            await p.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
            let _got4 = providers(await readyOutcome(p, 0))
            XCTAssertEqual(_got4, ["device"], "\(answer)")
            XCTAssertEqual(cloud.calls, 0, "\(answer)")
        }
    }

    func testYesWithConsentRendersOnTheCloudRoute() async {
        let age = store(.adult)
        let (p, cloud) = rig(age: age)
        await p.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        let _got5 = providers(await readyOutcome(p, 0))
        XCTAssertEqual(_got5, ["cloud"])
        XCTAssertEqual(cloud.calls, 1)
    }

    func testYesMidSessionPutsTheNextBreakOnTheCloudRoute() async {
        let age = store(.unanswered)
        let (p, cloud) = rig(age: age)
        await p.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        let _got6 = providers(await readyOutcome(p, 0))
        XCTAssertEqual(_got6, ["device"])
        XCTAssertEqual(cloud.calls, 0)
        age.record(isAdult: true)
        await p.prepare(presenterBreak(afterTrack: 1), deadline: .seconds(10), onDeviceOnly: false)
        let _got7 = providers(await readyOutcome(p, 1))
        XCTAssertEqual(_got7, ["cloud"])
        XCTAssertEqual(cloud.calls, 1)
    }

    func testAYesBetweenCuesNeverSwitchesVoicesMidBreak() async {
        let age = store(.unanswered)
        let (p, cloud) = rig(age: age, onDeviceRender: { age.record(isAdult: true) })
        await p.prepare(presenterBreak(afterTrack: 0, lines: 2), deadline: .seconds(10), onDeviceOnly: false)
        let _got8 = providers(await readyOutcome(p, 0))
        XCTAssertEqual(age.answer, .adult, "the yes landed while cue 1 rendered")
        XCTAssertEqual(_got8, ["device", "device"])
        XCTAssertEqual(cloud.calls, 0, "no cloud call in the break that started without a yes")
        await p.prepare(presenterBreak(afterTrack: 1, lines: 2), deadline: .seconds(10), onDeviceOnly: false)
        let _got9 = providers(await readyOutcome(p, 1))
        XCTAssertEqual(_got9, ["cloud", "cloud"])
        XCTAssertEqual(cloud.calls, 2)
    }

    func testClearingOrChangingTheAgeAnswerDropsAPreparedCloudBreak() async {
        let age = store(.adult)
        let (p, _) = rig(age: age)
        await p.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        let _got10 = providers(await readyOutcome(p, 0))
        XCTAssertEqual(_got10, ["cloud"])
        age.record(isAdult: false)
        let dropped = await p.dropCloudVoiceBreaks()
        XCTAssertEqual(dropped, [0])
        let _got11 = await p.takeBreak(afterTrack: 0)
        XCTAssertEqual(_got11, .skipped(.paidVoiceRevoked))
    }

    func testTakeRechecksTheAgeAnswer() async {
        let age = store(.adult)
        let (p, _) = rig(age: age)
        await p.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        let _got12 = providers(await readyOutcome(p, 0))
        XCTAssertEqual(_got12, ["cloud"])
        age.clear()
        // No eager drop: the take must still refuse the prepared cloud break.
        let _got13 = await p.takeBreak(afterTrack: 0)
        XCTAssertEqual(_got13, .skipped(.paidVoiceRevoked))
    }

    func testReleaseOnlyAfterAGrantAndOnlyForABreakPreparedWhileDenied() async {
        let age = store(.unanswered)
        let (p, _) = rig(age: age)
        await p.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        _ = await readyOutcome(p, 0)
        let stillDenied = await p.releaseBreakPreparedWhileDenied(afterTrack: 0)
        XCTAssertFalse(stillDenied, "no grant yet")
        age.record(isAdult: true)
        let released = await p.releaseBreakPreparedWhileDenied(afterTrack: 0)
        XCTAssertTrue(released)
        let cleared = await p.testResult(afterTrack: 0)
        XCTAssertNil(cleared, "ready to prepare again")
    }

    @MainActor
    func testYesThenAccessChangedPreparesThePlayingBreakAgainOnTheCloudRoute() async {
        let age = store(.unanswered)
        let (p, cloud) = rig(age: age)
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let session = DJBreakSession(preparer: p, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await session.start()
        await session.queueStarted(djTracks(8))
        guard let k = session.plannedBoundaries.first else { return XCTFail("no break planned") }
        await session.songStarted(index: k, remaining: .seconds(180))
        let first = await readyOutcome(p, k)
        XCTAssertEqual(Set(providers(first)), ["device"])
        XCTAssertEqual(cloud.calls, 0)
        age.record(isAdult: true)
        await session.paidVoiceAccessChanged()
        let again = await readyOutcome(p, k)
        XCTAssertTrue(providers(again).contains("cloud"), "prepared again with the cloud voice")
        XCTAssertGreaterThan(cloud.calls, 0)
        let handed = await session.naturalBoundary(afterTrack: k)
        XCTAssertTrue(handed?.clips.contains { $0.audio.providerID == "cloud" } ?? false,
                      "the next boundary plays the cloud voice, no relaunch")
    }

    @MainActor
    func testYesTooCloseToTheBoundaryKeepsTheOnDeviceBreak() async {
        let age = store(.unanswered)
        let (p, cloud) = rig(age: age)
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let session = DJBreakSession(preparer: p, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await session.start()
        await session.queueStarted(djTracks(8))
        guard let k = session.plannedBoundaries.first else { return XCTFail("no break planned") }
        await session.songStarted(index: k, remaining: .seconds(15))
        let first = await readyOutcome(p, k)
        XCTAssertEqual(Set(providers(first)), ["device"])
        age.record(isAdult: true)
        await session.paidVoiceAccessChanged()
        let kept = await p.testResult(afterTrack: k)
        XCTAssertEqual(kept, first, "kept as prepared")
        XCTAssertEqual(cloud.calls, 0)
    }

    @MainActor
    private func sessionWithAge(_ age: PaidVoiceAgeStore, now: @escaping () -> Date = { Date() }) async -> (DJBreakSession, DJBreakPreparer, AgeCloudFake) {
        let (p, cloud) = rig(age: age)
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let session = DJBreakSession(preparer: p, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 }, now: now)
        await session.start()
        await session.queueStarted(djTracks(8))
        return (session, p, cloud)
    }

    /// Fry: `playingRemaining` is a snapshot; a grant mid-song must subtract elapsed time
    /// (`now() - snapshotAt`) before the 20 s lead check. 60 s start, margin 3 s, lead 20 s:
    /// remaining must be at least 23 s to re-prepare. 30 s elapsed still qualifies; 45 s does not.
    @MainActor
    func testAGrantUsesElapsedTimeFromTheRemainingSnapshot() async {
        for (elapsed, shouldUpgrade) in [(30.0, true), (45.0, false)] {
            let clock = AdjustableClock()
            let age = store(.unanswered)
            let (session, p, cloud) = await sessionWithAge(age, now: { clock.now })
            guard let k = session.plannedBoundaries.first else { return XCTFail("no break planned") }
            await session.songStarted(index: k, remaining: .seconds(60))
            let first = await readyOutcome(p, k)
            XCTAssertEqual(Set(providers(first)), ["device"], "\(elapsed)")
            XCTAssertEqual(cloud.calls, 0, "\(elapsed)")
            clock.advance(seconds: elapsed)
            age.record(isAdult: true)
            await session.paidVoiceAccessChanged()
            if shouldUpgrade {
                let again = await readyOutcome(p, k)
                XCTAssertTrue(providers(again).contains("cloud"), "\(elapsed)s elapsed should re-prepare")
                XCTAssertGreaterThan(cloud.calls, 0, "\(elapsed)")
            } else {
                let kept = await p.testResult(afterTrack: k)
                XCTAssertEqual(kept, first, "\(elapsed)s elapsed is too close; kept on-device")
                XCTAssertEqual(cloud.calls, 0, "\(elapsed)")
            }
        }
    }

    func testGatedRendererScopeIsNoLinesUntilAYes() {
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let age = self.store(.unanswered)
        let renderer = VoiceRenderer(routes: device(), budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache()).gated(by: store, age: age)
        XCTAssertEqual(renderer.cloudScope(), .noLines)
        age.record(isAdult: true)
        XCTAssertEqual(renderer.cloudScope(), store.scope)
        age.record(isAdult: false)
        XCTAssertEqual(renderer.cloudScope(), .noLines)
    }

    /// The gate is opt-in and unwired until #281's age step lands. `gated(by:)`, compose,
    /// and a preparer with no age argument must keep the 9a1e0242 consent-only rule when
    /// consent is granted. This would fail if the default age were `NoPaidVoiceAgeAnswer`
    /// (unanswered), which would pin the scope at `.noLines` and keep the break on-device.
    func testExistingConsentPathWithNoAgeProviderStillAllowsTheCloudVoice() async {
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let cloud = AgeCloudFake()
        let renderer = VoiceRenderer(
            routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice, leavesDevice: true),
                     VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
            budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
            .gated(by: store)
        XCTAssertEqual(renderer.cloudScope(), store.scope)
        XCTAssertNotEqual(renderer.cloudScope(), .noLines, "consent granted, no age wired")

        let decision = await ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: FixedConsent(true)).decision()
        XCTAssertEqual(decision, .allowed)
        let composition = compose(decision)
        XCTAssertEqual(composition.decision, .included(catalogIndex: 0), "compose has no implicit age omit")
        XCTAssertEqual(composition.routes.first?.providerID, PremiumVoiceRoutes.providerID)

        let p = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", talkOverEnabled: { false },
                                cloudVoiceConsent: { store.isGranted })
        await p.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        let used = providers(await readyOutcome(p, 0))
        XCTAssertEqual(used, ["cloud"])
        XCTAssertEqual(cloud.calls, 1)
    }
}
