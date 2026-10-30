import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

// E1 wiring (-Nova): the paywall and the consent sheet call DJBreakSession.paidVoiceAccessChanged()
// through PaidVoiceAccessRelay, only when access really changes. Fakes only: no StoreKit, no
// network, no proxy, no paid service.

@MainActor private final class Counter { var count = 0 }

private final class RevokedBoundaries: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ k: Int) { lock.withLock { values.append(k) } }
    var all: [Int] { lock.withLock { values } }
}

/// A clock tests move by hand (the tracker's, the cache's and the gate's `now`).
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// The expiry scheduler, by hand: records each armed timer; a test fires one when it likes.
@MainActor private final class ManualExpiryTimers {
    final class Timer {
        let date: Date
        let fire: @MainActor @Sendable () async -> Void
        var cancelled = false
        init(date: Date, fire: @escaping @MainActor @Sendable () async -> Void) { self.date = date; self.fire = fire }
    }
    private(set) var all: [Timer] = []
    var pending: [Timer] { all.filter { !$0.cancelled } }

    var scheduler: PaidVoiceExpiryScheduler {
        { [self] date, fire in
            let timer = Timer(date: date, fire: fire)
            all.append(timer)
            return { timer.cancelled = true }
        }
    }
}

/// Proxy transport stand-in: counts requests, answers with fake audio.
private final class CountingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        let headers = ["Content-Type": "audio/wav", "X-Audio-Duration": "1.5", "X-Billed-Characters": "20"]
        return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

private struct FakeInstallSession: PaidVoiceInstallSessionProviding {
    func installSessionCredentials() -> PremiumProxyCredentials? {
        PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "fake-install-session")
    }
}

/// Stands in for a StoreKit read that never answers (`Transaction.currentEntitlements` or
/// `Transaction.latest` stuck on the App Store). Iterating it suspends until cancelled.
private func storeKitThatNeverAnswers() -> AsyncStream<Int> { AsyncStream { _ in } }

/// A refresh shaped like SubscriptionModel.refreshStatus: reads StoreKit, then sets the cache.
/// Here the read never completes, so the cache keeps whatever it held.
private func hungRefresh(_ cache: ProEntitlementCache) -> Task<Void, Never> {
    Task.detached {
        for await _ in storeKitThatNeverAnswers() {}
        if !Task.isCancelled { cache.set(.free) }
    }
}

/// Negative control: a provider that waits on the refresh, the shape Sentinel ruled out.
private struct AwaitsRefreshEntitlement: ProEntitlementProviding {
    let refresh: Task<Void, Never>
    let cache: ProEntitlementCache
    func currentProEntitlement() async -> ProEntitlementState { await refresh.value; return cache.snapshot() }
}

private final class AnswerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// The value of `op`, or nil if it has not answered within `seconds`. Never waits on a hung `op`.
private func within<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
    let once = AnswerOnce()
    return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
        Task.detached { let v = await op(); if once.claim() { c.resume(returning: v) } }
        Task.detached { try? await Task.sleep(for: .seconds(seconds)); if once.claim() { c.resume(returning: nil) } }
    }
}

