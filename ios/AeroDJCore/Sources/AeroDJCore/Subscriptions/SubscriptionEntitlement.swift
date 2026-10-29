import Foundation

// Client-side subscription entitlement. ADVISORY ONLY: it decides what the UI shows and keeps the
// app on the on-device voice when not Pro. The server (Atlas) makes the real paid-voice decision
// from Apple's signed transaction; the app never sends an "isPro" flag to the proxy.
// Fail-closed: unverified, unknown, expired, revoked or errored all resolve to Free. -Nova

public enum SubscriptionTier: String, Equatable, Sendable {
    case free
    case pro
}

/// StoreKit's renewal state, mirrored so AeroDJCore stays StoreKit-free (and Linux-testable).
public enum SubscriptionRenewalState: Equatable, Sendable {
    case subscribed
    case inGracePeriod
    case inBillingRetryPeriod
    case expired
    case revoked
    case unknown
}

public enum EntitlementVerification: Equatable, Sendable {
    case verified
    /// StoreKit `.unverified`: never grants anything.
    case unverified
}

/// What the entitlement logic needs from one transaction. Deliberately carries no transaction
/// ID, original ID, JWS or appAccountToken, so nothing here can leak them into logs.
public struct EntitlementSnapshot: Equatable, Sendable {
    public var productID: String
    public var verification: EntitlementVerification
    public var expirationDate: Date?
    /// Set when Apple refunded or revoked the purchase (or Family Sharing ended).
    public var revocationDate: Date?
    /// True when a higher-ranked product in the group replaced this one.
    public var isUpgraded: Bool
    public var renewalState: SubscriptionRenewalState
    public var willAutoRenew: Bool
    /// End of the billing grace period, when `renewalState == .inGracePeriod`.
    public var gracePeriodExpirationDate: Date?

    public init(productID: String, verification: EntitlementVerification, expirationDate: Date?,
                revocationDate: Date? = nil, isUpgraded: Bool = false,
                renewalState: SubscriptionRenewalState = .subscribed, willAutoRenew: Bool = true,
                gracePeriodExpirationDate: Date? = nil) {
        self.productID = productID
        self.verification = verification
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
        self.renewalState = renewalState
        self.willAutoRenew = willAutoRenew
        self.gracePeriodExpirationDate = gracePeriodExpirationDate
    }
}

/// What the status UI shows. Only `.pro` and `.gracePeriod` are the Pro tier.
public enum SubscriptionStatus: Equatable, Sendable {
    case free
    case pro(SubscriptionPeriod, renews: Bool, until: Date?)
    /// Apple is retrying a failed renewal and the grace period keeps Pro until `until`.
    case gracePeriod(SubscriptionPeriod, until: Date?)
    /// Lapsed, or in billing retry without grace. Free, with a resubscribe prompt.
    case expired(SubscriptionPeriod)
    /// Refunded or revoked by Apple. Free.
    case revoked
    /// StoreKit error or nothing loaded yet. Free.
    case unavailable

    public var tier: SubscriptionTier {
        switch self {
        case .pro, .gracePeriod: .pro
        case .free, .expired, .revoked, .unavailable: .free
        }
    }
}

public enum EntitlementResolver {
    /// Resolves StoreKit's current entitlements to one status. Fail-closed rules:
    /// unverified → ignored; unknown product → ignored; revoked/refunded → `.revoked`;
    /// past expiry (outside grace) → `.expired`; billing retry without grace → `.expired`.
    /// The best remaining Pro entitlement wins (yearly over monthly).
    public static func resolve(_ snapshots: [EntitlementSnapshot], now: Date) -> SubscriptionStatus {
        var best: SubscriptionStatus?
        var lapsed: SubscriptionStatus?
        for s in snapshots {
            guard s.verification == .verified,
                  let period = SubscriptionProducts.period(for: s.productID) else { continue }
            if s.revocationDate != nil || s.renewalState == .revoked {
                lapsed = .revoked  // refunds win over a plain lapse in the status line
                continue
            }
            if s.isUpgraded { continue }
            let candidate: SubscriptionStatus
            switch s.renewalState {
            case .inGracePeriod:
                let until = s.gracePeriodExpirationDate
                if let until, until <= now { candidate = .expired(period) } else { candidate = .gracePeriod(period, until: until) }
            case .subscribed:
                if let exp = s.expirationDate, exp <= now { candidate = .expired(period) }
                else { candidate = .pro(period, renews: s.willAutoRenew, until: s.expirationDate) }
            case .expired, .inBillingRetryPeriod:
                candidate = .expired(period)
            case .unknown, .revoked:
                // Unknown renewal state: fail closed.
                candidate = .expired(period)
            }
            if candidate.tier == .pro {
                if best == nil || rank(candidate) > rank(best!) { best = candidate }
            } else if lapsed == nil {
                lapsed = candidate
            }
        }
        return best ?? lapsed ?? .free
    }

