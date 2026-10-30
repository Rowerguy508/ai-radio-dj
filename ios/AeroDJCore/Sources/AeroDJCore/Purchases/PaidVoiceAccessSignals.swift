import Foundation

// E1 wiring (Echo's split, #244 review): the paywall and the consent sheet tell the break
// session when paid-voice access really changes, through `DJBreakSession.paidVoiceAccessChanged()`.
// The session drops prepared paid breaks and re-plans on-device if access is now denied; a grant
// changes nothing prepared. The boundary re-check (`takeCheckedBreak`) stays the backstop when no
// signal comes (e.g. an expiry between refreshes). Nothing here reads or logs transaction IDs,
// JWS or the appAccountToken: it sees only the mapped `ProEntitlementState`. -Nova

/// The notification. Injected so tests can observe it; the default is the real call.
public typealias PaidVoiceAccessNotify = @MainActor @Sendable () async -> Void

/// Forwards to the app's one break session (set once in `AppDependencies.live()`, held weakly).
/// With no session yet, a change has nothing prepared to drop, so it is a no-op.
@MainActor
public enum PaidVoiceAccessRelay {
    public static weak var session: DJBreakSession?

    public static func notify() async {
        await session?.paidVoiceAccessChanged()
    }

    /// The real call, as the default notifier.
    public static let live: PaidVoiceAccessNotify = { await PaidVoiceAccessRelay.notify() }
}

/// Deduplicates the paywall's StoreKit reads: notifies only when the *effective* Pro state
/// changes, i.e. whether `ProVoiceGate` would let this entitlement use a paid voice (with
/// consent). A renewal (`.pro` to a later `.pro`), or `.free` to `.expired`/`.unverified`/family-
/// shared, is no change. Starts at "not Pro", matching `ProEntitlementCache`'s `.free`.
@MainActor
public final class ProAccessChangeTracker {
    private var lastPermits = false
    private let notify: PaidVoiceAccessNotify

    public init(notify: @escaping PaidVoiceAccessNotify = PaidVoiceAccessRelay.live) {
        self.notify = notify
    }

    public static func permitsPaidVoice(_ state: ProEntitlementState, now: Date) -> Bool {
        ProVoiceGate.decide(entitlement: state, paidVoiceConsent: true, now: now).permitsPaidVoice
    }

    /// Call after every StoreKit read (launch, `Transaction.updates`, purchase, restore), once the
    /// new state is in `ProEntitlementCache`. Returns true when it notified.
    @discardableResult
    public func entitlementRead(_ state: ProEntitlementState, now: Date) async -> Bool {
        let permits = Self.permitsPaidVoice(state, now: now)
        guard permits != lastPermits else { return false }
        lastPermits = permits
        await notify()
        return true
    }
}

/// The consent sheet's writes. Grant ("Use cloud voice") and revoke ("Keep on-device voice" or
/// the toggle turned off) are written synchronously, as before, and notify when the stored
/// answer's grant actually flips. Declining when never granted is no change.
@MainActor
public final class PaidVoiceConsentSignals {
    private let store: CloudVoiceConsentStore
    private let notify: PaidVoiceAccessNotify

    public init(store: CloudVoiceConsentStore, notify: @escaping PaidVoiceAccessNotify = PaidVoiceAccessRelay.live) {
        self.store = store
        self.notify = notify
    }

    /// Returns the notification task when access changed (tests await it); nil otherwise.
    @discardableResult
    public func accept() -> Task<Void, Never>? { write { store.accept() } }

    @discardableResult
    public func decline() -> Task<Void, Never>? { write { store.decline() } }

    private func write(_ change: () -> Void) -> Task<Void, Never>? {
        let before = store.isGranted
        change()
        guard store.isGranted != before else { return nil }
        let notify = self.notify
        return Task { @MainActor in await notify() }
    }
}
