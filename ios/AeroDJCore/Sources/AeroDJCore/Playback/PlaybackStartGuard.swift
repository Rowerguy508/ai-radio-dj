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

/// How one attempt's `prepareToPlay()` / `play()` pass ended.
public enum AttemptPlayOutcome: Equatable, Sendable {
    /// The attempt still owns the player and the hold gate let it keep playing.
    case playing
    /// The attempt still owns the player; a hold or user pause landed during `play()`, so it paused.
    case pausedBecauseHeld
    /// A newer attempt began (or the user cancelled this one) during an await. This attempt did not
    /// call `play()` after that point and changed no playback state of a newer attempt.
    case superseded
}

/// #143 (-Atlas): `MusicKitService.playIfStillAllowed` for ONE attempt. `ApplicationMusicPlayer`
/// is shared, and the main actor is reentrant across awaits, so attempt A suspended in
/// `prepareToPlay()` can resume after attempt B replaced the queue. The attempt that entered is
/// carried through (never re-read from `current` after an await), and ownership is checked after
/// `prepare` (before `play`) and after `play` (before any pause or state change). A stale attempt
/// returns `.superseded` and never touches B's transport. A start the user cancelled (no current
/// attempt) is not played after `prepare`, and is paused by the hold gate if `play()` was in flight.
public enum AttemptPlaySequence {
    @MainActor
    public static func run(
        attempt: PlaybackAttemptID,
        current: @MainActor () -> PlaybackAttemptID?,
        prepare: @MainActor () async throws -> Void,
        willPlay: @MainActor () -> Void,
        play: @MainActor () async throws -> Void,
        didPlay: @MainActor () -> Void,
        gates: @MainActor () -> (mayAutoResume: Bool, userWantsPlayback: Bool),
        pause: @MainActor () -> Void
    ) async throws -> AttemptPlayOutcome {
        try await prepare()
        guard current() == attempt else { return .superseded }
        willPlay()
        try await play()
        let owner = current()
        guard owner == attempt else {
            // A newer attempt owns the player: touch nothing. With no current attempt (the user
            // stopped this start during `play()`), nobody else owns it, so the hold gate still
            // pauses audio the user turned down.
            if owner == nil, isHeld(gates()) { pause() }
            return .superseded
        }
        didPlay()
        guard !isHeld(gates()) else {
            pause()
            return .pausedBecauseHeld
        }
        return .playing
    }

    private static func isHeld(_ gates: (mayAutoResume: Bool, userWantsPlayback: Bool)) -> Bool {
        PlaybackStartGuard.afterPlay(mayAutoResume: gates.mayAutoResume,
                                     userWantsPlayback: gates.userWantsPlayback) != .keepPlaying
    }
}
