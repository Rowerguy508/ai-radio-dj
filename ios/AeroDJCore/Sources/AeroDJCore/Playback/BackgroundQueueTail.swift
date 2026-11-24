import Foundation

/// #304 R1 (-Atlas): the one place that decides what the MusicKit player queue holds.
///
/// The player normally holds one song (`MusicKitService.startTrack`), and the next one loads from
/// the 1 Hz poll after the boundary (and its break). If iOS suspends the app while it is in the
/// background, that poll stops, so when the song ends nothing loads and the music stops.
///
/// Rules, all pure so they are tested on Linux:
/// - Foreground: one song, unchanged. The remote-skip and natural-end detectors see exactly the
///   queue shapes they see today.
/// - Background, and nothing is armed for the playing song's boundary (no DJ break, talk-over,
///   station intro or station change): the player also gets the next station song (the tail),
///   so MusicKit advances on its own if the app is suspended.
/// - Only when the next song is not the queue's last: the last-song boundary is where the station
///   refill runs (`StationQueueFeed.queueForNextSong`), so that boundary keeps today's path.
/// - Before a break plays, the tail is trimmed back to one song, so a DJ line never talks over
///   the next song. Back in the foreground the tail is trimmed too.
/// - When the player is found on the tail (the app woke, or the poll was alive at the end), the
///   app adopts it: index + 1, no break, not a skip, not a natural-end boundary. If the app was
///   awake at that end and a break was armed after all (or the app's next song changed), the tail
///   is handed back to the normal boundary instead (pause, break, then the next song loads as today).
public struct BackgroundQueueTail: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case foreground
        case background
    }

    /// The tail the app put behind the playing song.
    public struct Pending: Equatable, Sendable {
        /// The playing song's index when the tail was queued (the boundary the tail crosses).
        public let afterIndex: Int
        /// `afterIndex + 1`: the queued song's index in the app queue.
        public var nextIndex: Int { afterIndex + 1 }
        /// The app queue generation when it was queued. Any new queue load makes it stale.
        public let generation: Int
        /// The player entry of the playing song when the tail was queued.
        public let headEntryID: String
        /// Catalog id of the queued song. Entry ids are not stable while an inserted entry is
        /// transient, so the tail is recognised by its song.
        public let nextSongID: String
    }

    public enum KeepReason: Equatable, Sendable {
        case foreground
        case alreadyQueued
        case notLoaded
        /// Paused or held: nothing would advance anyway. Asked again on a later poll.
        case notPlaying
        /// The song started less than `settleSeconds` ago: the DJ session may still be arming its
        /// break for this boundary. Asked again on a later poll.
        case settling
        case boundaryWorkArmed
        case noNextSong
        /// The next song is the queue's last: its boundary runs the station refill.
        case refillBoundary
    }

    public enum WidenDecision: Equatable, Sendable {
        case keepOneSong(KeepReason)
        case queueNext(afterIndex: Int, nextIndex: Int)
    }

    public enum TrimReason: Equatable, Sendable {
        case foreground
        case boundaryWorkArmed
        case queueChanged
    }

    /// What one player sample means for a queued tail.
    public enum Step: Equatable, Sendable {
        /// Nothing to do (no tail, or still on the playing song with the tail still wanted).
        case unchanged
        /// Still on the playing song: remove the tail so the player holds one song again.
        case trim(TrimReason)
        /// The player moved to the tail: the app adopts it. Not a skip, not a natural-end boundary.
        case adopt(finishedIndex: Int, nextIndex: Int, woke: Bool)
        /// The player moved to the tail, but the app must not adopt it: the app queue's next song
        /// changed, or the app was awake at that end with a break armed. Pause it and run the
        /// normal boundary for `finishedIndex`; the next song then loads as today.
        case handBack(finishedIndex: Int, finishedEntryID: String)
        /// The tail no longer matches the player (a new queue, or the player emptied). Forget it;
        /// the boundary detector judges the sample as today.
        case forget
    }

    /// The playing song must have played this long before the tail is queued, so the DJ session
    /// has reported a break it arms for this boundary (`songStarted` runs right after the start).
    public static let settleSeconds: TimeInterval = 3

    /// A poll gap longer than this means the app was suspended in between.
    public static let awakeGapSeconds: TimeInterval = 2.5

    public private(set) var phase: Phase = .foreground
    public private(set) var pending: Pending?
    private var lastSampleUptime: TimeInterval?

    public init() {}

    public mutating func sceneEnteredBackground() { phase = .background }
    public mutating func sceneBecameActive() { phase = .foreground }

    /// The player queue was replaced (`startTrack`): no tail is queued any more.
    public mutating func queueReplaced() { pending = nil }

    /// Whether to queue the next song behind the playing one now. Asked when the app goes to the
    /// background and on every background poll, so a song started there gets its tail too.
    /// - `loadedIndex`: the index `startTrack` actually put in the player (nil after a cut or failure).
    /// - `headPosition`: seconds into the playing song.
    public func widen(queueIndex: Int, queueCount: Int, loadedIndex: Int?, headPlaying: Bool,
                      headPosition: TimeInterval?, boundaryWorkArmed: Bool) -> WidenDecision {
        guard phase == .background else { return .keepOneSong(.foreground) }
        guard pending == nil else { return .keepOneSong(.alreadyQueued) }
        guard let loadedIndex, loadedIndex == queueIndex, queueIndex >= 0 else { return .keepOneSong(.notLoaded) }
        guard headPlaying else { return .keepOneSong(.notPlaying) }
        guard let headPosition, headPosition >= Self.settleSeconds else { return .keepOneSong(.settling) }
        guard !boundaryWorkArmed else { return .keepOneSong(.boundaryWorkArmed) }
        let next = queueIndex + 1
        guard next < queueCount else { return .keepOneSong(.noNextSong) }
        guard next < queueCount - 1 else { return .keepOneSong(.refillBoundary) }
        return .queueNext(afterIndex: queueIndex, nextIndex: next)
    }

    /// The tail was inserted into the player. Call before awaiting the insert, so a poll that
    /// runs during the await already recognises it.
    public mutating func noteQueued(afterIndex: Int, generation: Int, headEntryID: String, nextSongID: String) {
        pending = Pending(afterIndex: afterIndex, generation: generation, headEntryID: headEntryID,
                          nextSongID: nextSongID)
    }

    /// The insert failed or the tail was trimmed: the player holds one song again.
    public mutating func clear() { pending = nil }

    /// Judges one player sample against the queued tail. Call on every poll before the boundary
    /// detector, so an adopted tail is the app's own change and never a natural end or a skip.
    /// - `entrySongID`: catalog id of the player's current entry, nil when there is none.
    /// - `appNextSongID`: catalog id of the app queue's song at `pending.nextIndex` now.
    public mutating func observe(entryID: String?, entrySongID: String?, queueIndex: Int, generation: Int,
                                 appNextSongID: String?, boundaryWorkArmed: Bool,
                                 uptime: TimeInterval?) -> Step {
        let awake: Bool
        if let uptime, let last = lastSampleUptime { awake = uptime - last <= Self.awakeGapSeconds } else { awake = false }
        if let uptime { lastSampleUptime = uptime }
        guard let tail = pending else { return .unchanged }
        guard tail.generation == generation, tail.afterIndex == queueIndex, entryID != nil else {
            pending = nil
            return .forget
        }
        if entryID == tail.headEntryID {
            // Still on the playing song.
            if appNextSongID != tail.nextSongID { return .trim(.queueChanged) }
            if boundaryWorkArmed { return .trim(.boundaryWorkArmed) }
            if phase == .foreground { return .trim(.foreground) }
            return .unchanged
        }
        guard entrySongID == tail.nextSongID else {
            // Neither the playing song's entry nor the tail: not a queue this type knows.
            pending = nil
            return .forget
        }
        pending = nil
        // The app's next song is no longer the one playing: never adopt the wrong song.
        // Awake at the end with work armed: the DJ must not talk over the next song.
        if appNextSongID != tail.nextSongID || (awake && boundaryWorkArmed) {
            return .handBack(finishedIndex: tail.afterIndex, finishedEntryID: tail.headEntryID)
        }
        return .adopt(finishedIndex: tail.afterIndex, nextIndex: tail.nextIndex, woke: !awake)
    }

    /// A trim of the player queue finished (or found nothing to trim).
    public mutating func trimmed() { pending = nil }
}

