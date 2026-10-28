import Foundation

/// One observation of the player: which queue entry is current, and whether
/// playback is running. Fed from MusicKit state on a timer and on change.
/// `position` and `duration` are optional; without them only entry changes count as ends.
public struct PlaybackObservation: Equatable, Sendable {
    /// Identity of the current queue entry, nil when the queue is empty.
    public let entryID: String?
    public let isPlaying: Bool
    /// Seconds into the current entry, when the player reports it.
    public let position: TimeInterval?
    /// Catalog duration of the current entry, when known.
    public let duration: TimeInterval?
    /// Monotonic seconds when the sample was taken (`systemUptime`), when the caller has it.
    /// Used only to accumulate the entry's elapsed play time across slow or late polls.
    public let uptime: TimeInterval?

    public init(entryID: String?, isPlaying: Bool, position: TimeInterval? = nil, duration: TimeInterval? = nil,
                uptime: TimeInterval? = nil) {
        self.entryID = entryID
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
        self.uptime = uptime
    }

    /// Playback is within `tolerance` seconds of the entry's end.
    public func isNearEnd(tolerance: TimeInterval = 1.5) -> Bool {
        guard let position, let duration, duration > 0 else { return false }
        return position >= duration - tolerance
    }
}

/// A boundary between queue items that the app should react to.
public enum PlaybackBoundary: Equatable, Sendable {
    /// The previous entry finished on its own and the queue moved to the next one.
    case naturalEnd(finishedEntryID: String)
    /// The last entry finished on its own and nothing is queued.
    case queueFinished(lastEntryID: String)
}

/// Reports natural track boundaries exactly once each.
///
/// Signal: the current queue entry *changes identity* while playback was
/// running, and the app did not ask for the change. Pauses, phone-call
/// interruptions and resumes never change the entry, so they never fire.
/// The app calls `userRequestedChange()` before any skip or queue replacement,
/// so those changes are not mistaken for natural ends.
///
/// Second signal, for a queue that keeps its last entry after it ends: playback stops
/// within 1.5 s of the entry's duration on the same entry. That reports `queueFinished`
/// once, so the app takes the same path as a cleared queue.
public struct PlaybackBoundaryDetector: Sendable {
    private var entryID: String?
    private var wasPlaying = false
    private var userChangePending = false
    /// The entry whose end was already reported by position, so it is not reported twice.
    private var endedEntryID: String?
    /// Furthest position seen for `entryID`, when the player reported one. The furthest, not
    /// the last, so a playhead reset at the very end cannot hide a song that really played.
    private var lastPosition: TimeInterval?
    /// Build 9 P0 (-Atlas): an entry that changed or cleared before it played this far is a
    /// failed or replaced start, not a natural end. Only applies when a position was reported.
    public static let minimumProgressForNaturalEnd: TimeInterval = 2.0
    /// Set when a change or clear was refused for lack of progress. Read with `takeNoProgressEnd()`.
    private var noProgressEndPending = false

    // Build 18 P0 (-Fry): sticky per-entry facts that a system interruption cannot clear.
    /// Share of the catalog duration that counts as "this entry played through".
    public static let playedThroughFraction: Double = 0.9
    /// The raw last sample of this entry was `.playing`. Only samples change it, never a notice.
    private var lastSampleWasPlaying = false
    /// This entry was observed playing at least once.
    private var observedPlaying = false
    /// Accumulated play time of this entry, from sample uptimes (covers slow or late polls).
    private var elapsedPlay: TimeInterval = 0
    private var lastSampleUptime: TimeInterval?
    private var lastSamplePosition: TimeInterval?
    /// Last known catalog duration of this entry.
    private var lastDuration: TimeInterval?
    /// A user pause or a route loss holds this entry until it is observed playing again.
    /// While set, no stop of this entry is a natural end.
    private var heldByUserOrRoute = false
    /// A system interruption began while this entry was in its end window, or after its end
    /// was reported. Read by the hold decision at the boundary (`interruptionBeganNearEnd`).
    public private(set) var interruptionBeganNearEnd = false
    /// The last boundary reported has not been followed by a new load yet.
    private var endReportedSinceLoad = false
    /// A system interruption arrived after the last playing sample. If the next sample shows
    /// the end, the interruption began inside the end window (between that sample and the end).
    private var interruptionSinceLastPlayingSample = false

