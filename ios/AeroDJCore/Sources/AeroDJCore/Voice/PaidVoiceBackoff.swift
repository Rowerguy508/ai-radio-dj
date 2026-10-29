import Foundation

/// Client-side backoff for the paid voice proxy (aerodj-tts).
///
/// Without it, once the proxy answers 429 for its daily character cap the app keeps calling it
/// on every break until the cap resets. With it, `ProxyVoiceProvider` checks `suspendedUntil()`
/// before building a request: while suspended it throws `VoiceRenderError.suspended` with no
/// token read and no network call, and `VoiceRenderer` moves on to the next route (the existing
/// on-device fallback) exactly as it does for any other provider error.
///
/// Policy (the app half of the #233 §4.4 error contract, rev 2 at `8e2c1b4`):
/// - **429**: the `reason` in the JSON error body picks the wait.
///   - `install_daily` / `global_daily` / `owner_daily` / `sandbox_daily`: until `Retry-After`,
///     or the next UTC midnight without one.
///   - `rate` / `enroll`: `Retry-After`, or 60 s without one.
///   - missing or unknown reason: `Retry-After`, or the next UTC midnight (treated as the daily cap).
///   Every 429 wait is clamped to [60 s, 24 h]. A 429 is persisted.
/// - **503 and every other 5xx** (`500 misconfig`, `502 upstream`, `504 upstream_timeout` are
///   "treat as 503 unknown"): `Retry-After` when present, clamped to [30 s, 24 h]. Without it,
///   `disabled` (the kill switch) waits 1 h, `apple` (App Store status API unreachable) waits
///   5 min, and `store` or anything else uses the exponential backoff. Persisted.
/// - **Transport error**: exponential backoff, 30 s doubling per consecutive failure up to 15 min.
///   No 5xx or transport error ever shortens a longer suspension.
/// - **Stop for the rest of this launch** (in memory only, never persisted; the next launch tries
///   once): 401 (any reason) or an attestation failure; 400 `mixed_auth`; 405; 403 `install_limit`;
///   and any other 4xx with a missing or unknown reason (the contract's unknown-4xx rule).
/// - **403 `no_entitlement`**: stop paid calls in memory until `entitlementDidChange()` (called on
///   `Transaction.updates` or after a successful `/api/entitlement` re-sync) or the next launch.
///   Nothing here opens a paywall: the only effect is that the provider throws `.suspended`.
/// - **400 `bad_request` and 413**: that request is not retried (on-device for the cue); no state
///   change, so the next cue may use the paid route.
/// - **200 whose audio fails validation** (content type, size, duration): the call may already be
///   billed, so pause 5 min doubling per consecutive failure up to 1 h. Persisted. Never shortens
///   a longer suspension.
/// - **200 with valid audio**: clears the failure count and any timed suspension. It does not lift
///   a stop for this launch (no call can be made while stopped anyway).
/// - Cancellation and our own timeout leave the state as it is.
///
public final class PaidVoiceBackoff: @unchecked Sendable {
    public enum Reason: String, Codable, Equatable, Sendable {
        case rateLimited, serverError
        /// 429 `install_daily` / `global_daily`.
        case dailyCap
        /// 503 `disabled` (the proxy's kill switch).
        case disabled
        /// 503 `apple`: the App Store status API was unreachable (#233 §5.6).
        case apple
        /// A 200 whose audio failed validation.
        case invalidAudio
    }

    /// Why the paid route is stopped for the rest of this launch (in memory only).
    public enum StopReason: String, Equatable, Sendable {
        /// 401 (any reason) or an App Attest failure.
        case unauthorized
        /// 403 `no_entitlement`. Lifted by `entitlementDidChange()`.
        case noEntitlement
        /// 403 `install_limit` (too many installs on one purchase). Lasts until the next launch.
        case installLimit
        /// 400 `mixed_auth`, 405, or a 4xx with a missing or unknown reason: a client bug.
        case clientError
    }

