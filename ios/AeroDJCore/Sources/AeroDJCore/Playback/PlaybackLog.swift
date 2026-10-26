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
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }
}

/// `setActive(true)` belongs to playback, never to authorization.
public enum AudioActivationPoint: Equatable, Sendable {
    case authorization
    case playback
}

public enum AudioSessionActivation {
    public static func shouldActivate(during point: AudioActivationPoint) -> Bool {
        point == .playback
    }
}
