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
