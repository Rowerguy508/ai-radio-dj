import Foundation
import XCTest
@testable import AeroDJCore

/// Repo paths, resolved from this file so the checks run the same on Linux and macOS CI.
private enum RepoPaths {
    static let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AeroDJCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // AeroDJCore
        .deletingLastPathComponent() // ios
    static let storeKitConfig = ios.appendingPathComponent("StoreKit/OnAirlyPro.storekit")
    static let coreSources = ios.appendingPathComponent("AeroDJCore/Sources/AeroDJCore")
    static let app = ios.appendingPathComponent("AeroDJ")

    static func swiftFiles(under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}

final class ProSubscriptionConfigTests: XCTestCase {
    func testOwnerDecisionsMirroredClientSideAreSingleValues() {
        XCTAssertFalse(ProSubscriptionConfig.familySharingEnabled, "Family Sharing off (Orion)")
        XCTAssertEqual(ProSubscriptionConfig.clientGracePeriodSeconds, 0, "no grace period (Orion)")
    }

    func testOwnerPricingIsTwoAutoRenewablesUnderTheBundleID() {
        XCTAssertEqual(ProSubscriptionConfig.bundleID, "com.aerodj.app")
        XCTAssertEqual(ProSubscriptionConfig.products.map(\.id), ["com.aerodj.app.pro.monthly", "com.aerodj.app.pro.yearly"])
        XCTAssertEqual(ProSubscriptionConfig.products.map(\.period), ["P1M", "P1Y"])
        XCTAssertEqual(ProSubscriptionConfig.products.map(\.usdDisplayPrice), ["4.99", "34.99"])
        XCTAssertEqual(ProSubscriptionConfig.productIDs.count, 2, "IDs are unique")
        for id in ProSubscriptionConfig.productIDs {
            XCTAssertTrue(id.hasPrefix(ProSubscriptionConfig.bundleID + "."), id)
        }
    }

    /// The .storekit file and the config constant must not drift: same group, same IDs,
    /// periods and prices, all auto-renewable, all in the one group.
    func testStoreKitConfigurationFileMatchesTheConfig() throws {
        let data = try Data(contentsOf: RepoPaths.storeKitConfig)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((root["products"] as? [Any])?.count, 0, "no consumables or non-consumables")
        XCTAssertEqual((root["nonRenewingSubscriptions"] as? [Any])?.count, 0)
        let groups = try XCTUnwrap(root["subscriptionGroups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1, "one subscription group")
        let group = groups[0]
        XCTAssertEqual(group["name"] as? String, ProSubscriptionConfig.subscriptionGroupName)
        let groupID = try XCTUnwrap(group["id"] as? String)
        let subs = try XCTUnwrap(group["subscriptions"] as? [[String: Any]])
        let parsed = subs.map {
            ProSubscriptionConfig.Product(id: $0["productID"] as? String ?? "",
                                          period: $0["recurringSubscriptionPeriod"] as? String ?? "",
                                          usdDisplayPrice: $0["displayPrice"] as? String ?? "")
        }
        XCTAssertEqual(parsed, ProSubscriptionConfig.products)
        for sub in subs {
            XCTAssertEqual(sub["type"] as? String, "RecurringSubscription")
            XCTAssertEqual(sub["subscriptionGroupID"] as? String, groupID)
            XCTAssertEqual(sub["familyShareable"] as? Bool, ProSubscriptionConfig.familySharingEnabled)
        }
        let settings = try XCTUnwrap(root["settings"] as? [String: Any])
        XCTAssertEqual(settings["_storefront"] as? String, "USA")
    }

    /// Sentinel criterion 4: no App Store Server API key, shared secret or ASC account link in
    /// the app's StoreKit pieces. A local config only, never synced to the owner's team.
    func testNoSecretsOrAccountLinksInTheStoreKitPieces() throws {
        var files = [RepoPaths.storeKitConfig]
        files += RepoPaths.swiftFiles(under: RepoPaths.coreSources.appendingPathComponent("Purchases"))
        files += RepoPaths.swiftFiles(under: RepoPaths.app.appendingPathComponent("Purchases"))
        XCTAssertGreaterThanOrEqual(files.count, 3)
        let forbidden = ["-----BEGIN", "PRIVATE KEY", "sharedSecret", "shared_secret", "SharedSecret",
                         "_developerTeamID", "_applicationInternalID", "issuerId", "AuthKey_", "Bearer "]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in forbidden {
                XCTAssertFalse(text.contains(needle), "\(file.lastPathComponent) contains \(needle)")
            }
        }
    }
}

final class ProEntitlementMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let monthly = ProSubscriptionConfig.monthlyProductID
    private let yearly = ProSubscriptionConfig.yearlyProductID