    /// The `reason` enum the proxy puts in its error body (`{ error, requestId, reason }`, #233 §4.4).
    public enum ProxyErrorReason: String, Equatable, Sendable {
        case rate, enroll, store, disabled, reattest, assertion, apple, misconfig, upstream
        case installDaily = "install_daily"
        case globalDaily = "global_daily"
        case ownerDaily = "owner_daily"
        case sandboxDaily = "sandbox_daily"
        case noEntitlement = "no_entitlement"
        case installLimit = "install_limit"
        case badRequest = "bad_request"
        case mixedAuth = "mixed_auth"
        case tooLarge = "too_large"
        case ownerToken = "owner_token"
        case upstreamTimeout = "upstream_timeout"

        public static let allDailyCaps: [ProxyErrorReason] = [.installDaily, .globalDaily, .ownerDaily, .sandboxDaily]

        /// The four 429 reasons that mean a daily character cap (#233 §4.4).
        public var isDailyCap: Bool {
            switch self {
            case .installDaily, .globalDaily, .ownerDaily, .sandboxDaily: return true
            default: return false
            }
        }

        /// Reads `reason` from a small JSON error body. Nil for a large, non-JSON or unknown body.
        public static func parse(_ body: Data) -> ProxyErrorReason? {
            guard !body.isEmpty, body.count <= 4096,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let raw = object["reason"] as? String else { return nil }
            return ProxyErrorReason(rawValue: raw)
        }
    }

    public struct State: Codable, Equatable, Sendable {
        public var suspendedUntil: Date?
        public var reason: Reason?
        /// Consecutive 5xx or transport failures since the last 200.
        public var consecutiveFailures: Int

        public init(suspendedUntil: Date? = nil, reason: Reason? = nil, consecutiveFailures: Int = 0) {
            self.suspendedUntil = suspendedUntil
            self.reason = reason
            self.consecutiveFailures = consecutiveFailures
        }
    }

    public static let minimumRateLimitWait: TimeInterval = 60
    public static let maximumRateLimitWait: TimeInterval = 24 * 60 * 60
    public static let serverErrorBaseWait: TimeInterval = 30
    public static let serverErrorMaximumWait: TimeInterval = 15 * 60
    public static let shortRateLimitWait: TimeInterval = 60
    public static let disabledWait: TimeInterval = 60 * 60
    /// 503 `apple` without a `Retry-After` (the contract's value is 300).
    public static let appleWait: TimeInterval = 5 * 60
    public static let invalidAudioBaseWait: TimeInterval = 5 * 60
    public static let invalidAudioMaximumWait: TimeInterval = 60 * 60

    private let lock = NSLock()
    private let store: (any PaidVoiceBackoffStore)?
    private let now: @Sendable () -> Date
    private var state: State
    /// Set by a 401, an attestation failure or a stopping 4xx. In memory only: lasts until the next launch.
    private var stop: StopReason?

    public init(store: (any PaidVoiceBackoffStore)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        state = store?.load() ?? State()
    }

    /// The time the paid route resumes, or nil when it is not suspended now.
    public func suspendedUntil() -> Date? {
        lock.withLock {
            if stop != nil { return .distantFuture }
            guard let until = state.suspendedUntil, until > now() else { return nil }
            return until
        }
    }

    /// True after a 401, an attestation failure or a stopping 4xx, until the next launch
    /// (or, for `no_entitlement`, until `entitlementDidChange()`).
    public var isStoppedForThisLaunch: Bool { lock.withLock { stop != nil } }

    /// Why the paid route is stopped, for diagnostics and Nova's status UI ("too many devices").
    public var stopReason: StopReason? { lock.withLock { stop } }

    public var snapshot: State { lock.withLock { state } }

    /// A 200 whose audio passed validation: clear the failure count and any timed suspension.
    public func recordSuccess() {
        update { state in
            guard state != State() else { return false }
            state = State()
            return true
        }
    }

