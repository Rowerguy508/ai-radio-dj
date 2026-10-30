import AeroDJCore
import OSLog
import StoreKit
import SwiftUI

// StoreKit 2 paywall and subscription status, stacked on Fry's #244. Product IDs come from
// `ProSubscriptionConfig`; the state is `ProEntitlementMapper`'s; the voice gate is `ProVoiceGate`.
// ADVISORY: the proxy verifies Apple's signed transaction and decides (Atlas); the app never
// sends an "isPro" flag. No secrets, no server or proxy calls. Never log transaction IDs, JWS or
// the appAccountToken. Fail closed: unverified, expired, revoked, family-shared, unknown or any
// StoreKit error counts as Free. -Nova

/// The StoreKit entitlement type: reads verified `Transaction.currentEntitlements` (plus the latest
/// transaction per product, so expired and refunded show as such), listens to
/// `Transaction.updates`, and is the app's `ProEntitlementProviding`.
@MainActor @Observable
final class SubscriptionModel: ProEntitlementProviding {
    static let shared = SubscriptionModel()

    enum Prices: Equatable {
        case loading
        case loaded
        case unavailable
    }

    private(set) var status: ProSubscriptionStatus = .loading
    private(set) var products: [Product] = []
    private(set) var prices: Prices = .loading
    private(set) var message: String?
    private(set) var isBusy = false
    var isPaywallPresented = false

    /// What `ProVoiceAccess.live` reads; written only here.
    nonisolated let entitlement: ProEntitlementCache
    private let tokens: AppAccountTokenProvider
    /// Tells the break session when the effective Pro state changes (E1), deduped.
    private let accessChanges: ProAccessChangeTracker
    private var listener: Task<Void, Never>?
    // SEAM (Atlas): `ServerEntitlementHandoff` takes a verified transaction's JWS once the server
    // design (#233) lands. Not wired: no proxy calls here.
    private let log = Logger(subsystem: "com.aerodj.app", category: "subscription")

    init(entitlement: ProEntitlementCache = .shared,
         tokens: AppAccountTokenProvider = AppAccountTokenProvider(store: KeychainAppAccountTokenStore()),
         accessChanges: ProAccessChangeTracker? = nil) {
        self.entitlement = entitlement
        self.tokens = tokens
        self.accessChanges = accessChanges ?? ProAccessChangeTracker()
    }

    nonisolated func currentProEntitlement() async -> ProEntitlementState {
        await entitlement.currentProEntitlement()
    }

