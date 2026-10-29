import Foundation

/// Which signal produced `boundary queueEnd`.
public enum QueueEndSignal: String, Equatable, Sendable {
    case entryCleared
    case position
}

/// Fixed playback log lines. Indices, durations, bools, and tokens only.
/// No titles, cue text, catalog ids, or secrets.
public enum PlaybackLog {
    public static func breakStart(after track: Int) -> String {
        "break start after=\(track)"
    }

    public static func breakEnd(after track: Int, result: BreakPlayerOutcome) -> String {
        "break end after=\(track) result=\(result.logToken)"
    }

    public static func breakSkipped(after track: Int, reason: DJBreakSkipReason) -> String {
        "break skipped after=\(track) reason=\(reason.rawValue)"
    }

    /// The reason a boundary with no prepared break is logged under: the session's own
    /// `lastNoBreak` reason, or `.notPlanned` when the session recorded none.
    public static func noBreakReason(
        _ lastNoBreak: (reason: DJBreakSkipReason, cadencePlanned: Bool)?
    ) -> DJBreakSkipReason {
        lastNoBreak?.reason ?? .notPlanned
    }

    /// The reason a handed-out break that never started is logged under. An empty line or
    /// no clips, and clips that did not decode, mean the prepared audio was unusable.
    public static func handedOutReason(_ skip: HandedOutBreakSkip) -> DJBreakSkipReason {
        switch skip {
        case .emptyLine, .decodeFailed: .renderFailed
        case .notPlayable: .notPlanned
        }
    }

    public static func queueEnd(finished: Int, signal: QueueEndSignal) -> String {
        "boundary queueEnd finished=\(finished) signal=\(signal.rawValue)"
    }

    public static func stationFinished(finished: Int) -> String {
        "boundary stationFinished finished=\(finished)"
    }

    public static func userPause(index: Int, nearEnd: Bool) -> String {
        "user pause index=\(index) nearEnd=\(nearEnd)"
    }

    public static func interruptionBegan() -> String {
        "session interruption began"
    }

    /// Build 18 P0: the interruption's reason key, as an enum token only.
    public static func interruptionBegan(reason: AudioInterruptionReason) -> String {
        "session interruption began reason=\(reason.rawValue)"
    }

    /// Build 18 P0: a song-end interruption hold was released at a natural end.
    public static func songEndHoldReleased(index: Int) -> String {
        "song end hold released finished=\(index)"
    }

    public static func interruptionEnded(shouldResume: Bool, breakActive: Bool) -> String {
        "session interruption ended shouldResume=\(shouldResume) breakActive=\(breakActive)"
    }

    public static func routeRemoved() -> String {
        "session route removed"
    }

    public static func interludeStop(reason: InterludeStopReason) -> String {
        "interlude stop reason=\(reason.logToken)"
    }

    public static func songDeferred(index: Int) -> String {
        "song deferred index=\(index)"
    }
}

extension BreakPlayerOutcome {
    public var logToken: String {
        switch self {
        case .finished: "finished"
        case .cancelled, .revoked: "cancelled"
        case .failed: "failed"
        }
    }
}

/// Where the app could call `setActive(true)`.
public enum AudioActivationPoint: Equatable, Sendable {
    case authorization
    case playback
}

/// Build 10 P0 (-Atlas): the app never activates its own `AVAudioSession`.
/// Music plays through `ApplicationMusicPlayer`, and MusicKit activates the session it plays
/// through. On the Duo, our `setActive(true)` (category `.playback`, options `[]`, not mixable)
/// was interrupted 1 ms later (`shouldResume=false`), the interruption set a system hold, and the
/// hold refused the tapped start. The app still sets the category (that activates nothing).
public enum AudioSessionActivation {
    public static func shouldActivate(during point: AudioActivationPoint) -> Bool {
        switch point {
        case .authorization, .playback: false
        }
    }
}

/// Build 10 P0 (-Atlas, Fry's review): `ApplicationMusicPlayer` plays outside the app's session,
/// so any activation of a non-mixable app session interrupts it. The DJ clip's `AVAudioPlayer.play()`
/// activates the app session implicitly, so the category mixes with others and the session is
/// released (notifying others) when each break ends, before the next song starts.
public enum AppAudioSessionConfig {
    /// `AVAudioSession.CategoryOptions.mixWithOthers` on the `.playback` category.
    public static let mixesWithOthers = true
}
