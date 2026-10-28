import Foundation

/// What the user wants, kept separate from what the system did to playback.
///
/// A DJ break, a phone call and a route change all pause music, but only the user
/// may ask for music to start. After a break or an interruption, music resumes only
/// when the user still wants playback and the system did not hold it paused.
public struct PlaybackIntent: Equatable, Sendable {
    /// The user last pressed play (or started a station) and has not pressed pause.
    public private(set) var userWantsPlayback = false
    /// A phone call or other system interruption is holding playback. Cleared only when that
    /// interruption ends with permission to resume, never by a route change.
    private var interruptionHeld = false
    /// The output route was removed (headphones unplugged). Cleared only by an explicit user play.
    private var routeHeld = false

    /// The system paused playback (call, route removal) and has not given it back.
    public var pausedBySystem: Bool {
        interruptionHeld || routeHeld
    }

    public init() {}

    /// An explicit user play overrides every system hold, including a removed route.
    public mutating func userPlay() {
        userWantsPlayback = true
        interruptionHeld = false
        routeHeld = false
    }

    public mutating func userPause() {
        userWantsPlayback = false
    }

    public mutating func systemInterruptionBegan() {
        interruptionHeld = true
    }

    /// `shouldResume` is the system's own permission; without it, playback stays paused.
    /// It releases only the interruption hold, so a route removed during the call still holds.
    public mutating func systemInterruptionEnded(shouldResume: Bool) {
        interruptionHeld = !shouldResume
    }

    /// Build 18 P0 (-Fry): the interruption hold is released because the song it began at has
    /// ended naturally and `SongEndHold` allowed it. A route hold is never released here.
    public mutating func releaseInterruptionHoldAtSongEnd() {
        interruptionHeld = false
    }

    /// Headphones or the output route went away. Holds until the user presses play.
    public mutating func routeRemoved() {
        routeHeld = true
    }

    /// Whether music may start again on its own, after a DJ break or an interruption.
    public var mayAutoResume: Bool {
        userWantsPlayback && !pausedBySystem
    }
}
