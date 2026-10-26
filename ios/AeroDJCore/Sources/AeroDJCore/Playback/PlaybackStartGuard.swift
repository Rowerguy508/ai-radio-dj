import Foundation

/// What to do with playback after `play()` returns.
public enum PlayReturn: Equatable, Sendable {
    case keepPlaying
    case pauseBecauseHeld
}

/// Re-read after `play()` returns. An interruption or a user pause can land during the await.
public enum PlaybackStartGuard {
    public static func afterPlay(mayAutoResume: Bool, userWantsPlayback: Bool) -> PlayReturn {
        if mayAutoResume { return .keepPlaying }
        _ = userWantsPlayback
        return .pauseBecauseHeld
    }
}