    // Song scrubbing (-Atlas): a user seek is an explicit event, so only `userSeeked` resets
    // per-entry facts. No sample-shape heuristic does (build 18 regressed on one).
    /// Seconds after a seek during which stopped samples, and every reported position, are
    /// ignored: MusicKit can report the pre-seek position or a transient stop while it seeks.
    public static let seekSettleSeconds: TimeInterval = 1.5
    /// The last committed user seek on this entry. Cleared by a new entry or an empty queue.
    private var seekBaseline: SeekBaseline?

    private struct SeekBaseline: Sendable {
        let target: TimeInterval
        /// Uptime when settling ends. Nil when the seek had no uptime: settling then ends at
        /// the first playing sample after the seek.
        let settleUntil: TimeInterval?
        var settled = false
        /// Real play time accumulated since the seek (sample uptimes, same as `elapsedPlay`).
        var playSinceSeek: TimeInterval = 0

        func isSettling(at uptime: TimeInterval?) -> Bool {
            guard !settled else { return false }
            guard let settleUntil, let uptime else { return true }
            return uptime < settleUntil
        }
    }

    public init() {}

    /// The user committed a seek within the current entry to `target` seconds, at monotonic
    /// `uptime`. Call it right before the player's playhead is set.
    ///
    /// Rules (Orion/Nova API, owner ask "We also need scrubbing for songs"):
    /// - A seek target never counts as played through by itself. From here, `playedThrough`
    ///   comes only from real play: accumulated play time past 90%, or real play since the seek
    ///   that carried the playhead into the end window. A forward seek past 90% sets nothing.
    /// - A seek back is a replay: accumulated play time and the furthest position restart from
    ///   the target, so a pause after it can never read as the rewound end shape.
    /// - For `seekSettleSeconds`, stopped samples and positions are ignored (stale or transient).
    /// - The stopped-at-end shape is untouched, so a song seeked near its end still ends once.
    public mutating func userSeeked(to target: TimeInterval, uptime: TimeInterval?) {
        guard entryID != nil else { return }
        let playhead = lastSamplePosition ?? lastPosition ?? 0
        if target < playhead {
            elapsedPlay = 0
        }
        lastPosition = target
        lastSamplePosition = target
        if let uptime { lastSampleUptime = uptime }
        interruptionBeganNearEnd = false
        seekBaseline = SeekBaseline(target: target, settleUntil: uptime.map { $0 + Self.seekSettleSeconds })
    }

    /// Call before the app itself changes what plays (skip, new queue).
    public mutating func userRequestedChange() {
        userChangePending = true
        endedEntryID = nil
        interruptionBeganNearEnd = false
        endReportedSinceLoad = false
    }

    /// Why playback stopped. A natural end has no cause.
    public enum HoldCause: Equatable, Sendable {
        case userPause
        case systemInterruption
        case routeLoss
    }

    /// A pause the app made with no stated cause. Treated as a user pause: never a finish.
    public mutating func pausedByApp() {
        pausedByApp(.userPause)
    }

    /// A user pause and a route loss are never a finish, even in the last seconds of the song.
    /// Build 18 P0 (-Fry): a system interruption is not a user decision. It clears `wasPlaying`
    /// as before, but it cannot clear the entry's sticky played-through facts, so a stop that
    /// has the shape of an end (at the end, or rewound to 0 after the song played through) is
    /// still reported, once. A mid-song interruption never has that shape, so it stays a pause.
    public mutating func pausedByApp(_ cause: HoldCause) {
        wasPlaying = false
        switch cause {
        case .userPause, .routeLoss:
            heldByUserOrRoute = true
        case .systemInterruption:
            interruptionSinceLastPlayingSample = true
            if endReportedSinceLoad || playedThrough || furthestIsNearEnd {
                interruptionBeganNearEnd = true
            }
        }
    }