    private func tx(_ id: String, bought: TimeInterval, expires: TimeInterval?, revoked: TimeInterval? = nil,
                    upgraded: Bool = false) -> ProTransactionSnapshot {
        ProTransactionSnapshot(productID: id, purchaseDate: now.addingTimeInterval(bought),
                               expirationDate: expires.map(now.addingTimeInterval),
                               revocationDate: revoked.map(now.addingTimeInterval), isUpgraded: upgraded)
    }

    func testNothingOnRecordIsFree() {
        XCTAssertEqual(ProEntitlementMapper.state(for: [], now: now), .free)
        XCTAssertFalse(ProEntitlementState.free.showsPro)
    }

    func testActiveSubscriptionIsPro() {
        let s = ProEntitlementMapper.state(for: [tx(monthly, bought: -60, expires: 3600)], now: now)
        XCTAssertEqual(s, .pro(productID: monthly, expiresAt: now.addingTimeInterval(3600)))
        XCTAssertTrue(s.showsPro)
    }

    func testExpiryFlipsProToExpired() {
        let t = tx(monthly, bought: -3600, expires: 60)
        XCTAssertTrue(ProEntitlementMapper.state(for: [t], now: now).showsPro)
        let later = now.addingTimeInterval(61)
        XCTAssertEqual(ProEntitlementMapper.state(for: [t], now: later),
                       .expired(productID: monthly, expiredAt: now.addingTimeInterval(60)))
        XCTAssertEqual(ProEntitlementMapper.state(for: [t], now: now.addingTimeInterval(60)),
                       .expired(productID: monthly, expiredAt: now.addingTimeInterval(60)), "expiry instant is not active")
    }

    func testRefundOrRevocationIsNotPro() {
        let s = ProEntitlementMapper.state(for: [tx(yearly, bought: -60, expires: 86_400 * 300, revoked: -1)], now: now)
        XCTAssertEqual(s, .revoked(productID: yearly, revokedAt: now.addingTimeInterval(-1)))
        XCTAssertFalse(s.showsPro)
    }

    func testRestoredHistoryPicksTheActiveOneOverOlderExpiredOrRevoked() {
        let history = [tx(monthly, bought: -90 * 86_400, expires: -60 * 86_400),
                        tx(monthly, bought: -30 * 86_400, expires: -1, revoked: -10 * 86_400),
                        tx(yearly, bought: -5 * 86_400, expires: 360 * 86_400)]
        XCTAssertEqual(ProEntitlementMapper.state(for: history, now: now),
                       .pro(productID: yearly, expiresAt: now.addingTimeInterval(360 * 86_400)))
    }

    func testUpgradedTransactionDoesNotCountAndTheReplacementDoes() {
        let old = tx(monthly, bought: -100, expires: 1000, upgraded: true)
        XCTAssertEqual(ProEntitlementMapper.state(for: [old], now: now),
                       .expired(productID: monthly, expiredAt: now.addingTimeInterval(1000)))
        let new = tx(yearly, bought: -50, expires: 86_400 * 365)
        XCTAssertEqual(ProEntitlementMapper.state(for: [old, new], now: now),
                       .pro(productID: yearly, expiresAt: now.addingTimeInterval(86_400 * 365)))
    }

