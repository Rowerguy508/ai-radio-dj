import AeroDJCore
import Foundation
import StoreKit

/// Client-side view of the user's OnAirly Pro subscription, for the paywall and the
/// subscription status UI (Nova), and the `ProEntitlementProviding` input to `ProVoiceAccess`.
/// - Alone it never grants the paid voice: `ProVoiceGate` also needs paid-voice consent, and the
///   proxy verifies the signed transaction and decides (Sentinel's entitlement criteria 1 and 5).
/// - It never gates privacy. The consent sheet comes first whatever this says.
/// - Only `.verified` transactions can show Pro. An unverified one maps to `.unverified`
///   (no paid voice), so a forged transaction can never show Pro.
/// - It holds no secret and talks to no server of ours (criterion 4).
///
/// Not instantiated by the app yet; the paywall PR (Nova) wires it, or conforms its own store
/// to `ProEntitlementProviding` instead.
@MainActor
final class ProEntitlementObserver: ObservableObject, ProEntitlementProviding {
    /// For the UI. Set at each refresh; the voice gate does not read it (see below).
    @Published private(set) var state: ProEntitlementState = .free
    private var record = ProEntitlementRecord()

    private let productIDs: [String]
    private let now: @Sendable () -> Date
    private var updatesTask: Task<Void, Never>?

    init(productIDs: [String] = ProSubscriptionConfig.products.map(\.id),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.productIDs = productIDs
        self.now = now
    }

    /// Listens for renewals, refunds, revocations and purchases made elsewhere, and finishes
    /// verified ones. Call once at launch.
    func startListening() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
    }

    /// Recomputed now from the last-read transactions' own dates, not the cached `state`, so a
    /// `.pro` never outlives its expiry between refreshes (Sentinel N1).
    nonisolated func currentProEntitlement() async -> ProEntitlementState {
        await MainActor.run { record.state(now: now()) }
    }

    /// Recomputes the state from the latest transaction for each Pro product.
    /// `Transaction.latest(for:)` still returns expired and revoked transactions, which is what
    /// lets the state show "expired" or "refunded" instead of silently dropping to free.
    func refresh() async {
        var snapshots: [ProTransactionSnapshot] = []
        for id in productIDs {
            guard let result = await Transaction.latest(for: id) else { continue }
            switch result {
            case .verified(let transaction):
                snapshots.append(Self.snapshot(transaction, isVerified: true))
            case .unverified(let transaction, _):
                snapshots.append(Self.snapshot(transaction, isVerified: false))
            }
        }
        record = ProEntitlementRecord(snapshots)
        state = record.state(now: now())
    }

    /// Restore purchases: syncs with the App Store, then recomputes.
    func restore() async throws {
        try await AppStore.sync()
        await refresh()
    }

    static func snapshot(_ t: Transaction, isVerified: Bool) -> ProTransactionSnapshot {
        ProTransactionSnapshot(productID: t.productID, purchaseDate: t.purchaseDate,
                               expirationDate: t.expirationDate, revocationDate: t.revocationDate,
                               isUpgraded: t.isUpgraded, isVerified: isVerified,
                               ownership: t.ownershipType == .familyShared ? .familyShared : .purchased)
    }
}
