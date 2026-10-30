import Foundation

/// The one place the OnAirly Pro product IDs live (owner pricing, final): a free tier with the
/// on-device voice, and Pro at $4.99/month or $34.99/year for the ElevenLabs voice. Both are
/// auto-renewable subscriptions in one subscription group.
///
/// `ios/StoreKit/OnAirlyPro.storekit` (local StoreKit testing) must match this config; the
/// Linux test `ProSubscriptionConfigTests` reads that file and fails on any drift.
/// App Store Connect products must be created with exactly these IDs (owner step).
///
/// Nothing here is a secret. The App Store Server API key (.p8) and any shared secret live only
/// in the proxy's Production environment, never in the app (Sentinel's entitlement criterion 4).
public enum ProSubscriptionConfig {
    /// The app's bundle ID. It stays `com.aerodj.app` through the OnAirly rename, because
    /// App Attest and the App Store products are keyed to it.
    public static let bundleID = "com.aerodj.app"

    /// Reference name of the subscription group (App Store Connect and the .storekit file).
    public static let subscriptionGroupName = "OnAirly Pro"

    public static let monthlyProductID = "com.aerodj.app.pro.monthly"
    public static let yearlyProductID = "com.aerodj.app.pro.yearly"

    public struct Product: Equatable, Sendable {
        public let id: String
        /// ISO 8601 period, as written in the .storekit file.
        public let period: String
        /// Placeholder-now-final USD display price. The App Store's localized price is
        /// what the paywall shows; this is only for config checks.
        public let usdDisplayPrice: String
    }

    public static let products: [Product] = [
        Product(id: monthlyProductID, period: "P1M", usdDisplayPrice: "4.99"),
        Product(id: yearlyProductID, period: "P1Y", usdDisplayPrice: "34.99"),
    ]

    public static var productIDs: Set<String> { Set(products.map(\.id)) }

    /// Owner decision (Orion): Family Sharing is off for Pro. Mirrors the .storekit file and
    /// the App Store Connect setting; the proxy enforces it (Atlas, #233 PR 2).
    public static let familySharingEnabled = false

    /// A free introductory offer: `numberOfPeriods` periods of `period` (ISO 8601) at no charge.
    public struct FreeTrial: Equatable, Sendable {
        public let period: String
        public let numberOfPeriods: Int
    }

    /// Owner decision (9:19 PM, relayed by Orion): a 7-day free trial on both Pro products, as
    /// each one's introductory offer (payment mode free, one 1-week period). Mirrors the
    /// .storekit file and the App Store Connect offers (owner step). Config checks only: the
    /// paywall reads StoreKit's `introductoryOffer` and the user's eligibility, never this.
    /// A trial is an ordinary signed transaction with an expiry, so `ProEntitlementMapper`
    /// treats it exactly like a paid period (verified, own purchase, not expired or revoked).
    public static let freeTrial = FreeTrial(period: "P1W", numberOfPeriods: 1)

    /// Owner decision (Orion): no grace period. The client display state drops Pro at the
    /// expiry instant. One value so a later decision changes one line; the proxy decides access.
    public static let clientGracePeriodSeconds: TimeInterval = 0
}

/// StoreKit's `Transaction.OwnershipType`, kept so the client mirrors the proxy's
/// `allowFamilyShared: false` (Atlas, #244): a family-shared transaction is not Pro while
/// `ProSubscriptionConfig.familySharingEnabled` is false.
public enum ProOwnership: String, Equatable, Sendable {
    case purchased, familyShared
}

/// A StoreKit transaction reduced to the fields the client-side display state needs.
/// The app maps StoreKit's `.unverified` results with `isVerified: false`; they never count as
/// Pro (fail closed).
public struct ProTransactionSnapshot: Equatable, Sendable {
    public let productID: String
    public let purchaseDate: Date
    public let expirationDate: Date?
    public let revocationDate: Date?
    /// True when a later transaction in the group replaced this one (crossgrade).
    public let isUpgraded: Bool
    /// False when StoreKit returned `.unverified` for it. An unverified transaction never shows Pro.
    public let isVerified: Bool
    /// Purchased by this Apple ID, or shared to it by a family organizer.
    public let ownership: ProOwnership