    private static func rank(_ s: SubscriptionStatus) -> Int {
        switch s {
        case .pro(.yearly, _, _): 4
        case .pro(.monthly, _, _): 3
        case .gracePeriod(.yearly, _): 2
        case .gracePeriod(.monthly, _): 1
        default: 0
        }
    }
}

/// Where entitlements come from. The app's StoreKit 2 source (`Transaction.currentEntitlements`
/// + `Transaction.updates`, verification checked) implements this; Fry's StoreKitTest tests and
/// a fake in AeroDJCore tests plug in the same way.
public protocol EntitlementSource: Sendable {
    /// Current entitlements. Throwing means "unknown", which callers treat as Free.
    func currentEntitlements() async throws -> [EntitlementSnapshot]
    /// Fires whenever entitlements may have changed (purchase, renewal, refund, restore).
    func changes() -> AsyncStream<Void>
}

/// SEAM for Atlas (server entitlement). The proxy decides paid-voice access from Apple's signed
/// transaction (JWS), not from anything the app asserts. When Atlas's hand-off is ready, the
/// app passes the verified JWS through this protocol. Not implemented here: no server or proxy
/// calls, no secrets, and the JWS is never logged.
public protocol ServerEntitlementHandoff: Sendable {
    func handOff(signedTransactionJWS: String) async
}

/// Reads entitlements from a source and resolves them, failing closed on any error.
public struct EntitlementChecker: Sendable {
    public let source: any EntitlementSource
    public init(source: any EntitlementSource) { self.source = source }

    public func status(now: Date = Date()) async -> SubscriptionStatus {
        do {
            return EntitlementResolver.resolve(try await source.currentEntitlements(), now: now)
        } catch {
            return .unavailable
        }
    }
}

/// The app's current tier for the voice gate. Advisory (see top of file); starts Free and is
/// updated by the app's StoreKit listener. Thread-safe; copies of a reference share state.
public final class VoiceEntitlement: @unchecked Sendable {
    /// The app-wide value the live renderer reads.
    public static let shared = VoiceEntitlement(.free)

    private let lock = NSLock()
    private var current: SubscriptionTier

    public init(_ tier: SubscriptionTier = .free) { current = tier }

    /// A fixed tier for tests, previews and the owner A/B build.
    public static func fixed(_ tier: SubscriptionTier) -> VoiceEntitlement { VoiceEntitlement(tier) }

    public var tier: SubscriptionTier { lock.withLock { current } }
    public func set(_ tier: SubscriptionTier) { lock.withLock { current = tier } }
}

/// The paid-voice decision, client side. Privacy first: without consent nothing leaves the
/// device whatever the tier; Free is on-device only even with consent.
public enum CloudVoiceAccess {
    public static func allowsCloudVoice(consent: CloudVoiceConsentState, tier: SubscriptionTier) -> Bool {
        consent == .accepted && tier == .pro
    }

    /// The paywall is offered only after consent is stored, only where a cloud voice exists, and
    /// only to someone not already Pro. Without consent, Pro cannot be bought from the app.
    public static func mayOfferPaywall(consent: CloudVoiceConsentState, cloudVoiceOffered: Bool,
                                       tier: SubscriptionTier) -> Bool {
        cloudVoiceOffered && consent == .accepted && tier == .free
    }
}
