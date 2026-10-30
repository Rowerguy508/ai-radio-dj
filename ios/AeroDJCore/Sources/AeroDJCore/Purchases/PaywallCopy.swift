import Foundation

/// Paywall and subscription-status copy. Prices are never written here: they come from
/// `Product.displayPrice` at runtime. Plain, short, calm. -Nova
public enum PaywallCopy {
    public static var title: String { "\(AppName.display) Pro" }
    public static let subtitle = "A more natural DJ voice, made online by ElevenLabs."
    public static let freeLine = "Free: the DJ speaks with the voice on your iPhone. Nothing is sent."
    public static let proLine = "Pro: the DJ speaks with a cloud voice. Only the words of each DJ break are sent."
    public static let loadingPrices = "Loading prices…"
    public static let pricesUnavailable = "Prices aren't available right now. Try again later."
    public static let restore = "Restore Purchases"
    public static let manage = "Manage Subscription"
    public static let notNow = "Not now"
    public static let purchasePending = "Waiting for approval. Pro starts once the purchase is approved."
    public static let purchaseFailed = "The purchase didn't go through. You haven't been charged."
    public static let restoreNothing = "No active Pro subscription was found for this Apple Account."

    /// "Pro Yearly, $34.99 per year" – `price` is `Product.displayPrice`.
    public static func planLine(_ period: SubscriptionPeriod, price: String) -> String {
        "\(period.title), \(price) \(period.perPeriod)"
    }

    /// App Store subscription disclosure (Guideline 3.1.2). Shown under the plans.
    public static let autoRenewDisclosure =
        "Payment is charged to your Apple Account when you confirm. The subscription renews automatically at the same price for the same period unless you cancel at least 24 hours before the period ends. Your account is charged for renewal within 24 hours before the period ends. Manage or cancel any time in your Apple Account settings."

    public static let termsLabel = "Terms of Use"
    /// OWNER: placeholder. Apple's standard EULA until the app has its own Terms.
    public static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    public static let privacyLabel = "Privacy Policy"
    /// OWNER: placeholder. No Privacy Policy URL yet; App Review requires one before release.
    public static let privacyURL: URL? = nil

    public static func statusTitle(_ status: ProSubscriptionStatus) -> String {
        switch status {
        case .loading, .free, .unverified, .familyShared: "Free"
        case .pro(let p?, _, _): "Pro (\(p.title.lowercased()))"
        case .pro(nil, _, _): "Pro"
        case .expired: "Pro expired"
        case .revoked: "Pro refunded"
        }
    }

    public static func statusDetail(_ status: ProSubscriptionStatus) -> String {
        switch status {
        case .loading: "On-device voice. Checking your subscription…"
        case .free: "On-device voice."
        case .unverified: "On-device voice. This purchase couldn't be verified."
        case .familyShared: "On-device voice. Pro isn't shared through Family Sharing."
        case .pro(_, let renews, _):
            switch renews {
            case false?: "Cloud voice until the period ends. Won't renew."
            default: "Cloud voice. Renews automatically."
            }
        case .expired: "Back to the on-device voice. Subscribe again any time."
        case .revoked: "This purchase was refunded. Back to the on-device voice."
        }
    }
}

/// A product's introductory offer as the paywall needs it, mapped from StoreKit's
/// `Product.SubscriptionInfo.introductoryOffer` in the app (`period` and `paymentMode`).
/// Pure, so the trial copy is testable on Linux. -Nova
public struct PaywallIntroOffer: Equatable, Sendable {
    public enum Unit: Equatable, Sendable { case day, week, month, year }
    public let value: Int
    public let unit: Unit
    /// `paymentMode == .freeTrial`. Pay-as-you-go and pay-up-front offers are not a free trial.
    public let isFreeTrial: Bool

    public init(value: Int, unit: Unit, isFreeTrial: Bool) {
        self.value = value
        self.unit = unit
        self.isFreeTrial = isFreeTrial
    }
}

extension SubscriptionPeriod {
    /// "/month" / "/year", appended to `Product.displayPrice` in the trial line.
    public var perPeriodShort: String { self == .monthly ? "/month" : "/year" }
}

extension PaywallCopy {
    /// "7 days free, then $4.99/month". `price` is `Product.displayPrice` (localized, never
    /// hard-coded). nil unless the product has a free-trial intro offer AND the user is eligible
    /// (`isEligibleForIntroOffer`): then the paywall shows only the plain `planLine`. -Nova
    public static func trialLine(_ period: SubscriptionPeriod, price: String,
                                 offer: PaywallIntroOffer?, eligible: Bool) -> String? {
        guard eligible, let offer, offer.isFreeTrial, let length = trialLength(offer) else { return nil }
        return "\(length) free, then \(price)\(period.perPeriodShort)"
    }

    /// "7 days" for a one-week trial (the owner's wording), "1 month", "3 days". nil if empty.
    public static func trialLength(_ offer: PaywallIntroOffer) -> String? {
        guard offer.value > 0 else { return nil }
        let (count, noun): (Int, String) = switch offer.unit {
        case .day: (offer.value, "day")
        case .week: (offer.value * 7, "day")
        case .month: (offer.value, "month")
        case .year: (offer.value, "year")
        }
        return "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
