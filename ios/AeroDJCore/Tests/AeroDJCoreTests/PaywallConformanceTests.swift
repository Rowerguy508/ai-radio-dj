import XCTest
@testable import AeroDJCore

/// The paywall's conformances on top of #244: the StoreKit-side state (cache; family sharing is
/// #244's mapper filter), the consent store as `PaidVoiceConsentProviding`, the appAccountToken, and the
/// Sentinel checks that are specific to this PR. #244 owns the mapper and gate tests. -Nova
final class PaywallConformanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let monthly = ProSubscriptionConfig.monthlyProductID
    private let yearly = ProSubscriptionConfig.yearlyProductID

    private func tx(_ id: String, expiresIn: TimeInterval?, revoked: Bool = false, verified: Bool = true,
                    ownership: ProOwnership = .purchased) -> ProTransactionSnapshot {
        ProTransactionSnapshot(productID: id, purchaseDate: now.addingTimeInterval(-86_400),
                               expirationDate: expiresIn.map(now.addingTimeInterval),
                               revocationDate: revoked ? now.addingTimeInterval(-60) : nil,
                               isVerified: verified, ownership: ownership)
    }

    private func access(_ state: ProEntitlementState, consent: CloudVoiceConsentState) -> ProVoiceAccess {
        ProVoiceAccess(entitlement: ProEntitlementCache(state, now: { [now] in now }),
                       consent: CloudVoiceConsentStore.inMemory(consent))
    }

    // MARK: Sentinel: fail closed, consent first (through the real conformers)

    func testUnverifiedExpiredRevokedAndFreeGetNoPaidVoice() async {
        let states: [ProEntitlementState] = [
            .free, .unverified(productID: monthly),
            .expired(productID: monthly, expiredAt: now.addingTimeInterval(-1)),
            .revoked(productID: yearly, revokedAt: now.addingTimeInterval(-1)),
        ]
        for state in states {
            let decision = await access(state, consent: .accepted).decision()
            XCTAssertFalse(decision.permitsPaidVoice, "\(state)")
        }
    }

    func testProWithRevokedConsentStaysOnDevice() async {
        let pro = ProEntitlementState.pro(productID: yearly, expiresAt: now.addingTimeInterval(3600))
        let allowed = await access(pro, consent: .accepted).decision()
        XCTAssertEqual(allowed, .allowed)
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let live = ProVoiceAccess(entitlement: ProEntitlementCache(pro, now: { [now] in now }), consent: store)
        store.decline()
        let afterDecline = await live.decision()
        XCTAssertEqual(afterDecline, .denied(.noConsent))
        let undecided = await access(pro, consent: .undecided).decision()
        XCTAssertEqual(undecided, .denied(.noConsent))
    }

    func testConsentStoreConformsAndFailsClosed() async {
        let undecided: any PaidVoiceConsentProviding = CloudVoiceConsentStore.inMemory()
        let declined: any PaidVoiceConsentProviding = CloudVoiceConsentStore.inMemory(.declined)
        let accepted: any PaidVoiceConsentProviding = CloudVoiceConsentStore.inMemory(.accepted)
        let u = await undecided.hasPaidVoiceConsent(), d = await declined.hasPaidVoiceConsent()
        let a = await accepted.hasPaidVoiceConsent()
        XCTAssertFalse(u); XCTAssertFalse(d); XCTAssertTrue(a)
    }

    func testCacheStartsFreeAndNeverAnswersProPastExpiry() async {
        let fresh = await ProEntitlementCache().currentProEntitlement()
        XCTAssertEqual(fresh, .free)
        let clock = Clock(now)
        let cache = ProEntitlementCache(now: { clock.value })
        cache.set(.pro(productID: monthly, expiresAt: now.addingTimeInterval(10)))
        let before = await cache.currentProEntitlement()
        XCTAssertTrue(before.showsPro)
        clock.value = now.addingTimeInterval(10)
        let after = await cache.currentProEntitlement()
        XCTAssertEqual(after, .expired(productID: monthly, expiredAt: now.addingTimeInterval(10)))
    }

    // MARK: Family Sharing (off for Pro, matching #244) and verification

    func testFamilySharedIsNotPro() {
        let shared = [tx(yearly, expiresIn: 3600, ownership: .familyShared)]
        XCTAssertEqual(ProEntitlementMapper.state(for: shared, now: now), .free)
        XCTAssertTrue(ProStoreEntitlement.onlyFamilyShared(shared))
        XCTAssertEqual(ProSubscriptionStatus(state: .free, onlyFamilyShared: true), .familyShared)
        XCTAssertFalse(ProSubscriptionStatus.familyShared.isPro)
        // The family member's own purchase still counts.
        let mixed = shared + [tx(monthly, expiresIn: 600)]
        XCTAssertEqual(ProEntitlementMapper.state(for: mixed, now: now), .pro(productID: monthly, expiresAt: now.addingTimeInterval(600)))
        XCTAssertFalse(ProStoreEntitlement.onlyFamilyShared(mixed))
        XCTAssertFalse(ProSubscriptionConfig.familySharingEnabled)
    }

    func testStoreSideMappingFailsClosed() {
        XCTAssertEqual(ProEntitlementMapper.state(for: [tx(monthly, expiresIn: 3600, verified: false)], now: now),
                       .unverified(productID: monthly))
        XCTAssertFalse(ProEntitlementMapper.state(for: [tx(monthly, expiresIn: -1)], now: now).showsPro)
        XCTAssertFalse(ProEntitlementMapper.state(for: [tx(monthly, expiresIn: 3600, revoked: true)], now: now).showsPro)
        XCTAssertEqual(ProEntitlementMapper.state(for: [], now: now), .free)
    }

    // MARK: Status UI and products

    func testStatusRowsForEveryState() {
        let rows: [(ProEntitlementState, String)] = [
            (.free, "Free"), (.unverified(productID: monthly), "Free"),
            (.pro(productID: monthly, expiresAt: nil), "Pro (monthly)"), (.pro(productID: yearly, expiresAt: nil), "Pro (yearly)"),
            (.expired(productID: yearly, expiredAt: now), "Pro expired"), (.revoked(productID: monthly, revokedAt: now), "Pro refunded"),
        ]
        for (state, title) in rows {
            XCTAssertEqual(PaywallCopy.statusTitle(ProSubscriptionStatus(state: state)), title)
        }
        XCTAssertEqual(PaywallCopy.statusTitle(.loading), "Free")
        XCTAssertEqual(PaywallCopy.statusDetail(.pro(.monthly, renews: false, until: nil)), "Cloud voice until the period ends. Won't renew.")
        XCTAssertTrue(PaywallCopy.statusDetail(.familyShared).contains("Family Sharing"))
    }

    func testProductsComeFromTheOneConfig() throws {
        XCTAssertEqual(SubscriptionPeriod(productID: monthly), .monthly)
        XCTAssertEqual(SubscriptionPeriod(productID: yearly), .yearly)
        XCTAssertNil(SubscriptionPeriod(productID: "com.example.other"))
        XCTAssertEqual(Set(SubscriptionPeriod.paywallOrder), ProSubscriptionConfig.productIDs)
        for file in try paywallFiles() where file.lastPathComponent != "ProSubscription.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("\"com.aerodj.app.pro"), "\(file.lastPathComponent) repeats a product ID")
        }
    }

    func testPaywallOnlyAfterConsentAndNotForPro() {
        XCTAssertTrue(PaywallOffer.mayOffer(consent: .accepted, cloudVoiceOffered: true, status: .free))
        XCTAssertTrue(PaywallOffer.mayOffer(consent: .accepted, cloudVoiceOffered: true, status: .expired(.monthly)))
        XCTAssertFalse(PaywallOffer.mayOffer(consent: .undecided, cloudVoiceOffered: true, status: .free))
        XCTAssertFalse(PaywallOffer.mayOffer(consent: .declined, cloudVoiceOffered: true, status: .free))
        XCTAssertFalse(PaywallOffer.mayOffer(consent: .accepted, cloudVoiceOffered: false, status: .free))
        XCTAssertFalse(PaywallOffer.mayOffer(consent: .accepted, cloudVoiceOffered: true, status: .pro(.yearly, renews: true, until: nil)))
    }

    // MARK: appAccountToken (Atlas, #233 §5.4)

    func testAppAccountTokenIsMadeOnceAndPersistsAcrossLaunches() {
        let keychain = InMemoryAppAccountTokenStore()
        let made = Counter()
        let make: @Sendable () -> UUID = { made.bump(); return UUID() }
        let first = AppAccountTokenProvider(store: keychain, make: make).token()
        XCTAssertEqual(AppAccountTokenProvider(store: keychain, make: make).token(), first, "second launch")
        XCTAssertEqual(AppAccountTokenProvider(store: keychain, make: make).token(), first, "third launch")
        XCTAssertEqual(made.value, 1)
        XCTAssertEqual(keychain.writes, 1)
        let existing = UUID()
        XCTAssertEqual(AppAccountTokenProvider(store: InMemoryAppAccountTokenStore(existing)).token(), existing)
    }

    func testPurchaseOptionsIncludeTheToken() throws {
        let token = UUID()
        XCTAssertEqual(ProPurchasePlan.options(token: token), [.appAccountToken(token)])
        let app = try String(contentsOf: appPurchases.appendingPathComponent("Subscriptions+App.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("product.purchase(options: purchaseOptions())"))
        XCTAssertTrue(app.contains("Product.PurchaseOption.appAccountToken(uuid)"))
        XCTAssertFalse(app.contains("product.purchase()"), "every purchase passes the token")
    }

    func testTokenLivesInTheKeychainNotUserDefaults() throws {
        let store = try String(contentsOf: appPurchases.appendingPathComponent("AppAccountTokenKeychain.swift"), encoding: .utf8)
        XCTAssertTrue(store.contains("kSecClassGenericPassword"))
        XCTAssertTrue(store.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"))
        for file in try paywallFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for use in ["UserDefaults.", "UserDefaults(", "@AppStorage"] {
                XCTAssertFalse(text.contains(use), "\(file.lastPathComponent) touches UserDefaults")
            }
        }
    }

    /// Grep check (Sentinel): no log or print line in the paywall code mentions a transaction ID,
    /// JWS or the appAccountToken.
    func testPaywallCodeNeverLogsIdentifiersOrTheToken() throws {
        let sensitive = ["originalID", "jwsRepresentation", "appAccountToken", "token", "uuid", "UUID",
                         "transaction.id", ".id)", "signedTransaction", "productID"]
        let sinks = ["log.", "logger.", "Logger(", "print(", "NSLog(", "os_log(", "dump("]
        let files = try paywallFiles()
        XCTAssertGreaterThanOrEqual(files.count, 6)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                guard sinks.contains(where: { l.contains($0) }), !l.contains("Logger(subsystem:") else { continue }
                for s in sensitive where l.contains(s) {
                    XCTFail("\(file.lastPathComponent):\(n + 1) logs \(s)")
                }
            }
        }
    }

    func testCopyUsesTheAppNameAndNeverHardCodesPrices() {
        XCTAssertEqual(PaywallCopy.title, "\(AppName.display) Pro")
        XCTAssertEqual(PaywallCopy.planLine(.yearly, price: "$34.99"), "Yearly, $34.99 per year")
        for line in [PaywallCopy.subtitle, PaywallCopy.freeLine, PaywallCopy.proLine, PaywallCopy.autoRenewDisclosure,
                     PaywallCopy.loadingPrices, PaywallCopy.pricesUnavailable] {
            XCTAssertFalse(line.contains("$") || line.contains("4.99") || line.contains("34.99"), line)
            XCTAssertFalse(line.contains("AeroDJ"), line)
        }
        XCTAssertTrue(PaywallCopy.autoRenewDisclosure.contains("renews automatically"))
    }

    // MARK: Helpers

    private var ios: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private var appPurchases: URL { ios.appendingPathComponent("AeroDJ/Purchases") }

    private func paywallFiles() throws -> [URL] {
        let dirs = [appPurchases, ios.appendingPathComponent("AeroDJCore/Sources/AeroDJCore/Purchases")]
        return try dirs.flatMap { dir in
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
        }
    }

    private final class Clock: @unchecked Sendable {
        var value: Date
        init(_ value: Date) { self.value = value }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
