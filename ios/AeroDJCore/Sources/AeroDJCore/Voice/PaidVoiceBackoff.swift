import Foundation

/// Client-side backoff for the paid voice proxy (aerodj-tts).
///
/// Without it, once the proxy answers 429 for its daily character cap the app keeps calling it
/// on every break until the cap resets. With it, `ProxyVoiceProvider` checks `suspendedUntil()`
/// before building a request: while suspended it throws `VoiceRenderError.suspended` with no
/// token read and no network call, and `VoiceRenderer` moves on to the next route (the existing
/// on-device fallback) exactly as it does for any other provider error.
///
/// Policy:
/// - **429**: suspend until `Retry-After` (delta seconds or HTTP date). With no usable header the
///   429 is treated as the daily cap and suspends until the next UTC midnight. Either way the wait
///   is clamped to [60 s, 24 h].
/// - **5xx or a transport error**: short exponential backoff, 30 s doubling per consecutive failure
///   up to 15 min.
/// - **200**: clears the failure count and any suspension.
/// - Anything else (other 4xx, bad audio after a 200, cancellation, our own timeout) leaves the
///   state as it is.
///
/// The state is persisted through `PaidVoiceBackoffStore`, so a relaunch keeps the suspension.
/// The clock is injected for tests. Holds no text, voice, URL or token.
public final class PaidVoiceBackoff: @unchecked Sendable {
    public enum Reason: String, Codable, Equatable, Sendable {
        case rateLimited, serverError
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

    private let lock = NSLock()
    private let store: (any PaidVoiceBackoffStore)?
    private let now: @Sendable () -> Date
    private var state: State

    public init(store: (any PaidVoiceBackoffStore)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        state = store?.load() ?? State()
    }

    /// The time the paid route resumes, or nil when it is not suspended now.
    public func suspendedUntil() -> Date? {
        lock.withLock {
            guard let until = state.suspendedUntil, until > now() else { return nil }
            return until
        }
    }

    public var snapshot: State { lock.withLock { state } }

    /// A 200 from the proxy: clear the failure count and any suspension.
    public func recordSuccess() {
        update { state in
            guard state != State() else { return false }
            state = State()
            return true
        }
    }

    /// A 429. `retryAfter` is the raw `Retry-After` header value, if any.
    public func recordRateLimited(retryAfter: String?) {
        let at = now()
        let wait = Self.rateLimitWait(retryAfter: retryAfter, now: at)
        update { state in
            state.suspendedUntil = at.addingTimeInterval(wait)
            state.reason = .rateLimited
            return true
        }
    }

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

    /// Seconds to wait after a 429, clamped to [60 s, 24 h].
    public static func rateLimitWait(retryAfter: String?, now: Date) -> TimeInterval {
        let raw = retryAfter.flatMap { retryAfterInterval($0, now: now) } ?? secondsUntilNextUTCMidnight(from: now)
        return min(max(raw, minimumRateLimitWait), maximumRateLimitWait)
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
