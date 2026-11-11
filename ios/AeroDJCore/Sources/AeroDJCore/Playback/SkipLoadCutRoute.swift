import Foundation

/// #444 (-Atlas): what the poll does with a cut of a skip's load (`SkipLoadCut`).
///
/// The app's MusicKit queue holds one song, so a lock-screen, Control Center, headphone or CarPlay
/// Next reaches the app only as that song being cleared or rewound. #446 read every such cut in
/// the first 2 s of a skipped-to song as MusicKit cutting our own load, and reloaded the same song.
/// On build 43 that turned the owner's second Next into a reload, then a pause.
///
/// The rule now:
/// - A hold (user Pause, an interruption or call, or route loss) is active: the cut is ignored.
///   It never calls `userPlay()` and never starts playback over the hold.
/// - Our own attempt has called `play()` and it has not returned: the ambiguous cut #446 targeted.
///   Reload the same song through `SkipCoordinator.noteLoadCut`. One Next never skips two songs.
/// - Otherwise (our `play()` returned, or has not been called): MusicKit's own Next. It goes through
///   `SkipCoordinator.noteCutAsNext` and the skip path (`oneSkip(.advance)`), folding into the
///   chain's one stored follow-up when a chain is running.
public enum SkipLoadCutRoute: String, Equatable, Sendable {
    case ignoreHeld
    case reloadSameSong
    case advance

    public static func decide(awaitingOwnPlay: Bool, userWantsPlayback: Bool,
                              pausedBySystem: Bool) -> SkipLoadCutRoute {
        guard userWantsPlayback, !pausedBySystem else { return .ignoreHeld }
        return awaitingOwnPlay ? .reloadSameSong : .advance
    }

    /// `noteLoadCut` said `.exhausted` (no chain, this song's recovery is spent). A song that was
    /// seen playing is playable: the cut is a Next, not a failure to surface. Only a song never
    /// seen playing surfaces the error and pauses.
    public static func exhaustedIsAdvance(_ cut: SkipLoadCut) -> Bool {
        cut.targetSeenPlaying
    }
}

/// #444 (-Atlas): Play after a skip stopped short. A song the user explicitly skipped past (their
/// Next was observed for it, and no advance has left it since) is not reloaded: Play takes that
/// Next instead. Anything else keeps the `LoadedTargetPolicy` decision.
public enum SkippedPastResume: Equatable, Sendable {
    case asDecided(ResumeTargetDecision)
    case advancePastSkipped

    public static func decide(_ decision: ResumeTargetDecision, selectedIndex: Int, skippedPast: Int?,
                              queueCount: Int) -> SkippedPastResume {
        guard decision == .reloadSelected, skippedPast == selectedIndex,
              selectedIndex + 1 < queueCount else { return .asDecided(decision) }
        return .advancePastSkipped
    }
}

extension SkipLoadResult {
    /// Log token. No song identity beyond the target index.
    public var logToken: String {
        switch self {
        case .playing: "playing"
        case .queueStopped: "queueStopped"
        case .loadCut: "loadCut"
        case .cancelled: "cancelled"
        case .failed(.songUnavailable, _): "failedUnavailable"
        case .failed(.couldNotStart, _): "failedCouldNotStart"
        }
    }
}

extension SkipJob {
    public var logToken: String {
        switch self {
        case .advance: "advance"
        case .reload: "reload"
        }
    }
}

/// #444 (-Atlas): why `surfaceSkipFailure` paused.
public enum SkipSurfaceReason: String, Equatable, Sendable {
    /// The same-target retry also failed.
    case reloadFailed
    /// A cut of a song never seen playing, after its recovery was spent.
    case exhausted
    /// The queue entry has no playable song.
    case unavailable

    public init(_ failure: SkipTerminalFailure) {
        switch failure {
        case .songUnavailable: self = .unavailable
        case .couldNotStart: self = .reloadFailed
        }
    }
}

/// #444 diagnostics. Indexes, counts, bools and fixed tokens only: no titles, catalog ids or
/// station names.
extension PlaybackLog {
    public static func remoteNextCommand(index: Int) -> String {
        "remoteNextCommand fired index=\(index)"
    }

    /// `disposition` is `folded|recover|exhausted|advance|ignoredHeld`.
    public static func skipLoadCut(index: Int, generation: Int, shape: SkipLoadCutShape, chainInFlight: Bool,
                                   awaitingPlay: Bool, recoveries: Int, disposition: String) -> String {
        "skipLoadCut index=\(index) generation=\(generation) shape=\(shape.rawValue) chainInFlight=\(chainInFlight) awaitingPlay=\(awaitingPlay) recoveries=\(recoveries) disposition=\(disposition)"
    }

    public static func skipStep(job: SkipJob, target: Int, result: SkipLoadResult) -> String {
        "skipStep job=\(job.logToken) target=\(target) result=\(result.logToken)"
    }

    public static func skipSurface(reason: SkipSurfaceReason, index: Int) -> String {
        "skipSurface reason=\(reason.rawValue) index=\(index)"
    }

    /// `decision` is `playLoaded|reloadSelected|failClosed|advancePastSkipped`.
    public static func resumeDecision(_ decision: String, index: Int) -> String {
        "resume decision=\(decision) index=\(index)"
    }
}

extension ResumeTargetDecision {
    public var logToken: String {
        switch self {
        case .playLoaded: "playLoaded"
        case .reloadSelected: "reloadSelected"
        case .failClosed: "failClosed"
        }
    }
}
