import Foundation

/// Song scrubbing (-Atlas; owner: "We also need scrubbing for songs."; API by Nova and Orion).
///
/// The scrubber's drag state lives in the view. On release the view calls
/// `PlaybackActions.seek(to:trackID:)` once. The transport owner (`MusicKitService`) asks this policy
/// whether to seek and where, then re-baselines the boundary detector
/// (`BoundaryInterpreter.userSeeked`), sets `ApplicationMusicPlayer.playbackTime`, and tells
/// the DJ session the new remaining time (`DJBreakSession.songSeeked`).
///
/// A seek during a DJ break is **blocked**, not deferred: the scrubber shows the song's
/// position, and the song is not on air while the DJ speaks or a break is being handed out.
/// Applying a stale drag target after the break would jump the next song (or the same song,
/// replayed from a position the user no longer sees). Blocking returns `false` immediately,
/// so the view snaps back to the live position and nothing is queued behind the break.
public enum SongSeekBlock: String, Equatable, Sendable {
    /// No song is on air as music: a DJ break is preparing or airing, a song is loading,
    /// starting or changing, or nothing is queued (`PlaybackSnapshot.canSeek` is false).
    case notSeekableNow
    /// The current song's duration is unknown or not above 0.
    case unknownDuration
    /// The requested time is not a finite number.
    case invalidTarget
    /// The seek named a track that is no longer the current one: a scrub released after the
    /// song changed (stale drag, or a lock-screen scrub that raced a track change).
    case staleTrack
}

public enum SongSeekDecision: Equatable, Sendable {
    /// Seek to `target` seconds; `remaining` is what is left of the song from there.
    case seek(target: TimeInterval, remaining: TimeInterval)
    case blocked(SongSeekBlock)

    public var didSeek: Bool {
        if case .seek = self { true } else { false }
    }
}

public enum SongSeekPolicy {
    /// A seek never lands closer than this to the end, so a seek is never itself the end.
    public static let endGuardSeconds: TimeInterval = 1

    /// The seek target for `seconds` in a song of `duration`: clamped to [0, duration - 1 s].
    /// Nil when either value cannot be used.
    public static func clamp(_ seconds: TimeInterval, duration: TimeInterval) -> TimeInterval? {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return nil }
        let upper = max(0, duration - endGuardSeconds)
        return min(max(seconds, 0), upper)
    }

    /// One committed seek. `duration` is the current song's catalog duration.
    /// `trackID` is the track the caller was showing when the seek was committed. When it is
    /// given and is not `snapshot.nowPlaying`, the seek is a no-op (`.staleTrack`), so a target
    /// meant for one song never moves another. Nil keeps the untargeted behavior.
    public static func decide(seconds: TimeInterval, duration: TimeInterval?,
                              snapshot: PlaybackSnapshot, trackID: String? = nil) -> SongSeekDecision {
        guard snapshot.canSeek else { return .blocked(.notSeekableNow) }
        if let trackID, trackID != snapshot.nowPlaying?.id { return .blocked(.staleTrack) }
        guard let duration, duration.isFinite, duration > 0 else { return .blocked(.unknownDuration) }
        guard let target = clamp(seconds, duration: duration) else { return .blocked(.invalidTarget) }
        return .seek(target: target, remaining: duration - target)
    }
}
