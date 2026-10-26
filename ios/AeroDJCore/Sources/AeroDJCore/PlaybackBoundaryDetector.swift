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

    public init(entryID: String?, isPlaying: Bool, position: TimeInterval? = nil, duration: TimeInterval? = nil) {
        self.entryID = entryID
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
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

    public init() {}

    /// Call before the app itself changes what plays (skip, new queue).
    public mutating func userRequestedChange() {
        userChangePending = true
    }

    public mutating func consume(_ observation: PlaybackObservation) -> PlaybackBoundary? {
        defer { wasPlaying = observation.isPlaying }
        guard let current = observation.entryID else {
            // Queue emptied. A natural finish of the last item is a boundary.
            let finished = entryID
            entryID = nil
            defer { userChangePending = false }
            if let finished, wasPlaying, !userChangePending {
                return .queueFinished(lastEntryID: finished)
            }
            return nil
        }
        guard let previous = entryID else {
            // First entry of a queue: nothing finished yet.
            entryID = current
            userChangePending = false
            return nil
        }
        guard current == previous else {
            // Entry changed. Consume the app's pending request whether or not it was ours.
            let appRequested = userChangePending
            userChangePending = false
            entryID = current
            endedEntryID = nil
            // A change while paused cannot be a natural advance, so it is not reported.
            guard wasPlaying, !appRequested else { return nil }
            return .naturalEnd(finishedEntryID: previous)
        }
        // Same entry: playback stopped at its end, and the queue kept the entry.
        guard wasPlaying, !observation.isPlaying, observation.isNearEnd(),
              endedEntryID != current, !userChangePending else { return nil }
        endedEntryID = current
        return .queueFinished(lastEntryID: current)
    }
}
