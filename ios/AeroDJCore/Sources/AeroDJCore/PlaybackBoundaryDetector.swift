import Foundation

/// One observation of the player: which queue entry is current, and whether
/// playback is running. Fed from MusicKit state on a timer and on change.
public struct PlaybackObservation: Equatable, Sendable {
    /// Identity of the current queue entry, nil when the queue is empty.
    public let entryID: String?
    public let isPlaying: Bool

    public init(entryID: String?, isPlaying: Bool) {
        self.entryID = entryID
        self.isPlaying = isPlaying
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
public struct PlaybackBoundaryDetector: Sendable {
    private var entryID: String?
    private var wasPlaying = false
    private var userChangePending = false

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
        guard current != previous else { return nil }
        // Entry changed. Consume the app's pending request whether or not it was ours.
        let appRequested = userChangePending
        userChangePending = false
        entryID = current
        // A change while paused cannot be a natural advance, so it is not reported.
        guard wasPlaying, !appRequested else { return nil }
        return .naturalEnd(finishedEntryID: previous)
    }
}
