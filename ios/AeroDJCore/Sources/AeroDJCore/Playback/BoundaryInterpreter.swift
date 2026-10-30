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

    /// A pause the app recorded (user, call, or route). Forwarded to the detector so a stop
    /// in the last 1.5 s is not a natural end.
    public mutating func pausedByApp() {
        detector.pausedByApp()
    }

    public mutating func pausedByApp(_ cause: PlaybackBoundaryDetector.HoldCause) {
        detector.pausedByApp(cause)
    }

    /// Song scrubbing (-Atlas): the user committed a seek within the current entry. The only
    /// call that re-baselines the entry's played-through facts (see the detector's rules).
    public mutating func userSeeked(to target: TimeInterval, uptime: TimeInterval?) {
        detector.userSeeked(to: target, uptime: uptime)
    }

    /// Build 18 P0 (-Fry): a system interruption began in the finishing song's end window,
    /// or after its end was reported. Read once at the boundary by the song-end hold decision.
    public var interruptionBeganNearEnd: Bool { detector.interruptionBeganNearEnd }

    /// #149 (-Atlas): MusicKit cleared, changed or rewound the finished entry after the latest
    /// interruption began. The only evidence a never-ended interruption may be released on.
    public var queueFinishedSinceInterruption: Bool { detector.queueFinishedSinceInterruption }

    /// True once after the detector refused a change or clear because the entry never
    /// progressed (build 9 P0). The caller must surface a failed start and must not advance.
    public mutating func takeNoProgressEnd() -> Bool {
        detector.takeNoProgressEnd()
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
