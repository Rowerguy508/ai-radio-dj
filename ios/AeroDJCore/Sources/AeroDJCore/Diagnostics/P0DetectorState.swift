// TEMPORARY P0 diagnostics (remove with #121 / #133). -Fry
// Compiled only in Debug and in AERODJ_P0_DIAG builds.
//
// A read-only view of the boundary detector's private state for the on-screen trace. It is
// read by reflection so `PlaybackBoundaryDetector.swift` and `BoundaryInterpreter.swift` are not
// edited at all (#148 owns the end check there). A renamed field reads as nil/false;
// `P0EventTraceTests.testDetectorStateIsReadable` fails then, so the rename cannot go unnoticed.
#if DEBUG || AERODJ_P0_DIAG
import Foundation

public struct P0DetectorState: Equatable, Sendable {
    /// Furthest position seen for the current entry (`lastPosition`).
    public let furthest: TimeInterval?
    public let wasPlaying: Bool
    public let userChangePending: Bool
    public let noProgressEndPending: Bool
    /// #148's sticky per-entry fact: observed playing, and furthest or play time past 90%.
    public let playedThrough: Bool
    /// #148: a user pause or route loss holds the entry (never an end).
    public let held: Bool
    /// #148: a system interruption began inside the end window.
    public let intNearEnd: Bool
    /// #148: the end was already reported for this load (reported once).
    public let endReported: Bool

    public init(furthest: TimeInterval?, wasPlaying: Bool, userChangePending: Bool, noProgressEndPending: Bool,
                playedThrough: Bool = false, held: Bool = false, intNearEnd: Bool = false,
                endReported: Bool = false) {
        self.furthest = furthest
        self.wasPlaying = wasPlaying
        self.userChangePending = userChangePending
        self.noProgressEndPending = noProgressEndPending
        self.playedThrough = playedThrough
        self.held = held
        self.intNearEnd = intNearEnd
        self.endReported = endReported
    }

    public init(_ detector: PlaybackBoundaryDetector) {
        var fields: [String: Any] = [:]
        for child in Mirror(reflecting: detector).children {
            if let label = child.label { fields[label] = child.value }
        }
        self.init(furthest: (fields["lastPosition"] as? TimeInterval?) ?? nil,
                  wasPlaying: fields["wasPlaying"] as? Bool ?? false,
                  userChangePending: fields["userChangePending"] as? Bool ?? false,
                  noProgressEndPending: fields["noProgressEndPending"] as? Bool ?? false,
                  playedThrough: detector.playedThrough,
                  held: fields["heldByUserOrRoute"] as? Bool ?? false,
                  intNearEnd: detector.interruptionBeganNearEnd,
                  endReported: fields["endReportedSinceLoad"] as? Bool ?? false)
    }

    public init(_ interpreter: BoundaryInterpreter) {
        let detector = Mirror(reflecting: interpreter).children
            .first { $0.label == "detector" }?.value as? PlaybackBoundaryDetector
        self.init(detector ?? PlaybackBoundaryDetector())
    }

    /// The detector's same-entry end test at c257a3d (`isNearEnd` of the sample, or of the
    /// furthest position). A copy for display: it does not feed the detector.
    public static func reachedEnd(_ observation: PlaybackObservation, furthest: TimeInterval?) -> Bool {
        observation.isNearEnd() || PlaybackObservation(
            entryID: nil, isPlaying: false, position: furthest,
            duration: observation.duration).isNearEnd()
    }
}
#endif
