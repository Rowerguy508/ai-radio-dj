import AeroDJCore
import OSLog
import StoreKit
import SwiftUI

// StoreKit 2 paywall and subscription status. The entitlement here is ADVISORY: it drives the UI
// and keeps the app on the on-device voice when not Pro. The server (Atlas) makes the real
// paid-voice decision from Apple's signed transaction; the app never sends an "isPro" flag.
// No secrets, no server or proxy calls. Never log transaction IDs, JWS or appAccountToken.
// Fail-closed: `.unverified`, unknown state or any StoreKit error counts as Free. -Nova

/// `EntitlementSource` backed by `Transaction.currentEntitlements` / `Transaction.updates`.
/// Only verified transactions are mapped as verified; StoreKit's `.unverified` maps to
/// `.unverified`, which the core resolver ignores.
struct StoreKitEntitlementSource: EntitlementSource {
    func currentEntitlements() async throws -> [EntitlementSnapshot] {
        var result: [EntitlementSnapshot] = []
        for await entitlement in Transaction.currentEntitlements {
            result.append(await Self.snapshot(entitlement))
        }
        return result
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task.detached {
                for await update in Transaction.updates {
                    // Finish only verified transactions; an unverified one grants nothing.
                    if case .verified(let transaction) = update { await transaction.finish() }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func snapshot(_ verification: VerificationResult<Transaction>) async -> EntitlementSnapshot {
        switch verification {
        case .unverified(let transaction, _):
            return EntitlementSnapshot(productID: transaction.productID, verification: .unverified,
                                       expirationDate: transaction.expirationDate)
        case .verified(let transaction):
            var state: SubscriptionRenewalState = .unknown
            var willAutoRenew = false
            var grace: Date?
            if let status = await transaction.subscriptionStatus {
                state = Self.map(status.state)
                // Renewal info must verify too; otherwise keep the fail-closed defaults.
                if case .verified(let renewal) = status.renewalInfo {
                    willAutoRenew = renewal.willAutoRenew
                    grace = renewal.gracePeriodExpirationDate
                }
            } else if transaction.revocationDate == nil {
                // No status (e.g. StoreKit couldn't load it): trust only the signed expiry.
                state = .subscribed
            }
            return EntitlementSnapshot(productID: transaction.productID, verification: .verified,
                                       expirationDate: transaction.expirationDate,
                                       revocationDate: transaction.revocationDate,
                                       isUpgraded: transaction.isUpgraded, renewalState: state,
                                       willAutoRenew: willAutoRenew, gracePeriodExpirationDate: grace)
        }
    }

    static func map(_ state: Product.SubscriptionInfo.RenewalState) -> SubscriptionRenewalState {
        switch state {
        case .subscribed: .subscribed
        case .inGracePeriod: .inGracePeriod
        case .inBillingRetryPeriod: .inBillingRetryPeriod
        case .expired: .expired
        case .revoked: .revoked
        default: .unknown
        }
    }
}

/// App-wide subscription state for the paywall and the status card. Updates
/// `VoiceEntitlement.shared`, which the live `VoiceRenderer` reads before every cloud render.
@MainActor @Observable
final class SubscriptionModel {
    static let shared = SubscriptionModel(source: StoreKitEntitlementSource())

    enum Prices: Equatable {
        case loading
        case loaded
        case unavailable
    }

    private(set) var status: SubscriptionStatus = .unavailable
    private(set) var products: [Product] = []
    private(set) var prices: Prices = .loading
    private(set) var message: String?
    private(set) var isBusy = false
    var isPaywallPresented = false

    private let checker: EntitlementChecker
    private let source: any EntitlementSource
    private var listener: Task<Void, Never>?
    // SEAM (Atlas): `ServerEntitlementHandoff` takes a verified transaction's JWS once the server
    // design (#233) lands. Not wired: no proxy calls here.
    private let log = Logger(subsystem: "com.aerodj.app", category: "subscription")

    init(source: any EntitlementSource) {
        self.source = source
        self.checker = EntitlementChecker(source: source)
    }

    /// Starts listening for purchases, renewals, refunds and restores, then reads the current state.
    func start() {
        guard listener == nil else { return }
        let changes = source.changes()
        listener = Task { [weak self] in
            for await _ in changes { await self?.refreshStatus() }
        }
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        let status = await checker.status()
        self.status = status
        VoiceEntitlement.shared.set(status.tier)
        // Status category only; never IDs, JWS or tokens.
        log.notice("subscription tier=\(status.tier.rawValue, privacy: .public)")
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        prices = .loading
        do {
            let loaded = try await Product.products(for: SubscriptionProducts.all)
            products = SubscriptionProducts.all.compactMap { id in loaded.first { $0.id == id } }
            prices = products.isEmpty ? .unavailable : .loaded
        } catch {
            prices = .unavailable
        }
    }

    func purchase(_ product: Product) async {
        // Privacy first: no purchase path without stored consent.
        guard CloudVoiceAccess.mayOfferPaywall(consent: CloudVoiceConsentModel.shared.state,
                                               cloudVoiceOffered: CloudVoiceConsentModel.shared.isCloudVoiceOffered,
                                               tier: status.tier) else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification { await transaction.finish() }
                await refreshStatus()
                if status.tier == .pro { isPaywallPresented = false } else { message = PaywallCopy.purchaseFailed }
            case .pending:
                message = PaywallCopy.purchasePending
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = PaywallCopy.purchaseFailed
        }
    }

    /// Restore Purchases: `AppStore.sync()` then re-read entitlements.
    func restore() async {
        isBusy = true
        defer { isBusy = false }
        message = nil
        try? await AppStore.sync()
        await refreshStatus()
        if status.tier == .pro { isPaywallPresented = false } else { message = PaywallCopy.restoreNothing }
    }

    /// Offers the paywall only after consent, where a cloud voice exists, to a Free listener.
    func offerIfAllowed() {
        let consent = CloudVoiceConsentModel.shared
        if CloudVoiceAccess.mayOfferPaywall(consent: consent.state, cloudVoiceOffered: consent.isCloudVoiceOffered,
                                            tier: status.tier) {
            isPaywallPresented = true
        }
    }

    func plan(for product: Product) -> SubscriptionPeriod? { SubscriptionProducts.period(for: product.id) }
}

extension View {
    /// Starts the StoreKit listener and hosts the paywall sheet. Pair with `cloudVoiceConsentGate()`.
    func subscriptionPaywallHost() -> some View { modifier(SubscriptionPaywallHost()) }
}

private struct SubscriptionPaywallHost: ViewModifier {
    @Bindable private var model = SubscriptionModel.shared

    func body(content: Content) -> some View {
        content
            .task { model.start() }
            .sheet(isPresented: $model.isPaywallPresented) { PaywallView() }
    }
}

struct PaywallView: View {
    @Bindable private var model = SubscriptionModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isManaging = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "waveform")
                    .font(.largeTitle)
                    .foregroundStyle(AeroDJPalette.accentText)
                    .accessibilityHidden(true)
                Text(PaywallCopy.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("paywall.title")
                Text(PaywallCopy.subtitle)
                Text(PaywallCopy.freeLine).foregroundStyle(AeroDJPalette.secondaryText)
                Text(PaywallCopy.proLine).foregroundStyle(AeroDJPalette.secondaryText)
                plans
                if let message = model.message {
                    Text(message)
                        .font(.callout)
                        .accessibilityIdentifier("paywall.message")
                }
                secondaryActions
                disclosures
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityIdentifier("paywall.sheet")
        .task { await model.loadProducts() }
        .transaction { if reduceMotion { $0.animation = nil } }
        .manageSubscriptionsSheet(isPresented: $isManaging)
    }

    @ViewBuilder private var plans: some View {
        switch model.prices {
        case .loading:
            // Neutral loading state: no prices are ever hard-coded.
            HStack(spacing: 8) {
                ProgressView()
                Text(PaywallCopy.loadingPrices)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("paywall.loading")
        case .unavailable:
            Text(PaywallCopy.pricesUnavailable)
                .accessibilityIdentifier("paywall.unavailable")
        case .loaded:
            VStack(spacing: 10) {
                ForEach(model.products, id: \.id) { product in
                    if let period = model.plan(for: product) {
                        Button { Task { await model.purchase(product) } } label: {
                            Text(PaywallCopy.planLine(period, price: product.displayPrice))
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                        .aeroGlass(Capsule(), role: .control, fallback: AnyShapeStyle(.tint.opacity(0.18)))
                        .accessibilityLabel("Subscribe \(period.title.lowercased()), \(product.displayPrice) \(period.perPeriod)")
                        .accessibilityHint("Auto-renews until cancelled.")
                        .accessibilityIdentifier("paywall.plan.\(period.rawValue)")
                    }
                }
            }
        }
    }

    private var secondaryActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { secondaryButtons }
            VStack(alignment: .leading, spacing: 10) { secondaryButtons }
        }
        .font(.callout)
    }

    @ViewBuilder private var secondaryButtons: some View {
        Button(PaywallCopy.restore) { Task { await model.restore() } }
            .disabled(model.isBusy)
            .accessibilityIdentifier("paywall.restore")
        Button(PaywallCopy.manage) { isManaging = true }
            .accessibilityIdentifier("paywall.manage")
        Button(PaywallCopy.notNow) { dismiss() }
            .accessibilityIdentifier("paywall.notNow")
    }

    private var disclosures: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PaywallCopy.autoRenewDisclosure)
                .accessibilityIdentifier("paywall.disclosure")
            HStack(spacing: 12) {
                Link(PaywallCopy.termsLabel, destination: PaywallCopy.termsURL)
                    .accessibilityIdentifier("paywall.terms")
                // OWNER: placeholder; shown once the app's Privacy Policy URL exists.
                if let privacy = PaywallCopy.privacyURL {
                    Link(PaywallCopy.privacyLabel, destination: privacy)
                        .accessibilityIdentifier("paywall.privacy")
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(AeroDJPalette.secondaryText)
    }
}

/// Tune → DJ: Free / Pro (monthly, yearly) / payment issue / expired / refunded. Shown only where
/// a cloud voice exists. "See Pro" appears only after consent; without it Pro can't be bought.
struct SubscriptionStatusCard: View {
    @Bindable private var model = SubscriptionModel.shared
    @Bindable private var consent = CloudVoiceConsentModel.shared
    @State private var isManaging = false

    var body: some View {
        if consent.isCloudVoiceOffered {
            VStack(alignment: .leading, spacing: 8) {
                Text(PaywallCopy.statusTitle(model.status))
                    .font(.headline)
                    .accessibilityIdentifier("tune.subscriptionStatus")
                Text(PaywallCopy.statusDetail(model.status))
                    .font(.caption).foregroundStyle(AeroDJPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if CloudVoiceAccess.mayOfferPaywall(consent: consent.state, cloudVoiceOffered: true, tier: model.status.tier) {
                    Button("See \(PaywallCopy.title)") { model.isPaywallPresented = true }
                        .accessibilityIdentifier("tune.seePro")
                }
                if model.status.tier == .pro || isLapsed {
                    Button(PaywallCopy.manage) { isManaging = true }
                        .accessibilityIdentifier("tune.manageSubscription")
                }
            }
            .accessibilityElement(children: .contain)
            .padding(14)
            .workspaceCardBackground(Color(.tertiarySystemFill).opacity(0.6))
            .manageSubscriptionsSheet(isPresented: $isManaging)
        }
    }

    private var isLapsed: Bool {
        if case .expired = model.status { return true }
        return false
    }
}