    /// True once after a change or clear was refused because the entry never progressed.
    /// The app surfaces that as a failed start and does not advance the queue.
    public mutating func takeNoProgressEnd() -> Bool {
        defer { noProgressEndPending = false }
        return noProgressEndPending
    }

    /// The entry that is going away played less than the minimum, by a reported position.
    private var finishingEntryNeverProgressed: Bool {
        // A seek is only offered for a song that started and was confirmed playing.
        guard seekBaseline == nil, let furthest = lastPosition else { return false }
        return furthest < Self.minimumProgressForNaturalEnd
    }

    /// Sticky: this entry was observed playing, and either its furthest position or its
    /// accumulated play time passed 90% of its duration.
    var playedThrough: Bool {
        guard observedPlaying, let duration = lastDuration, duration > 0 else { return false }
        let threshold = duration * Self.playedThroughFraction
        if let seek = seekBaseline {
            // After a seek: real play only. Never the seek target or the furthest position.
            if elapsedPlay >= threshold { return true }
            return seek.playSinceSeek > 0
                && seek.target + seek.playSinceSeek >= duration - Self.endWindowSeconds
        }
        return (lastPosition ?? 0) >= threshold || elapsedPlay >= threshold
    }

    /// Same window as `PlaybackObservation.isNearEnd()`.
    static let endWindowSeconds: TimeInterval = 1.5

    private var furthestIsNearEnd: Bool {
        PlaybackObservation(entryID: entryID, isPlaying: false, position: lastPosition,
                            duration: lastDuration).isNearEnd()
    }

    /// The stop may be a natural end of the entry going away (cleared or changed).
    private var departingEntryMayHaveEnded: Bool {
        !heldByUserOrRoute && (wasPlaying || playedThrough)
    }

    private mutating func resetEntryFacts(_ observation: PlaybackObservation) {
        lastPosition = observation.position
        lastDuration = observation.duration
        observedPlaying = observation.isPlaying
        elapsedPlay = 0
        lastSampleUptime = observation.uptime
        lastSamplePosition = observation.position
        lastSampleWasPlaying = observation.isPlaying
        heldByUserOrRoute = false
        interruptionBeganNearEnd = false
        interruptionSinceLastPlayingSample = false
        seekBaseline = nil
    }

    /// An end is being reported. An interruption since the last playing sample began at the end.
    private mutating func noteEndReported() {
        endReportedSinceLoad = true
        if interruptionSinceLastPlayingSample { interruptionBeganNearEnd = true }
    }

    /// Adds the play time between the previous sample and this one, when the previous sample
    /// was playing. Capped by what was left of the song, so a long gap (suspension) cannot
    /// count more than the song could have played.
    private mutating func accumulate(_ observation: PlaybackObservation) {
        defer {
            lastSampleUptime = observation.uptime ?? lastSampleUptime
            lastSamplePosition = observation.position ?? lastSamplePosition
        }
        guard lastSampleWasPlaying, let now = observation.uptime, let then = lastSampleUptime,
              now > then else { return }
        var gap = now - then
        if let duration = lastDuration, let from = lastSamplePosition {
            gap = min(gap, max(0, duration - from))
        }
        elapsedPlay += gap
        seekBaseline?.playSinceSeek += gap
    }

