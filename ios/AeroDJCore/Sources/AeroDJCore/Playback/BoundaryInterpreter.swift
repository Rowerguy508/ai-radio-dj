import Foundation

/// What one player sample means for the station queue.
///
/// A one-song MusicKit queue ends with no current entry. That is a planned handoff when
/// another song is still in the station queue, and a stop when it is the last song.
/// An entry whose identity changes while playing is the other natural-end shape.
public enum BoundaryStep: Equatable, Sendable {
    /// The entry id changed. The caller advances its queue index.
    case advancedEntry(finishedIndex: Int, boundary: PlaybackBoundary)
    /// The single-song queue ended and another song follows. The caller does not advance yet.
    case plannedHandoff(finishedIndex: Int, nextIndex: Int, boundary: PlaybackBoundary)
    case stopped(finishedIndex: Int, boundary: PlaybackBoundary)

    public var finishedIndex: Int {
        switch self {
        case let .advancedEntry(finishedIndex, _),
             let .plannedHandoff(finishedIndex, _, _),
             let .stopped(finishedIndex, _):
            finishedIndex
        }
    }
}

/// `PlaybackBoundaryDetector` plus `QueueHandoff`, in the order `MusicKitService` polls.
public struct BoundaryInterpreter: Sendable {
    private var detector = PlaybackBoundaryDetector()

    public init() {}

    public mutating func userRequestedChange() {
        detector.userRequestedChange()
    }

    public mutating func interpret(
        _ observation: PlaybackObservation,
        queueIndex: Int,
        queueCount: Int
    ) -> BoundaryStep? {
        guard let boundary = detector.consume(observation) else { return nil }
        switch boundary {
        case .naturalEnd:
            return .advancedEntry(finishedIndex: queueIndex, boundary: boundary)
        case let .queueFinished(lastEntryID):
            switch QueueHandoff.afterSongEnds(finishedIndex: queueIndex, count: queueCount) {
            case let .advance(next):
                return .plannedHandoff(
                    finishedIndex: queueIndex,
                    nextIndex: next,
                    boundary: .naturalEnd(finishedEntryID: lastEntryID)
                )
            case .stop:
                return .stopped(finishedIndex: queueIndex, boundary: boundary)
            }
        }
    }
}