    func testUnknownProductsAndMissingExpiryNeverShowPro() {
        XCTAssertEqual(ProEntitlementMapper.state(for: [tx("com.example.other", bought: -1, expires: 9999)], now: now), .free)
        XCTAssertFalse(ProEntitlementMapper.state(for: [tx(monthly, bought: -1, expires: nil)], now: now).showsPro)
    }

    func testUnverifiedTransactionsNeverShowPro() {
        let forged = ProTransactionSnapshot(productID: monthly, purchaseDate: now.addingTimeInterval(-1),
                                            expirationDate: now.addingTimeInterval(86_400), isVerified: false)
        XCTAssertEqual(ProEntitlementMapper.state(for: [forged], now: now), .unverified(productID: monthly))
        let expiredButVerified = tx(yearly, bought: -400 * 86_400, expires: -35 * 86_400)
        XCTAssertEqual(ProEntitlementMapper.state(for: [expiredButVerified, forged], now: now),
                       .expired(productID: yearly, expiredAt: now.addingTimeInterval(-35 * 86_400)),
                       "an unverified active one never beats a verified history")
    }

    /// Atlas's contract nit: the proxy rejects FAMILY_SHARED (`allowFamilyShared: false`), so the
    /// client never shows it as Pro either while Family Sharing is off.
    func testFamilySharedIsNotProWhileFamilySharingIsOff() {
        let shared = ProTransactionSnapshot(productID: yearly, purchaseDate: now.addingTimeInterval(-60),
                                            expirationDate: now.addingTimeInterval(300 * 86_400), ownership: .familyShared)
        XCTAssertFalse(ProSubscriptionConfig.familySharingEnabled)
        XCTAssertEqual(ProEntitlementMapper.state(for: [shared], now: now), .free)
        XCTAssertEqual(ProVoiceGate.decide(entitlement: ProEntitlementMapper.state(for: [shared], now: now),
                                           paidVoiceConsent: true, now: now), .denied(.notPro))
        // Its own purchase still counts, and the shared one never beats it.
        let own = tx(monthly, bought: -3600, expires: 86_400)
        XCTAssertEqual(ProEntitlementMapper.state(for: [shared, own], now: now),
                       .pro(productID: monthly, expiresAt: now.addingTimeInterval(86_400)))
        // The one config value is what decides: turned on, the same transaction would be Pro.
        XCTAssertTrue(ProEntitlementMapper.state(for: [shared], now: now, familySharingEnabled: true).showsPro)
    }

    /// Sentinel N1: what was `.pro` when read is not `.pro` once its expiry passes, with no
    /// re-read in between; and a revocation in the record wins at once.
    func testRecordIsRecomputedAtCallTimeNotCached() {
        let expires = now.addingTimeInterval(60)
        let record = ProEntitlementRecord([tx(monthly, bought: -3600, expires: 60)])
        XCTAssertEqual(record.state(now: now), .pro(productID: monthly, expiresAt: expires))
        XCTAssertEqual(record.state(now: expires), .expired(productID: monthly, expiredAt: expires))
        XCTAssertEqual(record.state(now: expires.addingTimeInterval(86_400)), .expired(productID: monthly, expiredAt: expires))
        XCTAssertEqual(ProEntitlementRecord().state(now: now), .free)
        let revoked = ProEntitlementRecord([tx(monthly, bought: -3600, expires: 86_400, revoked: -1)])
        XCTAssertEqual(revoked.state(now: now), .revoked(productID: monthly, revokedAt: now.addingTimeInterval(-1)))
    }

