import Foundation

/// What to do with playback after `play()` returns.
public enum PlayReturn: Equatable, Sendable {
    case keepPlaying
    case pauseBecauseHeld
}

/// Re-read after `play()` returns. An interruption or a user pause can land during the await.
/// This check does not look at that state yet: play is treated as still wanted.
public enum PlaybackStartGuard {
    public static func afterPlay(mayAutoResume: Bool, userWantsPlayback: Bool) -> PlayReturn {
        _ = (mayAutoResume, userWantsPlayback)
        return .keepPlaying
    }
}