    /// Starts listening for purchases, renewals, refunds and restores, then reads the current state.
    func start() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await update in Transaction.updates {
                // Finish only verified transactions; an unverified one grants nothing.
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refreshStatus()
            }
        }
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        var transactions: [ProTransactionSnapshot] = []
        var willAutoRenew: Bool?
        for id in ProSubscriptionConfig.productIDs.sorted() {
            guard let result = await Transaction.latest(for: id) else { continue }
            if let snapshot = Self.snapshot(result) { transactions.append(snapshot) }
            if case .verified(let transaction) = result, transaction.revocationDate == nil,
               let status = await transaction.subscriptionStatus,
               case .verified(let renewal) = status.renewalInfo {
                willAutoRenew = (willAutoRenew ?? false) || renewal.willAutoRenew
            }
        }
        // Plus the current entitlements (active, verified-or-not, possibly family-shared), so an
        // active Pro is never missed. The mapper filters and fails closed either way.
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, !ProSubscriptionConfig.productIDs.contains(t.productID) { continue }
            if let snapshot = Self.snapshot(result) { transactions.append(snapshot) }
        }
        let state = ProEntitlementMapper.state(for: transactions, now: Date())
        entitlement.set(state)
        status = ProSubscriptionStatus(state: state, willAutoRenew: willAutoRenew,
                                       onlyFamilyShared: ProStoreEntitlement.onlyFamilyShared(transactions))
        // Status category only; never IDs, JWS or tokens.
        log.notice("subscription pro=\(self.status.isPro, privacy: .public)")
        // After the cache holds the new state, so the session's re-check reads it (E1).
        await accessChanges.entitlementRead(state, now: Date())
    }

    /// #244's snapshot, with #244's `ProOwnership`. An ownership type this build doesn't know is
    /// skipped (fail closed: never counted as Pro); family-shared is dropped by the mapper.
    static func snapshot(_ result: VerificationResult<Transaction>) -> ProTransactionSnapshot? {
        let (t, verified): (Transaction, Bool) = switch result {
        case .verified(let t): (t, true)
        case .unverified(let t, _): (t, false)
        }
        let ownership: ProOwnership
        switch t.ownershipType {
        case .purchased: ownership = .purchased
        case .familyShared: ownership = .familyShared
        default: return nil
        }
        return ProTransactionSnapshot(productID: t.productID, purchaseDate: t.purchaseDate,
                                      expirationDate: t.expirationDate, revocationDate: t.revocationDate,
                                      isUpgraded: t.isUpgraded, isVerified: verified, ownership: ownership)
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        prices = .loading
        do {
            let loaded = try await Product.products(for: SubscriptionPeriod.paywallOrder)
            products = SubscriptionPeriod.paywallOrder.compactMap { id in loaded.first { $0.id == id } }
            prices = products.isEmpty ? .unavailable : .loaded
        } catch {
            prices = .unavailable
        }
    }

    /// `ProPurchasePlan` mapped to StoreKit: always the install's appAccountToken (#233 §5.4).
    func purchaseOptions() -> Set<Product.PurchaseOption> {
        Set(ProPurchasePlan.options(token: tokens.token()).map { option in
            switch option {
            case .appAccountToken(let uuid): Product.PurchaseOption.appAccountToken(uuid)
            }
        })
    }

    func purchase(_ product: Product) async {
        // Privacy first: no purchase path without stored consent.
        guard PaywallOffer.mayOffer(consent: CloudVoiceConsentModel.shared.state,
                                    cloudVoiceOffered: CloudVoiceConsentModel.shared.isCloudVoiceOffered,
                                    status: status) else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil
        do {
            switch try await product.purchase(options: purchaseOptions()) {
            case .success(let verification):
                if case .verified(let transaction) = verification { await transaction.finish() }
                await refreshStatus()
                if status.isPro { isPaywallPresented = false } else { message = PaywallCopy.purchaseFailed }
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
        if status.isPro { isPaywallPresented = false } else { message = PaywallCopy.restoreNothing }
    }

    /// Offers the paywall only after consent, where a cloud voice exists, to someone not Pro.
    func offerIfAllowed() {
        let consent = CloudVoiceConsentModel.shared
        if PaywallOffer.mayOffer(consent: consent.state, cloudVoiceOffered: consent.isCloudVoiceOffered, status: status) {
            isPaywallPresented = true
        }
    }

    func plan(for product: Product) -> SubscriptionPeriod? { SubscriptionPeriod(productID: product.id) }
}

extension View {
    /// Starts the StoreKit listener and hosts the paywall sheet. Pair with `cloudVoiceConsentGate()`.
    func subscriptionPaywallHost() -> some View { modifier(SubscriptionPaywallHost()) }
}

private struct SubscriptionPaywallHost: ViewModifier {
    @Bindable private var model = SubscriptionModel.shared

    func body(content: Content) -> some View {
        content
            .task {
                model.start()
                #if DEBUG
                // UI tests only: show the sheet without a cloud voice. Buying still needs consent.
                if ProcessInfo.processInfo.arguments.contains("-AeroDJShowPaywall") { model.isPaywallPresented = true }
                #endif
            }
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
                if PaywallOffer.mayOffer(consent: consent.state, cloudVoiceOffered: true, status: model.status) {
                    Button("See \(PaywallCopy.title)") { model.isPaywallPresented = true }
                        .accessibilityIdentifier("tune.seePro")
                }
                if model.status.isPro || isLapsed {
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
