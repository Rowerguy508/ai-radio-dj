import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

// The "Are you 18 or older?" step (-Nova, on Fry's #267 API). In-memory storage and fakes only:
// no Keychain, no network, no proxy, no paid service.

/// Records each `accessChanged` call with the stored answer at that moment (write comes first).
@MainActor
private final class AccessChangedSpy {
    private(set) var answersSeen: [PaidVoiceAgeAnswer] = []
    let storage: InMemoryPaidVoiceAgeStorage
    init(_ storage: InMemoryPaidVoiceAgeStorage) { self.storage = storage }
    var calls: Int { answersSeen.count }
    func called() { answersSeen.append(PaidVoiceAgeStore(storage: storage).answer) }
}

/// Counts proxy requests and answers with fake audio.
private final class StepSpyTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        let headers = ["Content-Type": "audio/wav", "X-Audio-Duration": "1.5", "X-Billed-Characters": "20"]
        return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

private struct StepFakeSession: PaidVoiceInstallSessionProviding {
    func installSessionCredentials() -> PremiumProxyCredentials? {
        PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "fake-install-session")
    }
}

@MainActor
final class PaidVoiceAgeStepTests: XCTestCase {
    private let id = ProSubscriptionConfig.monthlyProductID
    private var epoch: Date { Date(timeIntervalSince1970: 0) }
    private var pro: ProEntitlementState { .pro(productID: id, expiresAt: .distantFuture) }

    private func model(_ access: ProVoiceAccess, answer: PaidVoiceAgeAnswer = .unanswered)
        -> (PaidVoiceAgeStepModel, AccessChangedSpy, InMemoryPaidVoiceAgeStorage) {
        let storage = InMemoryPaidVoiceAgeStorage()
        let store = PaidVoiceAgeStore(storage: storage)
        switch answer {
        case .unanswered: break
        case .adult: store.record(isAdult: true)
        case .notAdult: store.record(isAdult: false)
        }
        let spy = AccessChangedSpy(storage)
        let m = PaidVoiceAgeStepModel(store: store, accessWithoutAge: access, accessChanged: { spy.called() })
        return (m, spy, storage)
    }

    // MARK: When the step appears

    func testOfferedOnlyWhenProAndConsentAllowAndAgeIsUnanswered() async {
        let cases: [(ProVoiceAccess, String, Bool)] = [
            (.testing(pro, consent: true), "pro + consent", true),
            (.testing(pro, consent: false), "pro, no consent", false),
            (.testing(.free, consent: true), "free + consent", false),
            (.testing(.free, consent: false), "free", false),
            (.testing(.pro(productID: id, expiresAt: epoch), consent: true), "pro past expiry", false),
            (.testing(.expired(productID: id, expiredAt: epoch), consent: true), "expired", false),
            (.testing(.revoked(productID: id, revokedAt: epoch), consent: true), "revoked", false),
            (.testing(.unverified(productID: id), consent: true), "unverified", false),
            (.none, "build default (none)", false),
        ]
        for (access, name, offered) in cases {
            let (m, spy, _) = model(access)
            XCTAssertFalse(m.offersStep, "\(name): nothing offered before refresh")
            await m.refresh()
            XCTAssertEqual(m.offersStep, offered, name)
            XCTAssertEqual(m.showsChangeEntry, offered, "\(name): free listeners never see an age entry")
            XCTAssertEqual(spy.calls, 0, "\(name): showing the step changes nothing")
        }
    }

    func testAnAnswerAlreadyGivenIsNotAskedAgainButCanBeChanged() async {
        for answer in [PaidVoiceAgeAnswer.adult, .notAdult] {
            let (m, _, _) = model(.testing(pro, consent: true), answer: answer)
            await m.refresh()
            XCTAssertFalse(m.offersStep, "\(answer)")
            XCTAssertTrue(m.showsChangeEntry, "\(answer): change it later")
            XCTAssertEqual(m.answer, answer)
            // Even without Pro, a stored answer can still be changed or cleared.
            let (free, _, _) = model(.testing(.free, consent: false), answer: answer)
            await free.refresh()
            XCTAssertFalse(free.offersStep)
            XCTAssertTrue(free.showsChangeEntry, "\(answer): an answer on record can be cleared without Pro")
        }
    }

    func testDecisionMappingCountsOnlyAllowed() {
        XCTAssertTrue(PaidVoiceAgeStepModel.otherwiseAllows(.allowed))
        for denial in [ProVoiceGate.Denial.noConsent, .notPro, .unverified, .expired, .revoked, .ageNotConfirmed] {
            XCTAssertFalse(PaidVoiceAgeStepModel.otherwiseAllows(.denied(denial)), denial.rawValue)
        }
        XCTAssertTrue(PaidVoiceAgeStepModel.offersStep(paidVoiceOtherwiseAllowed: true, answer: .unanswered))
        XCTAssertFalse(PaidVoiceAgeStepModel.offersStep(paidVoiceOtherwiseAllowed: false, answer: .unanswered))
        XCTAssertFalse(PaidVoiceAgeStepModel.offersStep(paidVoiceOtherwiseAllowed: true, answer: .adult))
        XCTAssertFalse(PaidVoiceAgeStepModel.offersStep(paidVoiceOtherwiseAllowed: true, answer: .notAdult))
    }

