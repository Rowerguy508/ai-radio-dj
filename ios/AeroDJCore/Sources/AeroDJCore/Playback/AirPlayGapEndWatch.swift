import Foundation

/// #526 PR A (-Echo): the tight AirPlay gap break's end watch.
///
/// On AirPlay (#525/#527) the DJ never talks over the song: the song ends, the music stays paused,
/// the break plays in the gap, then the next song loads. The gap path has no fixed sleep and no
/// fade (`InterludePlaybackAdapter.runBreak`, `MusicKitService.completeNarration`). Its one dead
/// air the app adds itself is before the break: the boundary poll runs once a second
/// (`regularPollSeconds`), so a song end was noticed 0 to 1 s after MusicKit reported it.
///
/// This watch narrows that wait on the AirPlay gap route only. In the song's last `leadSeconds`,
/// it reads the player every `watchPollSeconds` and asks for the existing boundary poll at once
/// when MusicKit already shows an unambiguous end: the one-song queue cleared, the entry changed,
/// or the playhead rewound to the start. The detector (`PlaybackBoundaryDetector`) still decides
/// every boundary from that same sample, with every hold, skip and route rule it has today.
///
/// What it never does:
/// - It never pauses, plays, seeks, or touches the audio session. It only asks for a poll.
/// - A stop near the end with the entry kept (it may be an AirPlay buffering stall) is left to the
///   1 s poll exactly as today, so a playing song is never paused early more often than before.
/// - An end too early for the song to have reached it (a lock-screen Next) is left to the 1 s poll,
///   so the remote-skip judgement sees the same timing as today.
/// - Off the AirPlay gap route (talk-over allowed: headphones, Bluetooth, CarPlay, built-in, or the
///   #525 kill switch off) it never arms. Those routes keep today's 1 s poll only.
public struct AirPlayGapEndWatch: Equatable, Sendable {
    /// Today's boundary poll (`MusicKitService.startObserving`). Unchanged.
    public static let regularPollSeconds: TimeInterval = 1.0
    /// The watch's read interval inside the arm window.
    public static let watchPollSeconds: TimeInterval = 0.1
    /// The watch arms when a regular playing sample is this close to the catalog end. Longer than
    /// one regular poll plus the detector's end window, so the last regular sample before an end
    /// always arms it.
    public static let leadSeconds: TimeInterval = 3.0
    /// The watch stops by itself this long after its last regular sample (no end, no new sample).
    public static let maxWatchSeconds: TimeInterval = leadSeconds + 2 * regularPollSeconds

    /// Worst-case wait from MusicKit's reported end to the boundary poll, on each path.
    public static let worstCaseDetectionBefore: TimeInterval = regularPollSeconds
    public static let worstCaseDetectionAfter: TimeInterval = watchPollSeconds

    /// The last regular sample that armed the watch.
    public struct Anchor: Equatable, Sendable {
        public let entryID: String
        public let position: TimeInterval
        public let duration: TimeInterval
        public let uptime: TimeInterval
    }

    public enum Step: Equatable, Sendable {
        /// Read again after `watchPollSeconds`.
        case keepWatching
        /// MusicKit shows an unambiguous end: run the existing boundary poll now.
        case pollNow
        /// Nothing to watch any more (disarmed or expired).
        case stop
    }

    public private(set) var anchor: Anchor?

    public init() {}

    public var isArmed: Bool { anchor != nil }

    /// Every regular poll's sample. `airPlayGapRoute` is `!DJLongFormRouteState.talkoverAllowed`
    /// (the #525 switch on and the last probe saw AirPlay). Returns true while the watch should run.
    @discardableResult
    public mutating func regularSample(_ sample: PlaybackObservation, airPlayGapRoute: Bool) -> Bool {
        guard airPlayGapRoute, sample.isPlaying, let entry = sample.entryID,
              let position = sample.position, let duration = sample.duration, duration > 0,
              let uptime = sample.uptime, position >= duration - Self.leadSeconds else {
            anchor = nil
            return false
        }
        anchor = Anchor(entryID: entry, position: position, duration: duration, uptime: uptime)
        return true
    }

    /// One watch read. Never changes the anchor; only a regular sample or `disarm` does.
    public func step(_ probe: PlaybackObservation) -> Step {
        guard let anchor, let now = probe.uptime, now >= anchor.uptime else { return .stop }
        if now - anchor.uptime > Self.maxWatchSeconds { return .stop }
        // The song could have played to its end window by now (same rule as the detector's
        // remote-skip check). An earlier end is not the song ending on its own: the 1 s poll judges it.
        let couldHaveReached = anchor.position + (now - anchor.uptime)
        guard couldHaveReached >= anchor.duration - PlaybackBoundaryDetector.endWindowSeconds else {
            return .keepWatching
        }
        guard let entry = probe.entryID else { return .pollNow }    // the one-song queue cleared
        if entry != anchor.entryID { return .pollNow }               // the entry changed
        guard !probe.isPlaying else { return .keepWatching }
        // Rewound to the start after playing to its end (MusicKit's finished one-song queue).
        if let position = probe.position,
           position < PlaybackBoundaryDetector.minimumProgress(duration: anchor.duration) {
            return .pollNow
        }
        // Stopped near the end with the entry kept: maybe a stall. Today's 1 s poll decides.
        return .keepWatching
    }

    public mutating func disarm() {
        anchor = nil
    }
}
