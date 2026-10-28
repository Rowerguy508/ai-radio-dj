import Foundation

/// How a DJ break ended, from the interlude adapter's side.
public enum BreakEndTrigger: Equatable, Sendable, CaseIterable {
    /// The last clip finished on its own; the player already stopped.
    case naturalFinish
    /// The break's timeout fired while a clip may still be playing.
    case timeout
    /// `audioPlayerDecodeErrorDidOccur`; the player may still be running.
    case decodeError
    /// `haltAudio` (skip, pause, interruption) and the revoke stop.
    case halt
    case revoke
}

public enum BreakEndStep: Equatable, Sendable {
    case stopClip
    case finishBreak
    /// `completeNarration` -> `setActive(false, .notifyOthersOnDeactivation)`.
    case releaseSession
}

/// Build 10 P0 (#125, Echo's review, -Atlas). With a mixable session, a clip still playing
/// when the break ends would talk over the next song, and releasing the session under it
/// throws. Every end except a natural finish stops the clip before the break finishes, and
/// the session is released last.
public enum BreakEndSequence {
    public static func steps(for trigger: BreakEndTrigger) -> [BreakEndStep] {
        switch trigger {
        case .naturalFinish:
            [.finishBreak, .releaseSession]
        case .timeout, .decodeError, .halt, .revoke:
            [.stopClip, .finishBreak, .releaseSession]
        }
    }

    /// The steps the adapter runs itself (`releaseSession` runs in `completeNarration`).
    public static func appSteps(for trigger: BreakEndTrigger) -> [BreakEndStep] {
        steps(for: trigger)
    }

    /// True when a clip can still be producing audio at the moment the break ends.
    public static func clipMayStillPlay(_ trigger: BreakEndTrigger) -> Bool {
        trigger != .naturalFinish
    }
}