    func testRefreshFollowsTheGateAndTheStore() async {
        let consent = SwitchableConsent(false)
        let storage = InMemoryPaidVoiceAgeStorage()
        let m = PaidVoiceAgeStepModel(store: PaidVoiceAgeStore(storage: storage),
                                      accessWithoutAge: ProVoiceAccess(entitlement: FixedEntitlement(pro), consent: consent),
                                      accessChanged: {})
        await m.refresh()
        XCTAssertFalse(m.offersStep)
        consent.set(true)
        await m.refresh()
        XCTAssertTrue(m.offersStep, "consent given: the step appears")
        PaidVoiceAgeStore(storage: storage).record(isAdult: true)
        await m.refresh()
        XCTAssertEqual(m.answer, .adult)
        XCTAssertFalse(m.offersStep, "answered elsewhere: not asked")
    }

    // MARK: Answers go through record / clear, then paidVoiceAccessChanged

    func testYesRecordsThenCallsAccessChanged() async {
        let (m, spy, storage) = model(.testing(pro, consent: true))
        await m.refresh()
        await m.answer(isAdult: true)
        XCTAssertEqual(storage.readAnswer(), "yes")
        XCTAssertEqual(PaidVoiceAgeStore(storage: storage).answer, .adult)
        XCTAssertEqual(spy.answersSeen, [.adult], "one access change, after the write")
        XCTAssertEqual(m.answer, .adult)
        XCTAssertFalse(m.offersStep)
        XCTAssertEqual(m.confirmation, "Thanks. Your DJ can use the Pro voice from the next break.")
    }

    func testNoRecordsThenCallsAccessChangedAndKeepsTheOnDeviceVoice() async {
        let (m, spy, storage) = model(.testing(pro, consent: true))
        await m.refresh()
        await m.answer(isAdult: false)
        XCTAssertEqual(storage.readAnswer(), "no")
        XCTAssertEqual(spy.answersSeen, [.notAdult])
        XCTAssertEqual(m.answer, .notAdult)
        XCTAssertFalse(m.offersStep, "a no is not asked again")
        XCTAssertTrue(m.showsChangeEntry, "and can be changed later")
        XCTAssertEqual(m.confirmation, "Saved. Your DJ uses the on-device voice from now on.")
    }

    func testChangingTheAnswerLaterRecordsEachTime() async {
        let (m, spy, storage) = model(.testing(pro, consent: true), answer: .notAdult)
        await m.refresh()
        await m.answer(isAdult: true)
        await m.answer(isAdult: false)
        await m.clearAnswer()
        XCTAssertNil(storage.readAnswer(), "clear() deletes the stored answer")
        XCTAssertEqual(spy.answersSeen, [.adult, .notAdult, .unanswered], "each write, then its access change")
        XCTAssertEqual(m.answer, .unanswered)
        XCTAssertFalse(m.offersStep, "cleared from the entry: not asked again this launch")
        XCTAssertTrue(m.showsChangeEntry, "Pro + consent: the entry stays to answer again")
        XCTAssertEqual(m.confirmation, "Answer cleared. Your DJ uses the on-device voice until you answer again.")
    }

    func testDismissWritesNothingAndChangesNoAccess() async {
        let (m, spy, storage) = model(.testing(pro, consent: true))
        await m.refresh()
        XCTAssertTrue(m.offersStep)
        m.dismiss()
        XCTAssertNil(storage.readAnswer(), "Not now stores nothing")
        XCTAssertEqual(spy.calls, 0, "Not now changes no access")
        XCTAssertFalse(m.offersStep, "not asked again this launch")
        XCTAssertTrue(m.showsChangeEntry, "the entry still lets them answer")
        XCTAssertEqual(m.answer, .unanswered)
        await m.refresh()
        XCTAssertFalse(m.offersStep, "a refresh does not bring it back this launch")
        // Next launch (a new model over the same storage): asked again, since it was never answered.
        let next = PaidVoiceAgeStepModel(store: PaidVoiceAgeStore(storage: storage),
                                         accessWithoutAge: .testing(pro, consent: true), accessChanged: {})
        await next.refresh()
        XCTAssertTrue(next.offersStep)
    }

    func testYesWithoutProOrConsentNeverPromisesThePaidVoice() async {
        let (m, spy, _) = model(.testing(.free, consent: false), answer: .notAdult)
        await m.refresh()
        await m.answer(isAdult: true)
        XCTAssertEqual(spy.answersSeen, [.adult])
        XCTAssertEqual(m.confirmation,
                       "Saved. The Pro voice also needs an active Pro plan and your OK to use the cloud voice.")
    }

