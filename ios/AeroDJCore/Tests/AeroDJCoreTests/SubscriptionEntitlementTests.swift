import XCTest
@testable import AeroDJCore

// StoreKit 2 entitlement → tier → voice gate. All entitlements come from a fake source: no
// StoreKit, no network, no server. The client tier is advisory; these tests pin that it fails
// closed and never outranks privacy (consent). -Nova

/// Fake `EntitlementSource` (the protocol Fry's StoreKitTest and Atlas's server seam also use).
private final class FakeEntitlementSource: EntitlementSource, @unchecked Sendable {
    var snapshots: [EntitlementSnapshot] = []
    var error: Error?
    func currentEntitlements() async throws -> [EntitlementSnapshot] {
        if let error { throw error }
        return snapshots
    }
    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private final class CloudSpy: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var received: [String] { lock.withLock { texts } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

final class SubscriptionEntitlementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var later: Date { now.addingTimeInterval(86_400) }
    private var earlier: Date { now.addingTimeInterval(-86_400) }

    private func snap(_ id: String = SubscriptionProducts.proMonthly, _ v: EntitlementVerification = .verified,
                      expires: Date? = nil, revoked: Date? = nil, state: SubscriptionRenewalState = .subscribed,
                      renews: Bool = true, grace: Date? = nil, upgraded: Bool = false) -> EntitlementSnapshot {
        EntitlementSnapshot(productID: id, verification: v, expirationDate: expires ?? later, revocationDate: revoked,
                            isUpgraded: upgraded, renewalState: state, willAutoRenew: renews,
                            gracePeriodExpirationDate: grace)
    }

    private func status(_ s: [EntitlementSnapshot]) async -> SubscriptionStatus {
        let source = FakeEntitlementSource()
        source.snapshots = s
        return await EntitlementChecker(source: source).status(now: now)
    }

    // MARK: Config

    func testProductIDsLiveInOneConfig() {
        XCTAssertEqual(SubscriptionProducts.all, ["com.aerodj.app.pro.yearly", "com.aerodj.app.pro.monthly"])
        XCTAssertEqual(SubscriptionProducts.period(for: SubscriptionProducts.proMonthly), .monthly)
        XCTAssertEqual(SubscriptionProducts.period(for: SubscriptionProducts.proYearly), .yearly)
        XCTAssertNil(SubscriptionProducts.period(for: "com.example.other"))
    }

    // MARK: Resolution (fail-closed)

    func testNoEntitlementsIsFree() async {
        let s = await status([])
        XCTAssertEqual(s, .free)
        XCTAssertEqual(s.tier, .free)
    }

    func testVerifiedActiveMonthlyAndYearlyArePro() async {
        let monthly = await status([snap()])
        XCTAssertEqual(monthly, .pro(.monthly, renews: true, until: later))
        let yearly = await status([snap(SubscriptionProducts.proYearly, renews: false)])
        XCTAssertEqual(yearly, .pro(.yearly, renews: false, until: later))
        XCTAssertEqual(yearly.tier, .pro)
        let both = await status([snap(), snap(SubscriptionProducts.proYearly)])
        XCTAssertEqual(both, .pro(.yearly, renews: true, until: later))
    }

    func testUnverifiedTransactionIsFree() async {
        let s = await status([snap(SubscriptionProducts.proYearly, .unverified)])
        XCTAssertEqual(s, .free)
        XCTAssertEqual(s.tier, .free)
    }

    func testExpiredTransactionIsFree() async {
        let pastExpiry = await status([snap(expires: earlier)])
        XCTAssertEqual(pastExpiry, .expired(.monthly))
        XCTAssertEqual(pastExpiry.tier, .free)
        let expiredState = await status([snap(SubscriptionProducts.proYearly, state: .expired)])
        XCTAssertEqual(expiredState.tier, .free)
        let retryNoGrace = await status([snap(state: .inBillingRetryPeriod)])
        XCTAssertEqual(retryNoGrace, .expired(.monthly))
    }

    func testRevokedOrRefundedTransactionIsFree() async {
        let refunded = await status([snap(revoked: earlier)])
        XCTAssertEqual(refunded, .revoked)
        XCTAssertEqual(refunded.tier, .free)
        let revokedState = await status([snap(SubscriptionProducts.proYearly, state: .revoked)])
        XCTAssertEqual(revokedState, .revoked)
        // A refund outranks a plain lapse in the status line; an active plan still wins.
        let mixed = await status([snap(expires: earlier), snap(SubscriptionProducts.proYearly, revoked: earlier)])
        XCTAssertEqual(mixed, .revoked)
        let active = await status([snap(SubscriptionProducts.proYearly, revoked: earlier), snap()])
        XCTAssertEqual(active.tier, .pro)
    }

    func testGracePeriodKeepsProUntilItEnds() async {
        let grace = await status([snap(expires: earlier, state: .inGracePeriod, grace: later)])
        XCTAssertEqual(grace, .gracePeriod(.monthly, until: later))
        XCTAssertEqual(grace.tier, .pro)
        let over = await status([snap(expires: earlier, state: .inGracePeriod, grace: earlier)])
        XCTAssertEqual(over, .expired(.monthly))
    }

    func testUnknownProductUnknownStateUpgradedAndErrorsAreNotPro() async {
        let unknownProduct = await status([snap("com.example.other")])
        XCTAssertEqual(unknownProduct, .free)
        let unknownState = await status([snap(state: .unknown)])
        XCTAssertEqual(unknownState.tier, .free)
        let upgradedAway = await status([snap(upgraded: true)])
        XCTAssertEqual(upgradedAway, .free)

        let failing = FakeEntitlementSource()
        failing.error = URLError(.notConnectedToInternet)
        let s = await EntitlementChecker(source: failing).status(now: now)
        XCTAssertEqual(s, .unavailable)
        XCTAssertEqual(s.tier, .free)
    }

    // MARK: Gate (privacy first)

    func testAccessRules() {
        XCTAssertTrue(CloudVoiceAccess.allowsCloudVoice(consent: .accepted, tier: .pro))
        XCTAssertFalse(CloudVoiceAccess.allowsCloudVoice(consent: .accepted, tier: .free))
        XCTAssertFalse(CloudVoiceAccess.allowsCloudVoice(consent: .declined, tier: .pro))
        XCTAssertFalse(CloudVoiceAccess.allowsCloudVoice(consent: .undecided, tier: .pro))
        // The paywall only after consent, only where a cloud voice exists, only to Free.
        XCTAssertTrue(CloudVoiceAccess.mayOfferPaywall(consent: .accepted, cloudVoiceOffered: true, tier: .free))
        XCTAssertFalse(CloudVoiceAccess.mayOfferPaywall(consent: .undecided, cloudVoiceOffered: true, tier: .free))
        XCTAssertFalse(CloudVoiceAccess.mayOfferPaywall(consent: .declined, cloudVoiceOffered: true, tier: .free))
        XCTAssertFalse(CloudVoiceAccess.mayOfferPaywall(consent: .accepted, cloudVoiceOffered: false, tier: .free))
        XCTAssertFalse(CloudVoiceAccess.mayOfferPaywall(consent: .accepted, cloudVoiceOffered: true, tier: .pro))
    }

    private func cue(_ text: String = "That was Song 1 by Artist 1.") -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
    }

