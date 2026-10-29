import Foundation

// The paywall's side of Pro (Nova), on top of Fry's #244: product IDs come from
// `ProSubscriptionConfig`, the state from `ProEntitlementMapper`, and the gate is `ProVoiceGate`.
// Client-side and ADVISORY: the proxy verifies Apple's signed transaction and decides (Atlas).
// The app never sends an "isPro" flag. Fail closed: unverified, expired, revoked, family-shared
// or unknown means no paid voice. -Nova

/// Monthly or yearly, read from `ProSubscriptionConfig` (never a second copy of the IDs).
public enum SubscriptionPeriod: String, Equatable, Sendable, CaseIterable {
    case monthly
    case yearly

    public init?(productID: String) {
        guard let product = ProSubscriptionConfig.products.first(where: { $0.id == productID }) else { return nil }
        switch product.period {
        case "P1M": self = .monthly
        case "P1Y": self = .yearly
        default: return nil
        }
    }

    /// Paywall order: yearly first.
    public static let paywallOrder: [String] = [ProSubscriptionConfig.yearlyProductID, ProSubscriptionConfig.monthlyProductID]

    /// "per month" / "per year", appended to `Product.displayPrice`.
    public var perPeriod: String { self == .monthly ? "per month" : "per year" }
    public var title: String { self == .monthly ? "Monthly" : "Yearly" }
}

/// StoreKit's `Transaction.OwnershipType`, mirrored so the core stays Linux-testable.
public enum ProTransactionOwnership: Equatable, Sendable {
    case purchased
    case familyShared
    /// A value this build doesn't know. Fail closed: not Pro.
    case other
}

/// One StoreKit transaction as the paywall reads it. Carries no transaction ID, original ID,
/// JWS or appAccountToken, so none can reach a log from here.
public struct ProStoreTransaction: Equatable, Sendable {
    public var snapshot: ProTransactionSnapshot
    public var ownership: ProTransactionOwnership

    public init(snapshot: ProTransactionSnapshot, ownership: ProTransactionOwnership) {
        self.snapshot = snapshot
        self.ownership = ownership
    }
}

public enum ProStoreEntitlement {
    /// Family Sharing is off for Pro (`ProSubscriptionConfig.familySharingEnabled`, owner decision,
    /// matching #244 and the .storekit file), so a family-shared transaction never counts, and
    /// neither does an ownership type this build doesn't know. The rest is `ProEntitlementMapper`.
    public static func counts(_ t: ProStoreTransaction) -> Bool {
        switch t.ownership {
        case .purchased: true
        case .familyShared: ProSubscriptionConfig.familySharingEnabled
        case .other: false
        }
    }

    public static func state(for transactions: [ProStoreTransaction], now: Date) -> ProEntitlementState {
        ProEntitlementMapper.state(for: transactions.filter(counts).map(\.snapshot), now: now)
    }

    /// True when the only Pro transactions on record are family-shared ones (for the status copy).
    public static func onlyFamilyShared(_ transactions: [ProStoreTransaction]) -> Bool {
        let known = transactions.filter { ProSubscriptionConfig.productIDs.contains($0.snapshot.productID) }
        return !known.isEmpty && !known.contains(where: counts) && known.contains { $0.ownership == .familyShared }
    }
}

/// The app-wide client Pro state: the app's StoreKit store writes it, and `ProVoiceAccess`
/// reads it through `ProEntitlementProviding`. Starts `.free`. Never answers a cached `.pro`
/// past its expiry (#244's contract): an expired one reads as `.expired`. Thread-safe and cheap.
public final class ProEntitlementCache: ProEntitlementProviding, @unchecked Sendable {
    public static let shared = ProEntitlementCache()

    private let lock = NSLock()
    private var state: ProEntitlementState
    private let now: @Sendable () -> Date

    public init(_ state: ProEntitlementState = .free, now: @escaping @Sendable () -> Date = { Date() }) {
        self.state = state
        self.now = now
    }

    public func set(_ newState: ProEntitlementState) { lock.withLock { state = newState } }

    public func currentProEntitlement() async -> ProEntitlementState { snapshot() }

    public func snapshot() -> ProEntitlementState {
        let current = lock.withLock { state }
        if case .pro(let id, let expires?) = current, expires <= now() {
            return .expired(productID: id, expiredAt: expires)
        }
        return current
    }
}

/// The consent sheet's store is the `PaidVoiceConsentProviding` input to `ProVoiceAccess`
/// (`hasPaidVoiceConsent()` lives in the consent PR, so consent code never reads anything Pro).
extension CloudVoiceConsentStore: PaidVoiceConsentProviding {}

/// What the status card shows. Only `.pro` is Pro. No grace-period row: the owner chose no
/// client grace (`ProSubscriptionConfig.clientGracePeriodSeconds`, #244).
public enum ProSubscriptionStatus: Equatable, Sendable {
    /// Nothing read from StoreKit yet. Free until it is.
    case loading
    case free
    case pro(SubscriptionPeriod?, renews: Bool?, until: Date?)
    case expired(SubscriptionPeriod?)
    /// Refunded or revoked by Apple.
    case revoked
    /// StoreKit couldn't verify the purchase. Free.
    case unverified
    /// Shared through Family Sharing, which Pro doesn't support. Free.
    case familyShared

    public init(state: ProEntitlementState, willAutoRenew: Bool? = nil, onlyFamilyShared: Bool = false) {
        switch state {
        case .free: self = onlyFamilyShared ? .familyShared : .free
        case .pro(let id, let expires): self = .pro(SubscriptionPeriod(productID: id), renews: willAutoRenew, until: expires)
        case .expired(let id, _): self = .expired(SubscriptionPeriod(productID: id))
        case .revoked: self = .revoked
        case .unverified: self = .unverified
        }
    }

    public var isPro: Bool {
        if case .pro = self { return true }
        return false
    }
}

public enum PaywallOffer {
    /// The paywall is offered only after consent is stored, only where a cloud voice exists, and
    /// only to someone not already Pro. Without consent, Pro can't be bought from the app.
    public static func mayOffer(consent: CloudVoiceConsentState, cloudVoiceOffered: Bool, status: ProSubscriptionStatus) -> Bool {
        cloudVoiceOffered && consent == .accepted && !status.isPro
    }
}

/// SEAM for Atlas (server entitlement, #233). The proxy decides paid-voice access from Apple's
/// signed transaction (JWS) and the purchase's appAccountToken, never from anything the app
/// asserts. Not implemented here: no server or proxy calls, no secrets, nothing logged.
public protocol ServerEntitlementHandoff: Sendable {
    func handOff(signedTransactionJWS: String) async
}