    func testBeginReviewClearsTheOldResultLine() async {
        let (m, _, _) = model(.testing(pro, consent: true))
        await m.refresh()
        await m.answer(isAdult: false)
        XCTAssertNotNil(m.confirmation)
        m.beginReview()
        XCTAssertNil(m.confirmation)
    }

    // MARK: Copy

    func testCopyIsTruthfulAboutTimingAndNeverGatesFreeFeatures() {
        let yes = PaidVoiceAgeStepCopy.confirmation(after: .adult, paidVoiceOtherwiseAllowed: true)
        XCTAssertTrue(yes.contains("from the next break"), "a yes is used from the next break")
        var all = [PaidVoiceAgeStepCopy.title, PaidVoiceAgeStepCopy.detail, PaidVoiceAgeStepCopy.footer,
                   PaidVoiceAgeStepCopy.yes, PaidVoiceAgeStepCopy.no, PaidVoiceAgeStepCopy.notNow,
                   PaidVoiceAgeStepCopy.clear, PaidVoiceAgeStepCopy.entryTitle, PaidVoiceAgeStepCopy.navigationTitle]
        for answer in PaidVoiceAgeAnswer.allCases {
            all.append(PaidVoiceAgeStepCopy.currentAnswer(answer))
            for allowed in [true, false] {
                all.append(PaidVoiceAgeStepCopy.confirmation(after: answer, paidVoiceOtherwiseAllowed: allowed))
            }
        }
        for line in all {
            let lower = line.lowercased()
            for banned in ["launch", "restart", "relaunch", "instant", "immediately", "right away", "[owner]", "[pending]"] {
                XCTAssertFalse(lower.contains(banned), "\(line) must not say \(banned)")
            }
        }
        XCTAssertTrue(PaidVoiceAgeStepCopy.footer.contains("on-device voice"))
        XCTAssertTrue(PaidVoiceAgeStepCopy.footer.contains("works the same"), "a no never blocks free features")
        XCTAssertTrue(PaidVoiceAgeStepCopy.detail.contains("18"))
        XCTAssertTrue(PaidVoiceAgeStepCopy.detail.contains("stays on this device"))
        XCTAssertEqual(PaidVoiceAgeStepCopy.currentAnswer(.adult), "Your answer: 18 or older")
        XCTAssertEqual(PaidVoiceAgeStepCopy.currentAnswer(.notAdult), "Your answer: under 18")
        XCTAssertEqual(PaidVoiceAgeStepCopy.currentAnswer(.unanswered), "Your answer: not answered")
    }

    // MARK: End to end with the real session (Fry's paidVoiceAccessChanged)

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

    private func readyProviders(_ p: DJBreakPreparer, _ k: Int) async -> [String] {
        for _ in 0..<500 {
            if case .ready(let prepared)? = await p.testResult(afterTrack: k) { return prepared.clips.map(\.audio.providerID) }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return []
    }

    func testStepAnswersReachTheSessionYesUpgradesTheNextBreakAndNoDropsIt() async {
        let storage = InMemoryPaidVoiceAgeStorage()
        let store = PaidVoiceAgeStore(storage: storage)
        let access = ProVoiceAccess.testing(pro, consent: true)
        let t = StepSpyTransport()
        let base = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                 budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                                 revocations: NarrationRevocations())
        let voice = PaidVoice.publicComposition(base: base, access: access, age: store,
                                                selectedVoiceID: PremiumVoiceCatalog.voices[0].id,
                                                session: StepFakeSession(), routeCompiledIn: true, transport: t)
        let (s, p) = await session(voice)
        let m = PaidVoiceAgeStepModel(store: store, accessWithoutAge: access,
                                      accessChanged: { await s.paidVoiceAccessChanged() })
        await m.refresh()
        XCTAssertTrue(m.offersStep)
        guard let k = s.plannedBoundaries.first else { return XCTFail("no break planned") }
        await s.songStarted(index: k, remaining: .seconds(180))
        let before = await readyProviders(p, k)
        XCTAssertTrue(!before.isEmpty && before.allSatisfy { $0 == "device" }, "unanswered: on-device")
        XCTAssertEqual(t.calls, 0, "no proxy call before a yes")

        await m.answer(isAdult: true)
        let upgraded = await readyProviders(p, k)
        XCTAssertTrue(upgraded.contains(PremiumVoiceRoutes.providerID), "the yes is used from the next break")

        let calls = t.calls
        await m.answer(isAdult: false)
        let replanned = await readyProviders(p, k)
        XCTAssertTrue(!replanned.isEmpty && replanned.allSatisfy { $0 == "device" }, "a no applies at once")
        XCTAssertEqual(t.calls, calls, "no proxy call after the no")
    }
}