    /// A 429. `retryAfter` is the raw `Retry-After` header value, if any; `reason` comes from the body.
    public func recordRateLimited(retryAfter: String?, reason: ProxyErrorReason? = nil) {
        let at = now()
        let wait = Self.rateLimitWait(retryAfter: retryAfter, reason: reason, now: at)
        let kind: Reason = reason?.isDailyCap == true ? .dailyCap : .rateLimited
        update { state in
            state.suspendedUntil = at.addingTimeInterval(wait)
            state.reason = kind
            return true
        }
    }

    /// A 503 (`store`, `disabled` or no reason). Honors `Retry-After`, and never shortens a longer suspension.
    public func recordServiceUnavailable(retryAfter: String?, reason: ProxyErrorReason? = nil) {
        let at = now()
        update { state in
            state.consecutiveFailures += 1
            let wait = Self.serviceUnavailableWait(retryAfter: retryAfter, reason: reason,
                                                   consecutiveFailures: state.consecutiveFailures, now: at)
            let until = at.addingTimeInterval(wait)
            if let current = state.suspendedUntil, current > until, current > at { return true }
            state.suspendedUntil = until
            switch reason {
            case .disabled?: state.reason = .disabled
            case .apple?: state.reason = .apple
            default: state.reason = .serverError
            }
            return true
        }
    }

    /// A 401 (any reason) or an attestation failure: stop the paid route until the next launch.
    /// Nothing is persisted, so it can't outlive the process, and no break retries it meanwhile.
    public func recordUnauthorized() { recordStop(.unauthorized) }

    /// A 403 `no_entitlement`: no paid calls until `entitlementDidChange()` or the next launch.
    /// Never opens the paywall (#233 §5.10).
    public func recordNoEntitlement() { recordStop(.noEntitlement) }

    /// A 403 `install_limit` (from `/api/entitlement`): no paid calls until the next launch.
    public func recordInstallLimit() { recordStop(.installLimit) }

    /// 400 `mixed_auth`, 405, or a 4xx with a missing or unknown reason: a client bug, so stop
    /// until the next launch.
    public func recordClientError() { recordStop(.clientError) }

    /// `Transaction.updates` emitted, or a `/api/entitlement` re-sync returned 204: lift a
    /// `no_entitlement` stop so the next break may try the paid route once. Other stops stay.
    public func entitlementDidChange() {
        lock.withLock { if stop == .noEntitlement { stop = nil } }
    }

    private func recordStop(_ reason: StopReason) {
        lock.withLock {
            // Keep the first stop: an unauthorized or install-limit stop is never downgraded to
            // one that `entitlementDidChange()` could lift.
            if stop == nil || stop == .noEntitlement { stop = reason }
        }
    }

    /// A 200 whose audio failed validation (content type, size or duration). The call may already
    /// be billed, so pause 5 min, 10 min ... up to 1 h, persisted. Never shortens a longer suspension.
    public func recordInvalidAudio() {
        let at = now()
        update { state in
            state.consecutiveFailures += 1
            let wait = Self.invalidAudioWait(consecutiveFailures: state.consecutiveFailures)
            let until = at.addingTimeInterval(wait)
            if let current = state.suspendedUntil, current > until, current > at { return true }
            state.suspendedUntil = until
            state.reason = .invalidAudio
            return true
        }
    }

    /// An App Attest failure on the device (PR 5's attest client). Same as a 401.
    public func recordAttestFailure() { recordUnauthorized() }

    /// A 5xx or a transport error: back off 30 s, 60 s, 120 s ... up to 15 min.
    public func recordServerFailure() {
        let at = now()
        update { state in
            state.consecutiveFailures += 1
            let wait = Self.serverErrorWait(consecutiveFailures: state.consecutiveFailures)
            let until = at.addingTimeInterval(wait)
            // Never shorten a longer suspension (a 429 until midnight stays until midnight).
            if let current = state.suspendedUntil, current > until, current > at { return true }
            state.suspendedUntil = until
            state.reason = .serverError
            return true
        }
    }

    private func update(_ change: (inout State) -> Bool) {
        let saved: State? = lock.withLock {
            var next = state
            guard change(&next) else { return nil }
            state = next
            return next
        }
        if let saved { store?.save(saved) }
    }

