import Foundation

// E1 wiring (Echo's split, #244 review): the paywall and the consent sheet tell the break
// session when paid-voice access really changes, through `DJBreakSession.paidVoiceAccessChanged()`.
// The session drops prepared paid breaks and re-plans on-device if access is now denied; a grant
// changes nothing prepared. An expiry between refreshes is reported by the tracker's one-shot
// expiry timer (Fry's recommendation); the boundary re-check (`takeCheckedBreak`) stays the
// backstop. Nothing here reads or logs transaction IDs,
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

    /// Deletes cached cloud clips (N4); set once in `AppDependencies.live()` to the live
    /// renderer's `purgeCloudClips()`. Unset: nothing cached to delete yet.
    public static var purgeCloudAudio: (@Sendable () async -> Void)?

    /// The real purge, as the default for `PaidVoiceConsentSignals`.
    public static let livePurge: PaidVoiceAccessNotify = { await PaidVoiceAccessRelay.purgeCloudAudio?() }
}

/// Cancels one scheduled expiry check.
public typealias PaidVoiceExpiryCancel = @MainActor () -> Void

/// Runs `fire` once at `date` (or right away if it has passed) unless cancelled first. Injected so
/// Linux tests drive the clock by hand; `live` sleeps in a Task. Never touches StoreKit.
public typealias PaidVoiceExpiryScheduler =
    @MainActor (_ date: Date, _ fire: @escaping @MainActor @Sendable () async -> Void) -> PaidVoiceExpiryCancel

public enum PaidVoiceExpiryTimer {
    @MainActor
    public static let live: PaidVoiceExpiryScheduler = { date, fire in
        let task = Task { @MainActor in
            let wait = date.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            await fire()
        }
        return { task.cancel() }
    }
}

/// Deduplicates the paywall's StoreKit reads: notifies only when the *effective* Pro state
/// changes, i.e. whether `ProVoiceGate` would let this entitlement use a paid voice (with
/// consent). A renewal (`.pro` to a later `.pro`), or `.free` to `.expired`/`.unverified`/family-
/// shared, is no change. Starts at "not Pro", matching `ProEntitlementCache`'s `.free`.
///
/// Expiry between refreshes (Fry's recommendation): every read re-arms exactly one timer. A
/// `.pro` with a future `expiresAt` arms it for that date; any other state (`.free`, `.expired`,
/// `.unverified`, `.revoked`, `.pro` with no expiry) only cancels the old one. At the date the
/// tracker first re-reads StoreKit (`refreshOnExpiry`, i.e. `refreshStatus()`; Sentinel N1) and
/// then calls `paidVoiceAccessChanged()` exactly once. The refresh's own read does not notify
/// while the timer is firing, so there is one notification per expiry. An early wake-up re-arms.
/// A date already past is judged right away by the read itself.
@MainActor
public final class ProAccessChangeTracker {
    private var lastPermits = false
    private let notify: PaidVoiceAccessNotify
    private let schedule: PaidVoiceExpiryScheduler
    private let now: @Sendable () -> Date
    private var cancelExpiry: PaidVoiceExpiryCancel?
    /// Bumped on every arm, so a timer that fires after being replaced does nothing.
    private var generation = 0
    /// True while an expiry fire waits on its refresh: that read updates the state but the fire
    /// sends the one notification afterwards.
    private var expiryFiring = false
    /// Re-reads StoreKit when the timer fires (`ProStatusRefresher` sets it to its `refresh()`).
    /// nil: the tracker re-judges the cached state at its clock.
    public var refreshOnExpiry: (@MainActor () async -> Void)?

    public init(notify: @escaping PaidVoiceAccessNotify = PaidVoiceAccessRelay.live,
                schedule: @escaping PaidVoiceExpiryScheduler = PaidVoiceExpiryTimer.live,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.notify = notify
        self.schedule = schedule
        self.now = now
    }

    public static func permitsPaidVoice(_ state: ProEntitlementState, now: Date) -> Bool {
        ProVoiceGate.decide(entitlement: state, paidVoiceConsent: true, now: now).permitsPaidVoice
    }

    /// Call after every StoreKit read (launch, `Transaction.updates`, purchase, restore), once the
    /// new state is in `ProEntitlementCache`. Returns true when it notified.
    @discardableResult
    public func entitlementRead(_ state: ProEntitlementState, now: Date) async -> Bool {
        armExpiry(for: state, now: now)
        let permits = Self.permitsPaidVoice(state, now: now)
        guard permits != lastPermits else { return false }
        lastPermits = permits
        if expiryFiring { return false }   // the firing timer notifies once after its refresh
        await notify()
        return true
    }

