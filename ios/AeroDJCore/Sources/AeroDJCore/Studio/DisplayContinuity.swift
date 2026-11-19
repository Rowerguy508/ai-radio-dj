import Foundation

/// Outer display and inner display share this decision. Folding changes the
/// container and the width class. It does not start playback, clear the
/// selected station, or drop the scroll anchor.
///
/// `PlayingScreen` and `FoldedPlayer` both call `layout`. A missing width class
/// is passed as `hasRegularWidth: false` (`horizontalSizeClass == .regular`),
/// so it stays compact. The compact arm is `FoldedColumnLayout.controlPlacement`,
/// so a phone portrait container stays `.phoneBottom`. Since #542 a wide-and-tall
/// container is the rail layout whatever the width class.
public enum DisplayContinuity {
    /// One result for both displays. The first three are the compact player.
    public enum Layout: Equatable, Sendable {
        case phoneBottom
        case centredColumn
        case duoHorizontal
        case studio
        case studioStacked

        /// The compact player's placement, or nil when this is a Studio layout.
        public var controlPlacement: FoldedColumnLayout.ControlPlacement? {
            switch self {
            case .phoneBottom: .phoneBottom
            case .centredColumn: .centredColumn
            case .duoHorizontal: .duoHorizontal
            case .studio, .studioStacked: nil
            }
        }

        public var isCompactPlayer: Bool { controlPlacement != nil }
    }

    /// 2.0 rail routing (#542, after build 49). A wide-and-tall container
    /// (`FoldedColumnLayout.controlPlacement == .duoHorizontal`) is the rail layout
    /// (`FoldedPlayer` + `DuoVerticalRail`) at either size class: a regular width class no
    /// longer swaps it for the two-zone Studio or the two-pane arrangement. Accessibility
    /// text sizes keep `.studioStacked` wherever the Studio gate opens (regular, 716+), so
    /// large text still gets one scrolling column, except in the open Duo's own window
    /// (`FoldedColumnLayout.isOpenDuoWindow`), which keeps the rail as compact does. A regular container at 716+ that is not
    /// wide-and-tall (shorter than the rail needs) keeps the Studio. Everything else is the
    /// compact arm: the phone column, the centred column, or the horizontal Duo.
    public static func layout(hasRegularWidth: Bool, containerWidth: Double, containerHeight: Double,
                              accessibilityTextSize: Bool) -> Layout {
        let placement = FoldedColumnLayout.controlPlacement(containerWidth: containerWidth,
                                                            containerHeight: containerHeight)
        switch StudioLayoutMode.resolve(hasRegularWidth: hasRegularWidth,
                                        containerWidth: containerWidth,
                                        accessibilityTextSize: accessibilityTextSize) {
        case .studioStacked:
            // Build 54 (-Nova): the open Duo keeps the rail at accessibility text sizes at either
            // width class, as compact already did. A full-screen iPad (longer than
            // `openDuoMaxSide`) and a regular container too short for the rail keep the stack.
            return placement == .duoHorizontal
                && FoldedColumnLayout.isOpenDuoWindow(containerWidth: containerWidth,
                                                      containerHeight: containerHeight)
                ? .duoHorizontal : .studioStacked
        case .studio:
            return placement == .duoHorizontal ? .duoHorizontal : .studio
        case .compact:
            switch placement {
            case .phoneBottom: return .phoneBottom
            case .centredColumn: return .centredColumn
            case .duoHorizontal: return .duoHorizontal
            }
        }
    }

    /// The `PlayingScreen` branch for a layout. Only the two Studio results leave the
    /// compact player; the rail layout is the compact branch (`FoldedPlayer`).
    public static func screenMode(_ layout: Layout) -> StudioLayoutMode {
        switch layout {
        case .studio: .studio
        case .studioStacked: .studioStacked
        case .phoneBottom, .centredColumn, .duoHorizontal: .compact
        }
    }

    /// Short, Release-safe name of a layout for the layout log. No user content.
    public static func logName(_ layout: Layout) -> String {
        switch layout {
        case .phoneBottom: "phoneBottom"
        case .centredColumn: "centredColumn"
        case .duoHorizontal: "duoRail"
        case .studio: "studio"
        case .studioStacked: "studioStacked"
        }
    }

    /// Stable id for a continuity-probe row. The player scroll and the capture
    /// readout use the same string.
    public static func rowAnchor(_ index: Int) -> String { "continuity.row.\(index)" }

    /// Art and title anchors in the player scroll. Not keyed on the size class.
    public static let artAnchor = "player.art"
    public static let titleAnchor = "player.title"

    /// `playing|track-id`. Empty track id when nothing is loaded. A fold must
    /// leave this string alone.
    public static func playbackToken(transport: TransportState, trackID: String?) -> String {
        "\(transport.rawValue)|\(trackID ?? "")"
    }

    /// What survives opening the phone. A value, not view state: the views that
    /// a size-class `if` destroys read and write this, they do not own it.
    public struct Session: Equatable, Sendable {
        public var selectedStationID: String?
        public var scrollAnchor: String?
        public var playbackToken: String
        public var loadCount: Int

        public init(selectedStationID: String?, scrollAnchor: String?, playbackToken: String, loadCount: Int) {
            self.selectedStationID = selectedStationID
            self.scrollAnchor = scrollAnchor
            self.playbackToken = playbackToken
            self.loadCount = loadCount
        }

        /// The inner display's layout. The session is the same value: station,
        /// scroll anchor, playback and load count are not touched.
        public func opening(to layout: Layout) -> Session {
            _ = layout
            return self
        }

        public func scrolled(to anchor: String?) -> Session {
            var copy = self
            copy.scrollAnchor = anchor
            return copy
        }

        /// A recreated view's `onAppear`. A stored anchor wins. The default is
        /// only written when nothing was stored, so appear cannot jump the scroll.
        public func appeared(defaultAnchor: String?) -> Session {
            if let scrollAnchor, !scrollAnchor.isEmpty { return self }
            return scrolled(to: defaultAnchor)
        }

        /// A real catalog or station load. A size-class change does not call this.
        public func loaded() -> Session {
            var copy = self
            copy.loadCount += 1
            return copy
        }
    }
}
