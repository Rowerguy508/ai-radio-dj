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
    public static func banner(code: PlaybackErrorCode, attempt: Int, attemptIsCurrent: Bool) -> String? {
        guard attemptIsCurrent else { return nil }
        return "Could not start the next song: \(code). attempt=\(attempt)"
    }
}
