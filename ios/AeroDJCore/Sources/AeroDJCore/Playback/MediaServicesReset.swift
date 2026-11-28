/// #195 (-Fry): what the app does on `AVAudioSession.mediaServicesWereResetNotification`.
///
/// Apple's guidance: after a media services reset every audio object the app holds is invalid.
/// Dispose of and rebuild players and engines, then re-apply the session category. This plan is
/// the order; `MediaServicesResetObserver` in the app runs it on the main actor.
///
/// The app never calls `setActive(true)` for music (MusicKit activates on `play()`), so
/// re-activation is the existing `resumeIfAllowed`, gated by `mayAutoResume`. A break that was
/// speaking or pending is dropped, never replayed: its stop path already owns the one resume.

/// The break's state when the reset arrives.
public enum MediaServicesResetBreak: String, Equatable, Sendable {
    case none
    /// A clip player exists and is speaking.
    case speaking
    /// A break is handed out or pending, before any clip player exists.
    case pending
}

public enum MediaServicesResetStep: Equatable, Sendable {
    /// Stop the break now, without a fade: its player is dead. Cancels a pending break too.
    case stopBreak
    /// Drop every voice player the app holds, so the next break builds fresh ones.
    case rebuildVoicePlayers
    /// The app's own activation record is stale after a reset.
    case releaseAppActivation
    /// Re-apply the app's normal category (on an inactive session this activates nothing).
    case reapplyCategory
    /// Music again, only if the listener still wants playback.
    case resumeMusicIfAllowed
}

public struct MediaServicesResetPlan: Equatable, Sendable {
    public let steps: [MediaServicesResetStep]

    public var dropsBreak: Bool { steps.contains(.stopBreak) }

    public static func plan(break state: MediaServicesResetBreak, mayAutoResume: Bool) -> MediaServicesResetPlan {
        var steps: [MediaServicesResetStep] = []
        if state != .none { steps.append(.stopBreak) }
        steps += [.rebuildVoicePlayers, .releaseAppActivation, .reapplyCategory]
        if state == .none, mayAutoResume { steps.append(.resumeMusicIfAllowed) }
        return MediaServicesResetPlan(steps: steps)
    }
}

extension PlaybackLog {
    /// One log-safe line per reset. No track, no user data.
    public static func mediaServicesReset(break state: MediaServicesResetBreak, resume: Bool) -> String {
        "session media services reset break=\(state.rawValue) resume=\(resume)"
    }
}