    private func renderer(_ spy: CloudSpy, consent: CloudVoiceConsentStore, tier: VoiceEntitlement) -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: spy, voice: djVoice,
                                          microdollarsPerThousandCharacters: 30_000, leavesDevice: true),
                               VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 1_000_000), cache: InMemoryAudioCache(),
                      cloudConsent: consent, entitlement: tier)
    }

    func testFreeWithConsentStaysOnDevice() async throws {
        let spy = CloudSpy()
        let clip = try await renderer(spy, consent: .inMemory(.accepted), tier: .fixed(.free))
            .render(cue(), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(clip.audio.providerID, "device")
        XCTAssertEqual(clip.attempts.first?.result, .failed(VoiceRenderer.notProSkip))
        XCTAssertTrue(spy.received.isEmpty)
    }

    func testProWithConsentUsesTheCloudVoice() async throws {
        let spy = CloudSpy()
        let clip = try await renderer(spy, consent: .inMemory(.accepted), tier: .fixed(.pro))
            .render(cue(), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(clip.audio.providerID, "cloud")
    }

    func testProWithConsentRevokedStaysOnDevice() async throws {
        let consent = CloudVoiceConsentStore.inMemory(.accepted)
        let spy = CloudSpy()
        let r = renderer(spy, consent: consent, tier: .fixed(.pro))
        consent.decline()
        let clip = try await r.render(cue(), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(clip.audio.providerID, "device")
        XCTAssertEqual(clip.attempts.first?.result, .failed(VoiceRenderer.noConsentSkip))
        XCTAssertTrue(spy.received.isEmpty)
        // Pro without ever answering is the same.
        let undecided = try await renderer(spy, consent: .inMemory(), tier: .fixed(.pro))
            .render(cue(), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(undecided.audio.providerID, "device")
        XCTAssertTrue(spy.received.isEmpty)
    }

    func testLosingProAppliesOnTheNextRenderAndDefaultIsFree() async throws {
        XCTAssertEqual(VoiceEntitlement().tier, .free, "fail-closed default")
        let tier = VoiceEntitlement.fixed(.pro)
        let spy = CloudSpy()
        let r = renderer(spy, consent: .inMemory(.accepted), tier: tier)
        let first = try await r.render(cue("One."), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(first.audio.providerID, "cloud")
        tier.set(.free)  // e.g. refund arrives on Transaction.updates
        let second = try await r.render(cue("Two."), userID: "u", stationID: "s", attribution: .presenter).get()
        XCTAssertEqual(second.audio.providerID, "device")
        XCTAssertEqual(spy.received.count, 1)
        XCTAssertTrue(r.onDeviceOnly?.entitlement === tier || r.onDeviceOnly == nil)
        XCTAssertTrue(r.lastRouteOnly?.entitlement === tier)
    }

    func testPaidVoiceAllowedNeedsConsentAndVerifiedActivePro() async {
        let spy = CloudSpy()
        XCTAssertTrue(renderer(spy, consent: .inMemory(.accepted), tier: .fixed(.pro)).paidVoiceAllowed)
        XCTAssertFalse(renderer(spy, consent: .inMemory(.accepted), tier: .fixed(.free)).paidVoiceAllowed)
        let consent = CloudVoiceConsentStore.inMemory(.accepted)
        let r = renderer(spy, consent: consent, tier: .fixed(.pro))
        consent.decline()
        XCTAssertFalse(r.paidVoiceAllowed, "Pro with revoked consent")
        // Unverified, expired and revoked transactions resolve to Free, so nothing paid is allowed.
        for s in [snap(SubscriptionProducts.proYearly, .unverified), snap(expires: earlier), snap(revoked: earlier)] {
            let tier = VoiceEntitlement(await status([s]).tier)
            XCTAssertFalse(renderer(spy, consent: .inMemory(.accepted), tier: tier).paidVoiceAllowed, "\(s)")
        }
    }

    // MARK: No identifiers in logs

    func testSnapshotsCarryNoTransactionIdentifiers() {
        let labels = Mirror(reflecting: snap()).children.compactMap(\.label).map { $0.lowercased() }
        for banned in ["transactionid", "originalid", "id", "jws", "jwsrepresentation", "appaccounttoken", "token"] {
            XCTAssertFalse(labels.contains(banned), "EntitlementSnapshot must not carry \(banned)")
        }
        XCTAssertFalse(String(describing: snap()).localizedCaseInsensitiveContains("jws"))
    }

    /// Grep check: no log or print line in the app's subscription code mentions a transaction ID,
    /// JWS or appAccountToken.
    func testAppSubscriptionCodeNeverLogsTransactionIdentifiers() throws {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ")
        let files = try FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "app sources not found at \(appDir.path)")
        let sensitive = ["originalID", "jwsRepresentation", "appAccountToken", "transaction.id", ".id)", "signedTransaction"]
        let sinks = ["log.", "logger.", "Logger(", "print(", "NSLog(", "os_log("]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                guard sinks.contains(where: { l.contains($0) }) else { continue }
                for s in sensitive where l.contains(s) {
                    XCTFail("\(file.lastPathComponent):\(n + 1) logs \(s): \(l.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    // MARK: Copy

    func testCopyUsesTheAppNameAndNeverHardCodesPrices() {
        XCTAssertEqual(PaywallCopy.title, "OnAirly Pro")
        XCTAssertEqual(PaywallCopy.planLine(.yearly, price: "$34.99"), "Yearly, $34.99 per year")
        let all = [PaywallCopy.subtitle, PaywallCopy.freeLine, PaywallCopy.proLine, PaywallCopy.autoRenewDisclosure,
                   PaywallCopy.loadingPrices, PaywallCopy.pricesUnavailable]
        for line in all {
            XCTAssertFalse(line.contains("$") || line.contains("4.99") || line.contains("34.99"), line)
            XCTAssertFalse(line.contains("AeroDJ"), line)
        }
        XCTAssertTrue(PaywallCopy.autoRenewDisclosure.contains("renews automatically"))
        XCTAssertEqual(PaywallCopy.statusTitle(.pro(.yearly, renews: true, until: nil)), "Pro (yearly)")
        XCTAssertEqual(PaywallCopy.statusTitle(.revoked), "Pro refunded")
        XCTAssertEqual(PaywallCopy.statusTitle(.gracePeriod(.monthly, until: nil)), "Pro: payment issue")
    }
}