    public mutating func consume(_ observation: PlaybackObservation) -> PlaybackBoundary? {
        var settlingStop = false
        defer { if !settlingStop { wasPlaying = observation.isPlaying } }
        guard let current = observation.entryID else {
            // Queue emptied. A natural finish of the last item is a boundary.
            let finished = entryID
            let neverProgressed = finishingEntryNeverProgressed
            let mayHaveEnded = departingEntryMayHaveEnded && endedEntryID != finished
            entryID = nil
            lastPosition = nil
            lastSampleWasPlaying = false
            observedPlaying = false
            seekBaseline = nil
            defer { userChangePending = false }
            if let finished, mayHaveEnded, !userChangePending {
                guard !neverProgressed else {
                    noProgressEndPending = true
                    return nil
                }
                noteEndReported()
                return .queueFinished(lastEntryID: finished)
            }
            return nil
        }
        guard let previous = entryID else {
            // First entry of a queue: nothing finished yet.
            entryID = current
            resetEntryFacts(observation)
            userChangePending = false
            return nil
        }
        guard current == previous else {
            // Entry changed. Consume the app's pending request whether or not it was ours.
            let appRequested = userChangePending
            let neverProgressed = finishingEntryNeverProgressed
            let mayHaveEnded = departingEntryMayHaveEnded && endedEntryID != previous
            let interruptedAtEnd = interruptionSinceLastPlayingSample
            userChangePending = false
            entryID = current
            endedEntryID = nil
            resetEntryFacts(observation)
            // A change while paused cannot be a natural advance, so it is not reported.
            guard mayHaveEnded, !appRequested else { return nil }
            guard !neverProgressed else {
                noProgressEndPending = true
                return nil
            }
            endReportedSinceLoad = true
            if interruptedAtEnd { interruptionBeganNearEnd = true }
            return .naturalEnd(finishedEntryID: previous)
        }
        if let duration = observation.duration { lastDuration = duration }
        // Inside a seek's settle window: a stopped sample is transient and changes nothing (the
        // next stop after the window is still judged as the first stop after playing), and no
        // reported position is trusted. A playing sample there still counts as play time.
        let settling = seekBaseline?.isSettling(at: observation.uptime) ?? false
        if settling, !observation.isPlaying {
            settlingStop = true
            return nil
        }
        if seekBaseline != nil, !settling { seekBaseline?.settled = true }
        accumulate(observation)
        if settling, seekBaseline?.settleUntil == nil { seekBaseline?.settled = true }
        let firstStopAfterPlaying = lastSampleWasPlaying && !observation.isPlaying
        lastSampleWasPlaying = observation.isPlaying
        if observation.isPlaying {
            observedPlaying = true
            // A playing sample while settling may be stale: it cannot release a user hold.
            if !settling { heldByUserOrRoute = false }
            interruptionSinceLastPlayingSample = false
        }
        if !settling, let position = observation.position {
            if observation.isPlaying, let furthest = lastPosition, position < furthest,
               position >= Self.minimumProgressForNaturalEnd {
                // Still playing well past a rewind: a real restart, so the old furthest is gone.
                lastPosition = position
                elapsedPlay = 0
                interruptionBeganNearEnd = false
            } else {
                lastPosition = max(lastPosition ?? position, position)
            }
        }
        // Same entry: playback stopped at its end, and the queue kept the entry.
        // Build 18 P0 (-Fry): judged on the first stopped sample after a playing one, from
        // sticky facts, not from `wasPlaying` (an interruption at the end clears that). Two
        // shapes are an end: the stop is at the end, or the playhead is back at 0 after the
        // entry played through (MusicKit rewinds a finished one-song queue).
        guard firstStopAfterPlaying, !heldByUserOrRoute, !userChangePending,
              endedEntryID != current else { return nil }
        let stoppedAtEnd = observation.isNearEnd()
        let rewoundAfterPlayingThrough = playedThrough
            && (observation.position ?? 0) < Self.minimumProgressForNaturalEnd
        guard stoppedAtEnd || rewoundAfterPlayingThrough else { return nil }
        endedEntryID = current
        noteEndReported()
        return .queueFinished(lastEntryID: current)
    }
}
