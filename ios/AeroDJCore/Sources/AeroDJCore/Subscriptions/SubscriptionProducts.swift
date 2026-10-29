import Foundation

/// The one place product IDs live. The App Store Connect products, Fry's `.storekit` test config
/// and Atlas's server entitlement must use exactly these IDs. Prices are set in App Store Connect
/// and shown from `Product.displayPrice`; the placeholders below are documentation only and are
/// never displayed. -Nova
public enum SubscriptionProducts {
    /// Subscription group reference name (App Store Connect). Both products are in this group,
    /// yearly ranked above monthly, so switching is an upgrade/downgrade, not a second sub.
    public static let groupName = "Pro"

    public static let proMonthly = "com.aerodj.app.pro.monthly"
    public static let proYearly = "com.aerodj.app.pro.yearly"

    /// Every product the app requests from StoreKit, in paywall order.
    public static let all: [String] = [proYearly, proMonthly]

    /// Placeholder pricing (owner): Pro $4.99/month, $34.99/year. Not shown in the UI.
    public static let placeholderUSD: [String: Decimal] = [proMonthly: 4.99, proYearly: 34.99]

    public static func period(for productID: String) -> SubscriptionPeriod? {
        switch productID {
        case proMonthly: .monthly
        case proYearly: .yearly
        default: nil
        }
    }
}

public enum SubscriptionPeriod: String, Equatable, Sendable, CaseIterable {
    case monthly
    case yearly

    /// "per month" / "per year", appended to `Product.displayPrice`.
    public var perPeriod: String {
        switch self {
        case .monthly: "per month"
        case .yearly: "per year"
        }
    }

    public var title: String {
        switch self {
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }
}