    private func armExpiry(for state: ProEntitlementState, now: Date) {
        cancelExpiry?()
        cancelExpiry = nil
        generation += 1
        guard case .pro(_, let expiresAt?) = state, expiresAt > now else { return }
        let armed = generation
        cancelExpiry = schedule(expiresAt) { [weak self] in
            guard let self, self.generation == armed else { return }
            await self.expiryFired(state, at: expiresAt, armed: armed)
        }
    }

    /// N1: at `.pro`'s expiry, refresh from StoreKit, then notify the session exactly once.
    private func expiryFired(_ state: ProEntitlementState, at expiresAt: Date, armed: Int) async {
        let wokeAt = now()
        guard wokeAt >= expiresAt else { return armExpiry(for: state, now: wokeAt) }   // early wake-up
        expiryFiring = true
        if let refreshOnExpiry { await refreshOnExpiry() }
        expiryFiring = false
        if generation == armed {
            // No read landed (no refresher, or a refresh that was superseded or failed): judge the
            // cached state at the clock, which also clears this timer.
            let at = now()
            armExpiry(for: state, now: at)
            lastPermits = Self.permitsPaidVoice(state, now: at)
        }
        await notify()
    }
}

/// The consent sheet's writes. A revoke also deletes cached cloud clips (N4). Grant ("Use cloud voice") and revoke ("Keep on-device voice" or
/// the toggle turned off) are written synchronously, as before, and notify when the stored
/// answer's grant actually flips. Declining when never granted is no change.
@MainActor
public final class PaidVoiceConsentSignals {
    private let store: CloudVoiceConsentStore
    private let notify: PaidVoiceAccessNotify
    private let purgeCloudAudio: PaidVoiceAccessNotify

    /// `purgeCloudAudio` runs on a revoke (granted to not granted), before the notification, so
    /// the re-plan cannot pick a cached cloud clip back up (N4).
    public init(store: CloudVoiceConsentStore, notify: @escaping PaidVoiceAccessNotify = PaidVoiceAccessRelay.live,
                purgeCloudAudio: @escaping PaidVoiceAccessNotify = PaidVoiceAccessRelay.livePurge) {
        self.store = store
        self.notify = notify
        self.purgeCloudAudio = purgeCloudAudio
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
        let purge = before ? self.purgeCloudAudio : nil   // revoked: delete cached cloud clips first
        return Task { @MainActor in
            if let purge { await purge() }
            await notify()
        }
    }
}

/// One StoreKit read, as `SubscriptionModel.refreshStatus()` builds it: the entitlement for the
/// cache and the status card's state. No IDs, JWS or tokens. -Nova
public struct ProStatusRead: Equatable, Sendable {
    public let state: ProEntitlementState
    public let status: ProSubscriptionStatus

    public init(state: ProEntitlementState, status: ProSubscriptionStatus) {
        self.state = state
        self.status = status
    }
}

/// `SubscriptionModel.refreshStatus()`'s ordering, in core so it is testable on Linux (Sentinel):
/// - N3: every call takes a token; only the latest call may write the cache, so an older,
///   overlapping refresh that resolves last can't put a stale `.pro` back.
/// - Then the status card, then `ProAccessChangeTracker.entitlementRead` (E1, re-arms expiry).
/// - N1: the tracker's expiry timer calls `refresh()`.
/// - N4: `sceneBecameActive()` refreshes when the app comes to the foreground.
@MainActor
public final class ProStatusRefresher {
    private let cache: ProEntitlementCache
    private let tracker: ProAccessChangeTracker
    private let read: @MainActor () async -> ProStatusRead
    private let apply: @MainActor (ProSubscriptionStatus) -> Void
    private let now: @Sendable () -> Date
    private var latest = 0

    public init(cache: ProEntitlementCache, tracker: ProAccessChangeTracker,
                now: @escaping @Sendable () -> Date = { Date() },
                read: @escaping @MainActor () async -> ProStatusRead,
                apply: @escaping @MainActor (ProSubscriptionStatus) -> Void = { _ in }) {
        self.cache = cache
        self.tracker = tracker
        self.now = now
        self.read = read
        self.apply = apply
        tracker.refreshOnExpiry = { [weak self] in await self?.refresh() }
    }

    /// Returns false when a newer refresh started while this one was reading (nothing written).
    @discardableResult
    public func refresh() async -> Bool {
        latest += 1
        let token = latest
        let result = await read()
        guard token == latest else { return false }   // N3: a newer refresh owns the cache
        cache.set(result.state)
        apply(result.status)
        // After the cache holds the new state, so the session's re-check reads it (E1).
        await tracker.entitlementRead(result.state, now: now())
        return true
    }

    /// N4: scenePhase `.active` (back in the foreground).
    public func sceneBecameActive() async { await refresh() }
}
