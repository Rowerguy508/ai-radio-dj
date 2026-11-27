#if DEBUG
import Foundation

/// #465 item 1, DEBUG Studio capture only (-Nova). The owner decides whether the open Duo's
/// controls move into the iOS 27.1 system vertical bar (`toolbarVerticalBehavior(.automatic)`
/// plus `axisBehavior(.verticalPreferred)`, the toolbar `DuoSystemVerticalToolbar` already
/// builds) or stay in the custom Rail D. These captures give the owner real shots of the system
/// bar to decide from. Nothing ships: the whole file is `#if DEBUG`, and the app reads it only
/// inside `#if DEBUG`, so Release and the default Debug run draw Rail D exactly as before.
///
/// Pure and UI-free so the gate and the frames are unit tested on Linux.
public enum SystemVerticalBarsCapture {
    /// `-AeroDJCaptureSystemVerticalBars YES`. Honoured only in a Studio capture run.
    public static let launchKey = "AeroDJCaptureSystemVerticalBars"

    /// One frame per shot. The frames are Rail D's own capture frames (`RailDCaptureContainer`),
    /// so a shot sits beside its `rail-d-duo-open-*` counterpart with nothing else changed.
    public enum Scenario: String, CaseIterable, Equatable, Sendable {
        /// The open Duo upright, 640 x 820 pt, compact width (Rail D's `railDPortrait` frame).
        case duoOpenPortrait = "systemVerticalBarsDuoOpenPortrait"
        /// The open Duo sideways, 820 x 640 pt, regular width, flat hinge
        /// (Rail D's `railDLandscapeCentred` frame).
        case duoOpenLandscape = "systemVerticalBarsDuoOpenLandscape"

        /// The scenario named in `-AeroDJStudioCaptureScenario`, if it is one of these.
        public static func named(_ raw: String?) -> Scenario? {
            raw.flatMap(Scenario.init(rawValue:))
        }

        /// Shot file prefix, including the capture frame the test sets (for example
        /// `system-vertical-bars-820x640-open-landscape`). The UI test rebuilds this from
        /// the settled container so the name matches the size it read.
        public var shotName: String {
            Self.shotName(width: containerWidth, height: containerHeight,
                          landscape: self == .duoOpenLandscape)
        }

        /// The same frame after Collapse (`folded.collapse`), for the owner's open question
        /// "should Collapse keep a rail at all?".
        public var collapsedShotName: String {
            Self.shotName(width: containerWidth, height: containerHeight,
                          landscape: self == .duoOpenLandscape, collapsed: true)
        }

        public static func shotName(width: Double, height: Double, landscape: Bool,
                                    collapsed: Bool = false) -> String {
            let w = Int(width.rounded())
            let h = Int(height.rounded())
            let pose = landscape ? "open-landscape" : "open-portrait"
            return "system-vertical-bars-\(w)x\(h)-\(pose)" + (collapsed ? "-collapsed" : "")
        }

        public var containerWidth: Double {
            switch self {
            case .duoOpenPortrait: 640
            case .duoOpenLandscape: 820
            }
        }

        public var containerHeight: Double {
            switch self {
            case .duoOpenPortrait: 820
            case .duoOpenLandscape: 640
            }
        }

        /// The width class Rail D's matching frame forces.
        public var hasRegularWidth: Bool { self == .duoOpenLandscape }
    }

    /// Whether the player swaps the custom rail for the system vertical bar. Every input has to
    /// hold: a Studio capture run in the test station, the launch flag, and a binary and OS that
    /// have the 27.1 vertical bar API (`#if compiler(>=6.4)` and `#available(iOS 27.1, *)`).
    /// Anything missing keeps Rail D, so the custom rail is never removed with nothing in its place.
    public static func attachesSystemBar(studioCapture: Bool, testStation: Bool,
                                         launchFlag: Bool, sdkHasVerticalBar: Bool) -> Bool {
        studioCapture && testStation && launchFlag && sdkHasVerticalBar
    }
}
#endif