@MainActor
final class PaidVoiceAccessSignalsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let monthly = ProSubscriptionConfig.monthlyProductID
    private let yearly = ProSubscriptionConfig.yearlyProductID

    private func pro(_ id: String? = nil, for seconds: TimeInterval = 3600) -> ProEntitlementState {
        .pro(productID: id ?? monthly, expiresAt: now.addingTimeInterval(seconds))
    }

    private func tracker() -> (ProAccessChangeTracker, Counter) {
        let counter = Counter()
        return (ProAccessChangeTracker(notify: { counter.count += 1 }, schedule: ManualExpiryTimers().scheduler,
                                       now: { [now] in now }), counter)
    }

    private func signals(_ store: CloudVoiceConsentStore) -> (PaidVoiceConsentSignals, Counter) {
        let counter = Counter()
        return (PaidVoiceConsentSignals(store: store, notify: { counter.count += 1 }), counter)
    }

    // MARK: SubscriptionModel's reads (Transaction.updates, purchase, restore/re-sync)

    func testProFlipFiresOnceEachWay() async {
        let (t, c) = tracker()
        let toPro = await t.entitlementRead(pro(), now: now)
        XCTAssertTrue(toPro)
        XCTAssertEqual(c.count, 1, "Free to Pro notifies once")
        let renewed = await t.entitlementRead(pro(yearly, for: 86_400), now: now)
        XCTAssertFalse(renewed, "a renewal or plan change is still Pro: no change")
        XCTAssertEqual(c.count, 1)
        let refunded = await t.entitlementRead(.revoked(productID: monthly, revokedAt: now), now: now)
        XCTAssertTrue(refunded)
        XCTAssertEqual(c.count, 2, "Pro to refunded notifies once")
        _ = await t.entitlementRead(.revoked(productID: monthly, revokedAt: now), now: now)
        _ = await t.entitlementRead(.expired(productID: monthly, expiredAt: now), now: now)
        XCTAssertEqual(c.count, 2, "staying not-Pro does not notify again")
    }

    func testUnchangedRefreshDoesNotFire() async {
        let (t, c) = tracker()
        for state: ProEntitlementState in [.free, .free, .unverified(productID: monthly),
                                           .expired(productID: monthly, expiredAt: now)] {
            let fired = await t.entitlementRead(state, now: now)
            XCTAssertFalse(fired, "\(state)")
        }
        _ = await t.entitlementRead(pro(), now: now)
        _ = await t.entitlementRead(pro(), now: now)
        XCTAssertEqual(c.count, 1, "the same Pro read twice (restore after launch) notifies once")
    }

    func testProPastOrWithoutExpiryIsNotAChange() async {
        let (t, c) = tracker()
        _ = await t.entitlementRead(.pro(productID: monthly, expiresAt: nil), now: now)
        _ = await t.entitlementRead(pro(for: -1), now: now)
        XCTAssertEqual(c.count, 0, "#244's gate denies both, so the effective state stays not-Pro")
    }

    func testFamilySharedStaysNotProAndDoesNotFire() async {
        let shared = ProTransactionSnapshot(productID: yearly, purchaseDate: now.addingTimeInterval(-86_400),
                                            expirationDate: now.addingTimeInterval(3600), ownership: .familyShared)
        let state = ProEntitlementMapper.state(for: [shared], now: now)
        XCTAssertEqual(state, .free)
        XCTAssertTrue(ProStoreEntitlement.onlyFamilyShared([shared]))
        let (t, c) = tracker()
        let fired = await t.entitlementRead(state, now: now)
        XCTAssertFalse(fired)
        XCTAssertEqual(c.count, 0)
        let decision = await ProVoiceAccess(entitlement: ProEntitlementCache(state, now: { [now] in now }),
                                            consent: CloudVoiceConsentStore.inMemory(.accepted)).decision()
        XCTAssertFalse(decision.permitsPaidVoice)
    }

    // MARK: Consent sheet writes

    func testConsentGrantFiresOnce() async {
        let store = CloudVoiceConsentStore.inMemory()
        let (s, c) = signals(store)
        await s.accept()?.value
        XCTAssertTrue(store.isGranted, "the write is synchronous, as before")
        XCTAssertEqual(c.count, 1)
        XCTAssertNil(s.accept(), "accepting again is no change")
        XCTAssertEqual(c.count, 1)
    }

    func testConsentRevokeFiresOnce() async {
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let (s, c) = signals(store)
        await s.decline()?.value
        XCTAssertFalse(store.isGranted)
        XCTAssertEqual(c.count, 1)
        XCTAssertNil(s.decline())
        XCTAssertEqual(c.count, 1)
    }

    func testDecliningWhenNeverGrantedDoesNotFire() async {
        let store = CloudVoiceConsentStore.inMemory()
        let (s, c) = signals(store)
        XCTAssertNil(s.decline())
        XCTAssertEqual(store.state, .declined)
        XCTAssertEqual(c.count, 0)
    }

    // MARK: The default notifier is the real call

    func testRelayWithoutASessionIsANoOp() async {
        PaidVoiceAccessRelay.session = nil
        await PaidVoiceAccessRelay.notify()
    }

    /// Default notifier end to end: a consent revoke through PaidVoiceConsentSignals reaches the
    /// session, which re-prepares the playing song's break on-device with no further proxy call.
    func testDefaultNotifierReachesTheSessionOnRevoke() async {
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let access = ProVoiceAccess(entitlement: FixedEntitlement(.pro(productID: monthly, expiresAt: Date().addingTimeInterval(86_400))),
                                    consent: store)
        let transport = CountingTransport()
        let base = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                 budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                                 revocations: NarrationRevocations(), cloudConsent: store)
        let voice = PaidVoice.publicComposition(base: base, access: access, selectedVoiceID: PremiumVoiceCatalog.voices[0].id,
                                                session: FakeInstallSession(), routeCompiledIn: true, transport: transport)
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let preparer = DJBreakPreparer(voice: voice, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await session.start()
        await session.queueStarted(djTracks(8))
        PaidVoiceAccessRelay.session = session
        defer { PaidVoiceAccessRelay.session = nil }

        guard let k = session.plannedBoundaries.first else { return XCTFail("no break planned") }
        await session.songStarted(index: k, remaining: .seconds(180))
        _ = await outcome(preparer, k)
        XCTAssertGreaterThan(transport.calls, 0, "prepared with the paid route while allowed")
        let callsBefore = transport.calls

        await PaidVoiceConsentSignals(store: store).decline()?.value   // default notifier
        let replanned = await outcome(preparer, k)
        guard case .ready(let ready)? = replanned else { return XCTFail("the break is prepared again") }
        XCTAssertTrue(ready.clips.allSatisfy { $0.audio.providerID == "device" }, "and on-device")
        XCTAssertEqual(transport.calls, callsBefore)
    }

    // MARK: Expiry between refreshes (one timer, re-armed on every cache write; Fry's recommendation)

    private func expiryTracker(_ clock: TestClock, _ notify: @escaping PaidVoiceAccessNotify)
        -> (ProAccessChangeTracker, ManualExpiryTimers) {
        let timers = ManualExpiryTimers()
        return (ProAccessChangeTracker(notify: notify, schedule: timers.scheduler, now: { clock.now }), timers)
    }

    func testExpiryFiresOnceAtTheDate() async {
        let clock = TestClock(now), counter = Counter()
        let (t, timers) = expiryTracker(clock) { counter.count += 1 }
        let expiry = now.addingTimeInterval(3600)
        await t.entitlementRead(.pro(productID: monthly, expiresAt: expiry), now: clock.now)
        XCTAssertEqual(counter.count, 1, "Free to Pro")
        XCTAssertEqual(timers.pending.map(\.date), [expiry], "exactly one timer, at the expiry")

        clock.advance(1800)   // an early wake-up: still Pro, nothing reported, re-armed for the same date
        let early = timers.pending[0]
        early.cancelled = true
        await early.fire()
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(timers.pending.map(\.date), [expiry])

        clock.advance(1800)
        let atExpiry = timers.pending[0]
        atExpiry.cancelled = true
        await atExpiry.fire()
        XCTAssertEqual(counter.count, 2, "the lapse is reported once, at the date")
        XCTAssertTrue(timers.pending.isEmpty, "a lapsed Pro arms nothing")
        await atExpiry.fire()
        await early.fire()
        XCTAssertEqual(counter.count, 2, "replaced timers do nothing")
    }

    func testRenewalBeforeExpiryCancelsAndReArms() async {
        let clock = TestClock(now), counter = Counter()
        let (t, timers) = expiryTracker(clock) { counter.count += 1 }
        let first = now.addingTimeInterval(3600), renewed = now.addingTimeInterval(3600 + 30 * 86_400)
        await t.entitlementRead(.pro(productID: monthly, expiresAt: first), now: clock.now)
        let old = timers.pending[0]
        clock.advance(3000)
        await t.entitlementRead(.pro(productID: monthly, expiresAt: renewed), now: clock.now)
        XCTAssertTrue(old.cancelled, "the renewal cancels the old timer")
        XCTAssertEqual(timers.pending.map(\.date), [renewed], "and arms one at the new date")
        clock.advance(600)    // past the old date
        await old.fire()      // even if a cancelled timer still ran
        XCTAssertEqual(counter.count, 1, "the old date reports nothing")
        clock.advance(30 * 86_400)
        let current = timers.pending[0]
        current.cancelled = true
        await current.fire()
        XCTAssertEqual(counter.count, 2, "the renewed date does")
    }

    func testDowngradeCancelsTheTimer() async {
        let clock = TestClock(now), counter = Counter()
        let (t, timers) = expiryTracker(clock) { counter.count += 1 }
        let states: [ProEntitlementState] = [.free, .expired(productID: monthly, expiredAt: now),
                                             .unverified(productID: monthly), .revoked(productID: monthly, revokedAt: now),
                                             .pro(productID: monthly, expiresAt: nil)]
        for state in states {
            await t.entitlementRead(.pro(productID: monthly, expiresAt: now.addingTimeInterval(3600)), now: clock.now)
            let armed = timers.pending
            XCTAssertEqual(armed.count, 1)
            await t.entitlementRead(state, now: clock.now)
            XCTAssertTrue(armed.allSatisfy(\.cancelled), "\(state) cancels")
            XCTAssertTrue(timers.pending.isEmpty, "\(state) arms nothing")
            let before = counter.count
            clock.advance(7200)
            for timer in armed { await timer.fire() }
            XCTAssertEqual(counter.count, before, "\(state): a cancelled timer reports nothing")
            clock.advance(-7200)
        }
    }

    func testAnExpiryAlreadyPastIsJudgedRightAway() async {
        let clock = TestClock(now), counter = Counter()
        let (t, timers) = expiryTracker(clock) { counter.count += 1 }
        await t.entitlementRead(.pro(productID: monthly, expiresAt: now.addingTimeInterval(60)), now: clock.now)
        clock.advance(120)    // the app was asleep past the date; the next read carries the same state
        await t.entitlementRead(.pro(productID: monthly, expiresAt: now.addingTimeInterval(60)), now: clock.now)
        XCTAssertEqual(counter.count, 2, "reported right away")
        XCTAssertTrue(timers.pending.isEmpty, "nothing armed for a past date")
        await t.entitlementRead(.pro(productID: monthly, expiresAt: now.addingTimeInterval(60)), now: clock.now)
        XCTAssertEqual(counter.count, 2, "already reported: a no-op")
    }

    /// End to end: a paid break prepared while Pro is dropped when the expiry timer fires, and
    /// the session re-prepares it on-device with no further proxy call.
    func testAPreparedPaidBreakIsSkippedAfterTheExpiryNotification() async {
        let start = Date()
        let clock = TestClock(start)
        let expiry = start.addingTimeInterval(3600)
        let cache = ProEntitlementCache(.pro(productID: monthly, expiresAt: expiry), now: { clock.now })
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let access = ProVoiceAccess(entitlement: cache, consent: store, now: { clock.now })
        let transport = CountingTransport()
        let base = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                 budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                                 revocations: NarrationRevocations(), cloudConsent: store)
        let voice = PaidVoice.publicComposition(base: base, access: access, selectedVoiceID: PremiumVoiceCatalog.voices[0].id,
                                                session: FakeInstallSession(), routeCompiledIn: true, transport: transport)
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let preparer = DJBreakPreparer(voice: voice, userID: "u", stationID: "s", cadence: config.cadence())
        let revoked = RevokedBoundaries()
        await preparer.observe { event in
            if case .skipped(let k, .paidVoiceRevoked) = event { revoked.add(k) }
        }
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await session.start()
        await session.queueStarted(djTracks(8))
        let (tracker, timers) = expiryTracker(clock) { await session.paidVoiceAccessChanged() }
        await tracker.entitlementRead(cache.snapshot(), now: clock.now)   // SubscriptionModel's read after set

        guard let k = session.plannedBoundaries.first else { return XCTFail("no break planned") }
        await session.songStarted(index: k, remaining: .seconds(180))
        guard case .ready(let paid)? = await outcome(preparer, k) else { return XCTFail("prepared") }
        XCTAssertTrue(paid.clips.contains { $0.audio.providerID != "device" }, "with the paid route while Pro")
        XCTAssertTrue(revoked.all.isEmpty)
        let callsBefore = transport.calls

        clock.advance(3600)   // Pro lapses between refreshes; no StoreKit read happens
        guard let timer = timers.pending.first, timer.date == expiry else { return XCTFail("expiry timer armed") }
        await timer.fire()
        XCTAssertEqual(revoked.all, [k], "the prepared paid break is skipped as paidVoiceRevoked")
        guard case .ready(let replanned)? = await outcome(preparer, k) else { return XCTFail("prepared again") }
        XCTAssertTrue(replanned.clips.allSatisfy { $0.audio.providerID == "device" }, "on-device")
        XCTAssertEqual(transport.calls, callsBefore, "no proxy call after the lapse")
    }

    func testTheCacheHasOneAppWriterAndItReArms() throws {
        // The timer is re-armed by entitlementRead, so every cache write must be followed by one
        // (pinned in testSubscriptionModelNotifiesAfterEveryReadOnceTheCacheIsSet).
        let app = repoRoot.appendingPathComponent("ios/AeroDJ")
        var writers = 0
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            writers += source.components(separatedBy: "entitlement.set(").count - 1
            writers += source.components(separatedBy: "ProEntitlementCache.shared.set(").count - 1
        }
        XCTAssertEqual(writers, 1, "only SubscriptionModel.refreshStatus writes the cache")
    }

    // MARK: decision() answers from cached state (Sentinel on #255). takeCheckedBreak bounds the
    // check at 300 ms and fails closed (Echo, 2ed3ea6); these providers must answer well inside
    // that, from ProEntitlementCache and the stored consent, never after StoreKit.

    /// Inside the boundary's bound, DJBreakPreparer.paidVoiceTakeCheckTimeout (Echo, #255), in seconds.
    private var fastDecision: Double {
        let c = DJBreakPreparer.paidVoiceTakeCheckTimeout.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    func testDecisionAnswersFromTheCacheWhileAStoreKitRefreshNeverCompletes() async {
        let cache = ProEntitlementCache(.pro(productID: monthly, expiresAt: Date().addingTimeInterval(86_400)))
        let consent = CloudVoiceConsentStore.inMemory(.accepted)
        let refresh = hungRefresh(cache)
        defer { refresh.cancel() }
        let access = ProVoiceAccess(entitlement: cache, consent: consent)
        let clock = ContinuousClock(), start = clock.now
        let answer = await within(fastDecision) { await access.decision() }
        XCTAssertEqual(answer, .allowed, "answered from the cache, not after the refresh")
        XCTAssertLessThan(clock.now - start, DJBreakPreparer.paidVoiceTakeCheckTimeout, "inside the take-check bound")
        consent.decline()
        let revoked = await within(fastDecision) { await access.decision() }
        XCTAssertEqual(revoked, .denied(.noConsent), "the stored consent is read per call")
    }

    func testDecisionFailsClosedOnAnEmptyOrUnverifiedCacheWhileRefreshing() async {
        let empty = ProEntitlementCache()   // nothing read from StoreKit yet
        let refresh = hungRefresh(empty)
        defer { refresh.cancel() }
        let granted = CloudVoiceConsentStore.inMemory(.accepted)
        let none = await within(fastDecision) { await ProVoiceAccess(entitlement: empty, consent: granted).decision() }
        XCTAssertEqual(none, .denied(.notPro))
        let unverifiedCache = ProEntitlementCache(.unverified(productID: monthly))
        let unverified = await within(fastDecision) { await ProVoiceAccess(entitlement: unverifiedCache, consent: granted).decision() }
        XCTAssertEqual(unverified, .denied(.unverified))
        let pro = ProEntitlementCache(.pro(productID: monthly, expiresAt: Date().addingTimeInterval(86_400)))
        let undecided = await within(fastDecision) {
            await ProVoiceAccess(entitlement: pro, consent: CloudVoiceConsentStore.inMemory()).decision()
        }
        XCTAssertEqual(undecided, .denied(.noConsent), "no stored consent is no consent")
    }

    /// The harness does catch a provider that waits on StoreKit, so the two tests above can fail.
    func testAProviderThatAwaitsTheRefreshIsCaughtAsHung() async {
        let cache = ProEntitlementCache(.pro(productID: monthly, expiresAt: Date().addingTimeInterval(86_400)))
        let refresh = hungRefresh(cache)
        defer { refresh.cancel() }
        let access = ProVoiceAccess(entitlement: AwaitsRefreshEntitlement(refresh: refresh, cache: cache),
                                    consent: CloudVoiceConsentStore.inMemory(.accepted))
        let answer = await within(0.3) { await access.decision() }
        XCTAssertNil(answer)
    }

    /// End to end: the boundary re-check hands out a paid break mid-refresh. A provider that
    /// waited on StoreKit would hit Echo's 300 ms bound and be skipped, so `.ready` here proves
    /// the answer came from the cache in time.
    func testTakeCheckedBreakAnswersWhileAStoreKitRefreshNeverCompletes() async {
        let cache = ProEntitlementCache(.pro(productID: monthly, expiresAt: Date().addingTimeInterval(86_400)))
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let access = ProVoiceAccess(entitlement: cache, consent: store)
        let base = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                 budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                                 revocations: NarrationRevocations(), cloudConsent: store)
        let voice = PaidVoice.publicComposition(base: base, access: access, selectedVoiceID: PremiumVoiceCatalog.voices[0].id,
                                                session: FakeInstallSession(), routeCompiledIn: true,
                                                transport: CountingTransport())
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let preparer = DJBreakPreparer(voice: voice, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await session.start()
        await session.queueStarted(djTracks(8))
        let boundaries = session.plannedBoundaries
        guard boundaries.count >= 2 else { return XCTFail("two breaks planned") }
        for k in boundaries.prefix(2) {
            await session.songStarted(index: k, remaining: .seconds(180))
            guard case .ready? = await outcome(preparer, k) else { return XCTFail("break \(k) prepared") }
        }
        let refresh = hungRefresh(cache)
        defer { refresh.cancel() }

        let first = boundaries[0], second = boundaries[1]
        guard case .ready? = await within(1, { await preparer.takeCheckedBreak(afterTrack: first) }) else {
            return XCTFail("a paid break is handed out from the cached Pro state, mid-refresh")
        }
        cache.set(.free)   // what a completed refresh would write; the hung one never gets there
        let skipped = await within(1) { await preparer.takeCheckedBreak(afterTrack: second) }
        XCTAssertEqual(skipped, .skipped(.paidVoiceRevoked), "and skipped once the cache says not Pro")
    }

    private func outcome(_ preparer: DJBreakPreparer, _ k: Int) async -> DJBreakOutcome? {
        for _ in 0..<500 {
            if let r = await preparer.testResult(afterTrack: k) { return r }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    // MARK: App call sites (app target is iOS-only; these scans fail if a call is removed)

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testSubscriptionModelNotifiesAfterEveryReadOnceTheCacheIsSet() throws {
        let model = try text("ios/AeroDJ/Purchases/Subscriptions+App.swift")
        let refresh = model.components(separatedBy: "func refreshStatus() async {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        guard let set = refresh.range(of: "entitlement.set(state)"),
              let read = refresh.range(of: "await accessChanges.entitlementRead(state, now: Date())")
        else { return XCTFail("refreshStatus must set the cache and then report the read") }
        XCTAssertLessThan(set.lowerBound, read.lowerBound, "the session's re-check must see the new state")
        // Transaction.updates, purchase and restore all re-read through refreshStatus.
        XCTAssertGreaterThanOrEqual(model.components(separatedBy: "await self?.refreshStatus()").count - 1, 1)
        XCTAssertGreaterThanOrEqual(model.components(separatedBy: "await refreshStatus()").count - 1, 3)
        XCTAssertTrue(model.contains("self.accessChanges = accessChanges ?? ProAccessChangeTracker()"))
    }

    func testConsentModelGrantsAndRevokesThroughTheSignals() throws {
        let model = try text("ios/AeroDJ/CloudVoiceConsent+App.swift")
        XCTAssertTrue(model.contains("func accept() {\n        signals.accept()"))
        XCTAssertTrue(model.contains("func decline() {\n        signals.decline()"))
        XCTAssertFalse(model.contains("store.accept()"), "a direct write would skip the notification")
        XCTAssertFalse(model.contains("store.decline()"), "a direct write would skip the notification")
        XCTAssertTrue(model.contains("self.signals = signals ?? PaidVoiceConsentSignals(store: store)"))
    }

    /// The app's providers answer from cached state: the live gate is built on
    /// ProEntitlementCache.shared and the stored consent, and SubscriptionModel's provider reads
    /// only the cache snapshot (no StoreKit, no network, no Transaction.currentEntitlements).
    func testTheAppGateReadsOnlyCachedState() throws {
        let live = try text("ios/AeroDJ/OwnerVoiceTrial+App.swift")
            .components(separatedBy: "static var live: ProVoiceAccess {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertTrue(live.contains("ProVoiceAccess(entitlement: ProEntitlementCache.shared, consent: CloudVoiceConsentStore())"))
        let provider = try text("ios/AeroDJ/Purchases/Subscriptions+App.swift")
            .components(separatedBy: "nonisolated func currentProEntitlement() async -> ProEntitlementState {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? "missing"
        XCTAssertEqual(provider.trimmingCharacters(in: .whitespacesAndNewlines), "entitlement.snapshot()")
    }

    /// Deliberate seam (Fry B1 on #258): ProVoiceAccess.live is defined and tested, but the live
    /// voice still uses .buildDefault, so Release keeps paid voice locked. Wiring .live into
    /// PaidVoice.live() is a one-line follow-up that needs Sentinel and the owner; it must fail
    /// this test and update it on purpose.
    func testPaidVoiceLiveStillUsesBuildDefaultNotTheLiveGate() throws {
        let live = try text("ios/AeroDJ/PaidVoice+App.swift")
            .components(separatedBy: "static func live() -> PaidVoice {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertTrue(live.contains("publicComposition(base: base, access: .buildDefault,"))
        XCTAssertFalse(live.contains(".live"), "the live gate is not wired into PaidVoice.live() yet")
        // Nowhere else in the app hands the live gate to a composition either.
        let app = repoRoot.appendingPathComponent("ios/AeroDJ")
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            XCTAssertFalse(code.contains("access: .live") || code.contains("ProVoiceAccess.live"),
                           "\(file.lastPathComponent) wires the live gate")
        }
    }

    /// N4: the app registers the live renderer's cloud-clip purge for consent revokes.
    func testTheAppRegistersTheCloudClipPurge() throws {
        let deps = try text("ios/AeroDJ/AppDependencies.swift")
        XCTAssertTrue(deps.contains("PaidVoiceAccessRelay.purgeCloudAudio = { await voice.purgeCloudClips() }"))
        XCTAssertTrue(deps.contains("let voice = paidVoice.renderer"))
    }

    func testTheAppRegistersItsBreakSession() throws {
        let deps = try text("ios/AeroDJ/AppDependencies.swift")
        XCTAssertTrue(deps.contains("PaidVoiceAccessRelay.session = djSession"))
    }
}