    /// The app's provider answers from the record at call time, never from its cached `state`.
    func testObserverAnswersTheGateFromTheRecordAtCallTime() throws {
        let file = RepoPaths.app.appendingPathComponent("Purchases/ProEntitlementObserver.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let body = try XCTUnwrap(text.range(of: "func currentProEntitlement()").map { String(text[$0.upperBound...].prefix(160)) })
        XCTAssertTrue(body.contains("record.state(now: now())"), body)
        XCTAssertFalse(body.contains("await state"), "a cached .pro would outlive its expiry")
        XCTAssertFalse(body.contains("return state"))
    }

    func testNoGracePeriodByDefaultAndTheGraceIsOneValue() {
        let t = tx(monthly, bought: -3600, expires: -1)
        XCTAssertFalse(ProEntitlementMapper.state(for: [t], now: now).showsPro)
        XCTAssertTrue(ProEntitlementMapper.state(for: [t], now: now, gracePeriodSeconds: 60).showsPro)
    }

    func testLatestRevokedBeatsAnOlderExpired() {
        let s = ProEntitlementMapper.state(for: [tx(monthly, bought: -200, expires: -100),
                                                 tx(yearly, bought: -50, expires: 9999, revoked: -5)], now: now)
        XCTAssertEqual(s, .revoked(productID: yearly, revokedAt: now.addingTimeInterval(-5)))
    }
}

/// Sentinel criteria 1 and 5. Voice and DJ code see only the `ProVoiceGate` decision (Pro AND
/// consent), never the raw subscription state, so no path can play the paid voice on Pro alone.
/// Consent code never reads anything Pro, so the paywall can never gate privacy.
final class ProEntitlementIsUIOnlyTests: XCTestCase {
    private let rawStateNeedles = ["ProEntitlementState", "showsPro", "ProTransactionSnapshot", "ProEntitlementMapper",
                                   "StoreKit", "currentProEntitlement"]
    private let anyProNeedles = ["ProVoiceAccess", "ProVoiceGate", "ProEntitlement", "ProSubscription", "StoreKit", "showsPro"]

    func testCoreOutsidePurchasesNeverReadsTheRawProState() throws {
        let files = RepoPaths.swiftFiles(under: RepoPaths.coreSources)
            .filter { !$0.path.contains("/Purchases/") }
        XCTAssertGreaterThan(files.count, 50)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in rawStateNeedles { XCTAssertFalse(text.contains(needle), "\(file.lastPathComponent) reads \(needle)") }
        }
    }

    func testAppVoiceFilesNeverReadTheRawProState() throws {
        let parts = ["Voice", "Speech", "Proxy", "Talkover", "Narration", "Briefing", "DJBreak", "AppDependencies"]
        let files = RepoPaths.swiftFiles(under: RepoPaths.app)
            .filter { f in parts.contains { f.lastPathComponent.contains($0) } }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in rawStateNeedles { XCTAssertFalse(text.contains(needle), "\(file.lastPathComponent) reads \(needle)") }
        }
    }

    func testConsentCodeNeverReadsAnythingPro() throws {
        let files = (RepoPaths.swiftFiles(under: RepoPaths.coreSources) + RepoPaths.swiftFiles(under: RepoPaths.app))
            .filter { $0.lastPathComponent.contains("Consent") || $0.lastPathComponent.contains("Connection") }
        XCTAssertGreaterThanOrEqual(files.count, 2)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in anyProNeedles { XCTAssertFalse(text.contains(needle), "\(file.lastPathComponent) reads \(needle)") }
        }
    }

    /// The bundled clips and the paid route both take the gate, and neither has a default.
    func testBundleAndPaidRouteRequireTheGate() throws {
        let bundled = try String(contentsOf: RepoPaths.coreSources.appendingPathComponent("Voice/BundledClips.swift"), encoding: .utf8)
        XCTAssertTrue(bundled.contains("directory: URL, access: ProVoiceAccess,"))
        XCTAssertTrue(bundled.contains("guard await access.decision().permitsPaidVoice else { return nil }"))
        let routes = try String(contentsOf: RepoPaths.coreSources.appendingPathComponent("Voice/PremiumVoiceCatalog.swift"), encoding: .utf8)
        XCTAssertTrue(routes.contains("access: ProVoiceGate.Decision,"))
        XCTAssertFalse(routes.contains("access: ProVoiceGate.Decision ="), "no default access")
        let prep = try String(contentsOf: RepoPaths.coreSources.appendingPathComponent("DJ/DJBreakPreparation.swift"), encoding: .utf8)
        XCTAssertTrue(prep.contains("bundled?.gatedClip("))
        XCTAssertFalse(prep.contains("bundled?.clip("), "the preparer never uses the ungated lookup")
    }
}