    public init(productID: String, purchaseDate: Date, expirationDate: Date?,
                revocationDate: Date? = nil, isUpgraded: Bool = false, isVerified: Bool = true,
                ownership: ProOwnership = .purchased) {
        self.productID = productID
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
        self.isVerified = isVerified
        self.ownership = ownership
    }
}

/// The client's view of the user's Pro subscription: what the paywall shows, and one input to
/// `ProVoiceGate`.
///
/// It never grants the paid voice on its own: the proxy verifies the signed transaction itself
/// and decides (Sentinel's criteria 1 and 5), so a wrong client state can only cost the user
/// the paid voice, never spend. It never gates privacy: consent is checked first and separately,
/// and no consent code reads it. Voice and DJ code see only `ProVoiceGate.Decision` (a Linux
/// source-scan test enforces both).
public enum ProEntitlementState: Equatable, Sendable {
    /// No Pro transaction on record: the free tier with the on-device voice.
    case free
    /// An active, unrevoked Pro subscription.
    case pro(productID: String, expiresAt: Date?)
    /// The latest Pro subscription ran out.
    case expired(productID: String, expiredAt: Date)
    /// The latest Pro transaction was refunded or revoked by the App Store.
    case revoked(productID: String, revokedAt: Date)
    /// StoreKit could not verify the only Pro transaction(s) on record.
    case unverified(productID: String)

    public var showsPro: Bool {
        if case .pro = self { return true }
        return false
    }
}

public enum ProEntitlementMapper {
    /// Maps verified transactions to the display state.
    ///
    /// - Transactions for product IDs outside `ProSubscriptionConfig` are ignored.
    /// - Unverified transactions never count; if they are all there is, the state is `.unverified`.
    /// - Any active, unrevoked, non-upgraded transaction wins (the one that runs longest).
    /// - Otherwise the most recent transaction decides between revoked and expired.
    /// - Nothing on record is `.free`.
    public static func state(for transactions: [ProTransactionSnapshot], now: Date,
                             knownProductIDs: Set<String> = ProSubscriptionConfig.productIDs,
                             gracePeriodSeconds: TimeInterval = ProSubscriptionConfig.clientGracePeriodSeconds,
                             familySharingEnabled: Bool = ProSubscriptionConfig.familySharingEnabled) -> ProEntitlementState {
        // Family-shared transactions are dropped like unknown products while Family Sharing is
        // off, so they read as free, never Pro (fail closed, matching the proxy).
        let known = transactions.filter {
            knownProductIDs.contains($0.productID) && (familySharingEnabled || $0.ownership == .purchased)
        }
        let pro = known.filter(\.isVerified)
        if pro.isEmpty, let first = known.first { return .unverified(productID: first.productID) }
        let active = pro.filter { t in
            guard t.revocationDate == nil, !t.isUpgraded else { return false }
            guard let expires = t.expirationDate else { return false } // auto-renewables always expire
            return expires.addingTimeInterval(gracePeriodSeconds) > now
        }
        if let best = active.max(by: { ($0.expirationDate ?? .distantPast) < ($1.expirationDate ?? .distantPast) }) {
            return .pro(productID: best.productID, expiresAt: best.expirationDate)
        }
        guard let latest = pro.max(by: { $0.purchaseDate < $1.purchaseDate }) else { return .free }
        if let revoked = latest.revocationDate {
            return .revoked(productID: latest.productID, revokedAt: revoked)
        }
        return .expired(productID: latest.productID, expiredAt: latest.expirationDate ?? latest.purchaseDate)
    }
}

/// The transactions last read from StoreKit. Its state is recomputed from their own expiration
/// and revocation dates at the moment of asking, never a cached result, so a `.pro` read before
/// an expiry is not `.pro` after it even if no refresh or `Transaction.updates` event came
/// (Sentinel N1, #244). Revocations arrive through `Transaction.updates`, which re-reads.
public struct ProEntitlementRecord: Equatable, Sendable {
    public private(set) var transactions: [ProTransactionSnapshot]

    public init(_ transactions: [ProTransactionSnapshot] = []) {
        self.transactions = transactions
    }

    public func state(now: Date) -> ProEntitlementState {
        ProEntitlementMapper.state(for: transactions, now: now)
    }
}
