import AeroDJCore
import StoreKit
import StoreKitTest
import XCTest
@testable import AeroDJ

/// StoreKitTest coverage for OnAirly Pro against the local `StoreKit/OnAirlyPro.storekit`
/// (bundled into this test target). Each test shows the client-side entitlement state moving.
/// That state is UI only: the proxy decides paid access, and the consent sheet still comes first.
///
/// Simulator only, through SKTestSession: no App Store account, no sandbox, no device.
@MainActor
final class ProSubscriptionStoreKitTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OnAirlyPro", withExtension: "storekit"),
                                "OnAirlyPro.storekit must be a resource of AeroDJStoreKitTests")
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
    }

    private func observer() -> ProEntitlementObserver { ProEntitlementObserver() }

    func testProductsLoadAtTheOwnersPricesInOneGroup() async throws {
        let products = try await Product.products(for: ProSubscriptionConfig.productIDs)
        XCTAssertEqual(Set(products.map(\.id)), ProSubscriptionConfig.productIDs)
        let byID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        XCTAssertEqual(byID[ProSubscriptionConfig.monthlyProductID]?.price, Decimal(string: "4.99"))
        XCTAssertEqual(byID[ProSubscriptionConfig.yearlyProductID]?.price, Decimal(string: "34.99"))
        XCTAssertEqual(Set(products.compactMap { $0.subscription?.subscriptionGroupID }).count, 1)
        for product in products { XCTAssertEqual(product.type, .autoRenewable, product.id) }
    }

    func testPurchaseMovesFreeToPro() async throws {
        let o = observer()
        await o.refresh()
        XCTAssertEqual(o.state, .free)

        let transaction = try await session.buyProduct(identifier: ProSubscriptionConfig.monthlyProductID)
        await o.refresh()
        guard case .pro(let id, let expires) = o.state else { return XCTFail("expected .pro, got \(o.state)") }
        XCTAssertEqual(id, ProSubscriptionConfig.monthlyProductID)
        XCTAssertEqual(expires, transaction.expirationDate)
    }

    func testRestoreOnAFreshObserverShowsPro() async throws {
        _ = try await session.buyProduct(identifier: ProSubscriptionConfig.yearlyProductID)
        let fresh = observer() // a relaunch: nothing in memory
        XCTAssertEqual(fresh.state, .free)
        try await fresh.restore()
        guard case .pro(let id, _) = fresh.state else { return XCTFail("expected .pro, got \(fresh.state)") }
        XCTAssertEqual(id, ProSubscriptionConfig.yearlyProductID)
    }

    func testExpiryMovesProToExpired() async throws {
        let o = observer()
        _ = try await session.buyProduct(identifier: ProSubscriptionConfig.monthlyProductID)
        await o.refresh()
        XCTAssertTrue(o.state.showsPro)

        try session.expireSubscription(productIdentifier: ProSubscriptionConfig.monthlyProductID)
        try await waitForState(o) { if case .expired = $0 { return true }; return false }
        XCTAssertFalse(o.state.showsPro)
    }

    func testRefundRevocationMovesProToRevoked() async throws {
        let o = observer()
        let transaction = try await session.buyProduct(identifier: ProSubscriptionConfig.yearlyProductID)
        await o.refresh()
        XCTAssertTrue(o.state.showsPro)

        try session.refundTransaction(identifier: UInt(transaction.id))
        try await waitForState(o) { if case .revoked = $0 { return true }; return false }
        guard case .revoked(let id, _) = o.state else { return XCTFail("expected .revoked, got \(o.state)") }
        XCTAssertEqual(id, ProSubscriptionConfig.yearlyProductID)
    }

    /// StoreKitTest applies expiry and refunds asynchronously; poll refresh() briefly.
    /// The observer is the `ProEntitlementProviding` behind `ProVoiceAccess`: purchase plus consent
    /// opens the paid voice, consent alone never does, and a refund closes it again.
    func testObserverDrivesTheProVoiceGate() async throws {
        let o = observer()
        await o.refresh()
        let before = await ProVoiceAccess(entitlement: o, consent: GrantedConsent()).decision()
        XCTAssertEqual(before, .denied(.notPro))

        let transaction = try await session.buyProduct(identifier: ProSubscriptionConfig.monthlyProductID)
        await o.refresh()
        let bought = await ProVoiceAccess(entitlement: o, consent: GrantedConsent()).decision()
        XCTAssertEqual(bought, .allowed)
        let noConsent = await ProVoiceAccess(entitlement: o, consent: NoPaidVoiceConsent()).decision()
        XCTAssertEqual(noConsent, .denied(.noConsent))

        try session.refundTransaction(identifier: UInt(transaction.id))
        try await waitForState(o) { if case .revoked = $0 { return true }; return false }
        let refunded = await ProVoiceAccess(entitlement: o, consent: GrantedConsent()).decision()
        XCTAssertEqual(refunded, .denied(.revoked))
    }

    /// SKTestSession cannot create a family-shared transaction (the group is not family
    /// shareable), so the `.familyShared` case is covered by the Linux mapper test. This pins the
    /// other half: an own purchase carries `.purchased` into the snapshot and counts as Pro.
    func testOwnPurchaseCarriesPurchasedOwnership() async throws {
        let transaction = try await session.buyProduct(identifier: ProSubscriptionConfig.monthlyProductID)
        XCTAssertEqual(transaction.ownershipType, .purchased)
        let snapshot = ProEntitlementObserver.snapshot(transaction, isVerified: true)
        XCTAssertEqual(snapshot.ownership, .purchased)
        XCTAssertTrue(ProEntitlementMapper.state(for: [snapshot], now: Date()).showsPro)
    }

    /// Sentinel N1: past the expiry, the gate input is not `.pro` even with no refresh and no
    /// `Transaction.updates` event in between.
    func testCurrentEntitlementIsNotACachedProPastExpiry() async throws {
        let clock = TestClock()
        let o = ProEntitlementObserver(now: { clock.now })
        try await session.buyProduct(identifier: ProSubscriptionConfig.monthlyProductID)
        await o.refresh()
        guard case .pro(_, let expiresAt?) = o.state else { return XCTFail("expected .pro, got \(o.state)") }
        let before = await o.currentProEntitlement()
        XCTAssertTrue(before.showsPro)

        clock.now = expiresAt.addingTimeInterval(1)
        let after = await o.currentProEntitlement()
        XCTAssertEqual(after, .expired(productID: ProSubscriptionConfig.monthlyProductID, expiredAt: expiresAt))
        let gate = await ProVoiceAccess(entitlement: o, consent: GrantedConsent()).decision()
        XCTAssertEqual(gate, .denied(.expired))
    }

    private func waitForState(_ o: ProEntitlementObserver, timeout: TimeInterval = 10,
                              _ matches: (ProEntitlementState) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await o.refresh()
            if matches(o.state) { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("state never matched; last \(o.state)")
    }
}

private struct GrantedConsent: PaidVoiceConsentProviding {
    func hasPaidVoiceConsent() async -> Bool { true }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
