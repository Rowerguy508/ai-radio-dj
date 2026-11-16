import Foundation

/// Outer display and inner display share this decision. Folding changes the
/// container and the width class. It does not start playback, clear the
/// selected station, or drop the scroll anchor.
///
/// `PlayingScreen` and `FoldedPlayer` both call `layout`. A missing width class
/// is passed as `hasRegularWidth: false` (`horizontalSizeClass == .regular`),
/// so it stays compact. The compact arm is `FoldedColumnLayout.controlPlacement`,
/// so a phone portrait container stays `.phoneBottom`.
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

    /// Size class gates the Studio (`StudioLayoutMode`). Below that threshold the
    /// compact arm picks the phone column, the centred column, or the horizontal Duo.
    public static func layout(hasRegularWidth: Bool, containerWidth: Double, containerHeight: Double,
                              accessibilityTextSize: Bool) -> Layout {
        switch StudioLayoutMode.resolve(hasRegularWidth: hasRegularWidth,
                                        containerWidth: containerWidth,
                                        accessibilityTextSize: accessibilityTextSize) {
        case .studio: return .studio
        case .studioStacked: return .studioStacked
        case .compact:
            switch FoldedColumnLayout.controlPlacement(containerWidth: containerWidth,
                                                       containerHeight: containerHeight) {
            case .phoneBottom: return .phoneBottom
            case .centredColumn: return .centredColumn
            case .duoHorizontal: return .duoHorizontal
            }
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
