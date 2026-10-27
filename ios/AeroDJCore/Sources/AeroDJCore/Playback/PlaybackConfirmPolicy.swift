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
    /// MusicKit reports `.playing`: confirm the start.
    case confirm
    /// Not playing yet. Keep waiting; a slow start is not a failure.
    case keepWaiting
    /// The transport already left `.preparing` (pause, refusal, error). Stop polling.
    case stopWaiting
    /// The deadline passed without `.playing`. Report the failure.
    case fail
}

/// Build 9 P0 (-Atlas): the confirm used to fail on the first `.paused` / `.stopped` poll, 0.5 s
/// after it was armed. After `play()` returns, MusicKit can still report `.paused` while the
/// catalog item loads, so that early failure paused a start that was only slow. A non-playing
/// status now waits until the deadline; only the deadline reports a failure. `.interrupted`
/// is a real system hold and still fails at once.
public enum PlaybackConfirmPolicy {
    /// 16 polls x 0.5 s = the 8 s deadline from #109.
    public static let maxPolls = 16

    /// `poll` is 1-based: the first check after the first sleep is poll 1.
    public static func step(status: ConfirmStatus, transportIsPreparing: Bool, poll: Int,
                            maxPolls: Int = PlaybackConfirmPolicy.maxPolls) -> ConfirmStep {
        if status == .playing { return .confirm }
        guard transportIsPreparing else { return .stopWaiting }
        if status == .interrupted { return .fail }
        return poll >= maxPolls ? .fail : .keepWaiting
    }
}
