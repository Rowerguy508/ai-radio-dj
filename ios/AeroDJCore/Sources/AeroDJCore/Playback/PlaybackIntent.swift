import Foundation

/// What the user wants, kept separate from what the system did to playback.
///
/// A DJ break, a phone call and a route change all pause music, but only the user
/// may ask for music to start. After a break or an interruption, music resumes only
/// when the user still wants playback and the system did not hold it paused.
public struct PlaybackIntent: Equatable, Sendable {
    /// The user last pressed play (or started a station) and has not pressed pause.
    public private(set) var userWantsPlayback = false
    /// The system paused playback (call, route removal) and has not given it back.
    public private(set) var pausedBySystem = false

    public init() {}

    /// An explicit user play overrides a system hold, such as a removed route.
    public mutating func userPlay() {
        userWantsPlayback = true
        pausedBySystem = false
    }

    public mutating func userPause() {
        userWantsPlayback = false
    }

    public mutating func systemInterruptionBegan() {
        pausedBySystem = true
    }

    /// `shouldResume` is the system's own permission; without it, playback stays paused.
    public mutating func systemInterruptionEnded(shouldResume: Bool) {
        pausedBySystem = !shouldResume
    }

    public mutating func routeRemoved() {
        pausedBySystem = true
    }

    /// Whether music may start again on its own, after a DJ break or an interruption.
    public var mayAutoResume: Bool {
        userWantsPlayback && !pausedBySystem
    }
}
