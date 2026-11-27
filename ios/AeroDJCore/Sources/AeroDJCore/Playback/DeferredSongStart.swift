import Foundation

/// A song loaded while playback is not allowed to start (user pause, call, headphones).
///
/// `take()` reports that index once, when a later play actually starts it. A second
/// successful play does not report the song again.
public struct DeferredSongStart: Equatable, Sendable {
    public private(set) var index: Int?

    public init() {}

    public mutating func arm(_ index: Int) {
        self.index = index
    }

    public mutating func clear() {
        index = nil
    }

    public mutating func take() -> Int? {
        defer { index = nil }
        return index
    }
}


/// What to do when `startTrack` would play but `mayAutoResume` is false.
public enum HeldStartAction: Equatable, Sendable {
    /// Natural boundary / auto start: arm deferred start, no error.
    case deferSilently
    /// User-initiated start (search play, user resume/skip): arm deferred start and report.
    case deferAndReport
}

public enum HeldStartPolicy {
    public static func action(userInitiated: Bool) -> HeldStartAction {
        userInitiated ? .deferAndReport : .deferSilently
    }
}

/// Build 18 P0 (Atlas): song 2's start was allowed and `play()` (or `prepareToPlay()`) threw.
/// `startNextTrack` must show this banner for the current attempt, never stop silently.
/// A superseded attempt shows nothing (the caller checks `MusicKitError.superseded` first).
public enum NextSongStartFailure {
    /// #302 (-Atlas): advance at most once (to `k + 2`) when `k + 1` fails to start.
    public static let maxRetries = 1

    public enum Recovery: Equatable, Sendable {
        /// A newer tap, skip, or stop replaced this start: do nothing, show nothing.
        case ignore
        /// First failure and `k + 2` exists: advance once without a new intro.
        case retry(nextIndex: Int)
        /// Retry exhausted or no `k + 2` in the queue: stop and show the failure banner.
        case stop(banner: String)
    }

    /// #302 (-Atlas): decides whether `startNextTrack` retries `failedIndex + 1` once or stops
    /// with the failure banner. A superseded attempt always returns `.ignore`.
    public static func decide(
        code: PlaybackErrorCode,
        attempt: Int,
        attemptIsCurrent: Bool,
        failedIndex: Int,
        queueCount: Int,
        retriesUsed: Int
    ) -> Recovery {
        guard attemptIsCurrent else { return .ignore }
        let retryIndex = failedIndex + 1
        if retriesUsed < maxRetries, retryIndex >= 0, retryIndex < queueCount {
            return .retry(nextIndex: retryIndex)
        }
        return .stop(banner: bannerMessage(code: code, attempt: attempt))
    }

    public static func banner(code: PlaybackErrorCode, attempt: Int, attemptIsCurrent: Bool) -> String? {
        guard attemptIsCurrent else { return nil }
        return bannerMessage(code: code, attempt: attempt)
    }

    private static func bannerMessage(code: PlaybackErrorCode, attempt: Int) -> String {
        "Could not start the next song: \(code). attempt=\(attempt)"
    }
}
