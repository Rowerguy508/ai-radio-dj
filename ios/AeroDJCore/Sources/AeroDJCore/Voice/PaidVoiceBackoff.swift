import Foundation

/// Client-side backoff for the paid voice proxy (aerodj-tts).
///
/// Without it, once the proxy answers 429 for its daily character cap the app keeps calling it
/// on every break until the cap resets. With it, `ProxyVoiceProvider` checks `suspendedUntil()`
/// before building a request: while suspended it throws `VoiceRenderError.suspended` with no
/// token read and no network call, and `VoiceRenderer` moves on to the next route (the existing
/// on-device fallback) exactly as it does for any other provider error.
///
/// Policy (the app half of the #233 §4.4 error contract):
/// - **429**: the `reason` in the JSON error body picks the wait.
///   - `install_daily` / `global_daily` / `daily_allowance`: until `Retry-After`, or the next UTC
///     midnight without one. Labelled `dailyCap`.
///   - `rate` / `enroll`: `Retry-After`, or 60 s without one.
///   - missing or unknown reason: `Retry-After`, or the next UTC midnight (treated as the daily cap).
///   Every 429 wait is clamped to [60 s, 24 h]. A 429 is persisted.
/// - **503**: `Retry-After` when present, clamped to [30 s, 24 h]. Without it, `disabled` (the kill
///   switch) waits 1 h and `store` or anything else uses the 5xx exponential backoff. Persisted.
/// - **Other 5xx or a transport error**: short exponential backoff, 30 s doubling per consecutive
///   failure up to 15 min. A 5xx or 503 never shortens a longer suspension.
/// - **401 or an attestation failure**: the paid route stops for the rest of this launch. Not
///   persisted and not retried on later breaks; the next launch tries again once.
/// - **200 with valid audio**: clears the failure count and any timed suspension.
/// - Anything else (other 4xx, bad audio after a 200, cancellation, our own timeout) leaves the
///   state as it is.
///
public final class PaidVoiceBackoff: @unchecked Sendable {
    public enum Reason: String, Codable, Equatable, Sendable {
        case rateLimited, serverError
        /// 429 `install_daily` / `global_daily` / `daily_allowance`.
        case dailyCap
        /// 503 `disabled` (the proxy's kill switch).
        case disabled
    }

    /// The `reason` enum the proxy puts in its error body (`{ error, requestId, reason }`, #233 §4.4).
    public enum ProxyErrorReason: String, Equatable, Sendable {
        case rate, enroll, store, disabled, reattest, assertion
        case installDaily = "install_daily"
        case globalDaily = "global_daily"
        /// 429: this Pro purchase's daily render allowance is used up (proxy `handler.ts`, until 00:00 UTC).
        case dailyAllowance = "daily_allowance"

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

    private let lock = NSLock()
    private let store: (any PaidVoiceBackoffStore)?
    private let now: @Sendable () -> Date
    private var state: State
    /// Set by a 401 or an attestation failure. In memory only: lasts until the next launch.
    private var stoppedThisLaunch = false

    public init(store: (any PaidVoiceBackoffStore)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        state = store?.load() ?? State()
    }

    /// The time the paid route resumes, or nil when it is not suspended now.
    public func suspendedUntil() -> Date? {
        lock.withLock {
            if stoppedThisLaunch { return .distantFuture }
            guard let until = state.suspendedUntil, until > now() else { return nil }
            return until
        }
    }

    /// True after a 401 or an attestation failure, until the next launch.
    public var isStoppedForThisLaunch: Bool { lock.withLock { stoppedThisLaunch } }

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
        let kind: Reason = (reason == .installDaily || reason == .globalDaily || reason == .dailyAllowance)
            ? .dailyCap : .rateLimited
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
            state.reason = reason == .disabled ? .disabled : .serverError
            return true
        }
    }

    /// A 401 (any reason) or an attestation failure: stop the paid route until the next launch.
    /// Nothing is persisted, so it can't outlive the process, and no break retries it meanwhile.
    public func recordUnauthorized() {
        lock.withLock { stoppedThisLaunch = true }
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

    public static func serverErrorWait(consecutiveFailures: Int) -> TimeInterval {
        let exponent = min(max(consecutiveFailures - 1, 0), 10)
        return min(serverErrorBaseWait * pow(2, Double(exponent)), serverErrorMaximumWait)
    }

    /// Owner A/B diagnostics: reason and resume time only.
    public func statusLine() -> String {
        if isStoppedForThisLaunch { return "Premium backoff: unauthorized until next launch" }
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