extension BackgroundQueueTail.KeepReason {
    public var logCode: String {
        switch self {
        case .foreground: "foreground"
        case .alreadyQueued: "alreadyQueued"
        case .notLoaded: "notLoaded"
        case .notPlaying: "notPlaying"
        case .settling: "settling"
        case .boundaryWorkArmed: "boundaryWorkArmed"
        case .noNextSong: "noNextSong"
        case .refillBoundary: "refillBoundary"
        }
    }
}

extension BackgroundQueueTail.TrimReason {
    public var logCode: String {
        switch self {
        case .foreground: "foreground"
        case .boundaryWorkArmed: "boundaryWorkArmed"
        case .queueChanged: "queueChanged"
        }
    }
}

extension PlaybackLog {
    /// #304 R1: indices and enum codes only.
    public static func queueTailQueued(after index: Int, next: Int) -> String {
        "queueTail queued after=\(index) next=\(next)"
    }

    public static func queueTailKept(index: Int, reason: BackgroundQueueTail.KeepReason) -> String {
        "queueTail kept index=\(index) reason=\(reason.logCode)"
    }

    public static func queueTailTrimmed(after index: Int, reason: BackgroundQueueTail.TrimReason) -> String {
        "queueTail trimmed after=\(index) reason=\(reason.logCode)"
    }

    public static func queueTailAdopted(finished: Int, next: Int, woke: Bool) -> String {
        "queueTail adopted finished=\(finished) next=\(next) woke=\(woke)"
    }

    public static func queueTailHandedBack(finished: Int) -> String {
        "queueTail handedBack finished=\(finished)"
    }

    public static func queueTailInsertFailed(after index: Int) -> String {
        "queueTail insertFailed after=\(index)"
    }
}

extension BackgroundQueueTail {
    /// Whether song `k`'s boundary has work armed, from read-only app state: a DJ break preparing or
    /// ready for `k`, any DJ line speaking, a talk-over holding `k`, or station work (an intro, a
    /// switch, or edits that apply at the boundary). Armed keeps the player at one song.
    public static func boundaryWorkArmed(afterTrack k: Int, dj: DJPresentationState, interludeSpeaking: Bool,
                                         talkoverOwnsBoundary: Bool, stationWorkPending: Bool) -> Bool {
        if interludeSpeaking || talkoverOwnsBoundary || stationWorkPending { return true }
        switch dj {
        case let .preparing(afterTrack, _), let .ready(afterTrack, _, _):
            return afterTrack == k
        case .speaking:
            return true
        case .idle, .unavailable:
            return false
        }
    }
}