    // MARK: Policy (pure, for tests)

    /// Seconds to wait after a 429, clamped to [60 s, 24 h]. See the type comment for the per-reason default.
    public static func rateLimitWait(retryAfter: String?, reason: ProxyErrorReason? = nil, now: Date) -> TimeInterval {
        let header = retryAfter.flatMap { retryAfterInterval($0, now: now) }
        let fallback: TimeInterval
        switch reason {
        case .rate?, .enroll?: fallback = shortRateLimitWait
        default: fallback = secondsUntilNextUTCMidnight(from: now)
        }
        return min(max(header ?? fallback, minimumRateLimitWait), maximumRateLimitWait)
    }

    /// Seconds to wait after a 503: `Retry-After` clamped to [30 s, 24 h]; without it 1 h for
    /// `disabled`, else the exponential 5xx wait.
    public static func serviceUnavailableWait(retryAfter: String?, reason: ProxyErrorReason?,
                                              consecutiveFailures: Int, now: Date) -> TimeInterval {
        if let header = retryAfter.flatMap({ retryAfterInterval($0, now: now) }) {
            return min(max(header, serverErrorBaseWait), maximumRateLimitWait)
        }
        if reason == .disabled { return disabledWait }
        if reason == .apple { return appleWait }
        return serverErrorWait(consecutiveFailures: consecutiveFailures)
    }

    /// `Retry-After` as delta seconds or an HTTP date (RFC 9110), relative to `now`. Nil if unparseable.
    public static func retryAfterInterval(_ header: String, now: Date) -> TimeInterval? {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.allSatisfy(\.isASCIIDigit) { return TimeInterval(value) }
        for format in httpDateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date.timeIntervalSince(now) }
        }
        return nil
    }

    private static let httpDateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",  // IMF-fixdate
        "EEEE, dd-MMM-yy HH:mm:ss zzz",   // obsolete RFC 850
        "EEE MMM d HH:mm:ss yyyy",        // obsolete asctime
    ]

    public static func secondsUntilNextUTCMidnight(from now: Date) -> TimeInterval {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let startOfDay = utc.startOfDay(for: now)
        let next = utc.date(byAdding: .day, value: 1, to: startOfDay)!
        return next.timeIntervalSince(now)
    }

    public static func invalidAudioWait(consecutiveFailures: Int) -> TimeInterval {
        let exponent = min(max(consecutiveFailures - 1, 0), 10)
        return min(invalidAudioBaseWait * pow(2, Double(exponent)), invalidAudioMaximumWait)
    }

    public static func serverErrorWait(consecutiveFailures: Int) -> TimeInterval {
        let exponent = min(max(consecutiveFailures - 1, 0), 10)
        return min(serverErrorBaseWait * pow(2, Double(exponent)), serverErrorMaximumWait)
    }

    /// Owner A/B diagnostics: reason and resume time only.
    public func statusLine() -> String {
        if let stop = stopReason {
            if stop == .noEntitlement { return "Premium backoff: noEntitlement until entitlement changes" }
            return "Premium backoff: \(stop.rawValue) until next launch"
        }
        let current = snapshot
        guard let until = suspendedUntil() else { return "Premium backoff: none" }
        let iso = ISO8601DateFormatter().string(from: until)
        return "Premium backoff: \(current.reason?.rawValue ?? "unknown") until \(iso)"
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Where `PaidVoiceBackoff` keeps its state across launches.
public protocol PaidVoiceBackoffStore: Sendable {
    func load() -> PaidVoiceBackoff.State?
    func save(_ state: PaidVoiceBackoff.State)
}

/// `UserDefaults` persistence (JSON under one key).
public struct UserDefaultsPaidVoiceBackoffStore: PaidVoiceBackoffStore, @unchecked Sendable {
    public static let defaultKey = "voice.paidBackoff.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PaidVoiceBackoff.State? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PaidVoiceBackoff.State.self, from: $0) }
    }

    public func save(_ state: PaidVoiceBackoff.State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
