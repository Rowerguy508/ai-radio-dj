import Foundation

/// MusicKit `playbackStatus`, reduced to what the start confirm needs. AVFoundation and
/// MusicKit types stay in the app target.
public enum ConfirmStatus: String, Equatable, Sendable {
    case playing
    case paused
    case stopped
    case interrupted
    case seeking
}

/// One poll of #109's start confirm.
public enum ConfirmStep: Equatable, Sendable {
    /// MusicKit reports `.playing`: confirm the start (also after a reported timeout).
    case confirmed
    /// Not playing yet. Keep waiting; a slow start is not a failure.
    case keepWaiting
    /// The 8 s deadline passed without `.playing`. Report it on screen, keep transport out of
    /// `.playing`, and do NOT pause the player: a stream still buffering on cellular may start
    /// late, and a late `.playing` confirms this same attempt (Fry's review).
    case reportTimeoutKeepPlayer
    /// MusicKit reported `.interrupted` while preparing. Report it at once; the player is not
    /// paused either, and a late `.playing` still confirms.
    case failInterrupted
    /// The transport already left `.preparing` (user pause, refusal, error). Stop watching.
    case stopWaiting
    /// A newer attempt started (another tap, resume or skip). This watchdog stops without
    /// touching the player or the snapshot: it must never fail or confirm the new attempt.
    case superseded
}

/// Build 9 P0 (-Atlas): the confirm used to fail on the first `.paused` / `.stopped` poll, 0.5 s
/// after it was armed, and then call `player.pause()`. After `play()` returns, MusicKit can still
/// report `.paused` while the catalog item loads, so that paused a start that was only slow. Now a
/// non-playing status waits until the deadline, the deadline only REPORTS, and nothing here ever
/// pauses the player. `.interrupted` is the only early report.
public enum PlaybackConfirmPolicy {
    /// 16 polls x 0.5 s = the 8 s deadline from #109.
    public static let maxPolls = 16
    /// Seconds between start-confirm polls (#109).
    public static let pollInterval: TimeInterval = 0.5
    /// `maxPolls` x `pollInterval`: the 8 s start-confirm deadline.
    public static var deadlineSeconds: TimeInterval { Double(maxPolls) * pollInterval }

    /// `poll` is 1-based: the first check after the first sleep is poll 1.
    public static func step(status: ConfirmStatus, transportIsPreparing: Bool, poll: Int,
                            maxPolls: Int = PlaybackConfirmPolicy.maxPolls) -> ConfirmStep {
        if status == .playing { return .confirmed }
        guard transportIsPreparing else { return .stopWaiting }
        if status == .interrupted { return .failInterrupted }
        return poll >= maxPolls ? .reportTimeoutKeepPlayer : .keepWaiting
    }

    /// Whether the app's position poll, seeing MusicKit `.playing`, confirms the current attempt
    /// (`confirmStart`). A `.preparing` start confirms (#109). #587 (-Fry): a start whose stall this
    /// attempt already reported also confirms once it plays past 0:00, whatever the transport. The
    /// skip path leaves transport `.playing`, so without this the banner outlived a playing song.
    public static func pollConfirms(position: TimeInterval?, transportIsPreparing: Bool,
                                    reportedThisAttempt: Bool) -> Bool {
        if transportIsPreparing { return true }
        guard reportedThisAttempt, let position else { return false }
        return position > 0
    }

    /// Whether a step lets the app touch the player. Always false: the confirm never pauses.
    public static func pausesPlayer(_ step: ConfirmStep) -> Bool {
        _ = step
        return false
    }
}
