import Foundation

/// When the display-only progress bar redraws (owner-reported frozen bar, build 16).
///
/// The bar's schedule is fixed when its timeline is built, so it must be built from plain
/// values the view receives (`transport`, current track id), not from closures. A new
/// `Key` means a new timeline: it rebuilds on Play and on every track change, so elapsed
/// starts ticking and the duration label follows the song that is playing.
public enum PlaybackProgressClock {
    /// What the timeline is keyed on. Changing either value rebuilds the schedule.
    public struct Key: Hashable, Sendable {
        public let transport: TransportState
        public let trackID: String?

        public init(transport: TransportState, trackID: String?) {
            self.transport = transport
            self.trackID = trackID
        }
    }

    /// Redraw period while playing. Reduce Motion keeps this: it removes the bar's
    /// animation, it does not stop the clock text from updating.
    public static let playingInterval: TimeInterval = 1
    /// Nothing moves while not playing. The next `Key` change rebuilds the timeline.
    public static let idleInterval: TimeInterval = 3600

    /// Compare to `.playing` only; `.preparing` must not move the bar. `reduceMotion` is
    /// accepted and deliberately ignored: at 2abafc3 it forced 3600 s while playing.
    public static func interval(for key: Key, reduceMotion: Bool) -> TimeInterval {
        _ = reduceMotion
        return key.transport == .playing ? playingInterval : idleInterval
    }

    /// The fill animation is the only motion. Reduce Motion turns it off.
    public static func animatesFill(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }
}

/// Models SwiftUI's behaviour for the bar's timeline: the schedule is computed once per
/// identity and kept until the identity changes. Used by tests to drive paused -> playing.
public struct PlaybackProgressTimeline: Equatable, Sendable {
    public private(set) var key: PlaybackProgressClock.Key
    public private(set) var interval: TimeInterval
    public let reduceMotion: Bool

    public init(key: PlaybackProgressClock.Key, reduceMotion: Bool = false) {
        self.key = key
        self.reduceMotion = reduceMotion
        self.interval = PlaybackProgressClock.interval(for: key, reduceMotion: reduceMotion)
    }

    /// A body rerun with new inputs. Same key keeps the built schedule.
    public mutating func render(_ newKey: PlaybackProgressClock.Key) {
        guard newKey != key else { return }
        self = PlaybackProgressTimeline(key: newKey, reduceMotion: reduceMotion)
    }

    /// True when a redraw is due `seconds` after the timeline was built.
    public func redrawsWithin(_ seconds: TimeInterval) -> Bool {
        interval <= seconds
    }
}
