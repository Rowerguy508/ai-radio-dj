import Foundation

/// Monotonic test clock. Production playback does not sleep on this type; tests advance it.
public struct ManualClock: Equatable, Sendable {
    public private(set) var now: Duration

    public init(now: Duration = .zero) {
        self.now = now
    }

    public mutating func advance(by amount: Duration) {
        now += amount
    }
}

/// Position and catalog duration for the song that is loaded.
///
/// The preparation deadline is `DJBreakPreparer.deadline(remainingInSong:)`. When the
/// song has no duration, or the remaining time is inside the margin, there is no deadline
/// and the break is not started.
public struct PlaybackProgress: Equatable, Sendable {
    public private(set) var position: Duration = .zero
    public private(set) var duration: Duration?

    public init() {}

    public mutating func songStarted(duration: Duration?) {
        position = .zero
        self.duration = duration
    }

    public mutating func seek(to position: Duration) {
        let floored = max(position, .zero)
        if let duration {
            self.position = min(floored, duration)
        } else {
            self.position = floored
        }
    }

    public var remaining: Duration? {
        guard let duration else { return nil }
        let left = duration - position
        return left > .zero ? left : .zero
    }

    /// Nil when it is too late to render, or the song's duration was never reported.
    public var preparationDeadline: Duration? {
        guard let remaining else { return nil }
        return DJBreakPreparer.deadline(remainingInSong: remaining)
    }
}
