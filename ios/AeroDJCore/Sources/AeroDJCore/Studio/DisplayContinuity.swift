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
    /// large text still gets one scrolling column. A regular container at 716+ that is not
    /// wide-and-tall (shorter than the rail needs) keeps the Studio. Everything else is the
    /// compact arm: the phone column, the centred column, or the horizontal Duo.
    public static func layout(hasRegularWidth: Bool, containerWidth: Double, containerHeight: Double,
                              accessibilityTextSize: Bool) -> Layout {
        let placement = FoldedColumnLayout.controlPlacement(containerWidth: containerWidth,
                                                            containerHeight: containerHeight)
        switch StudioLayoutMode.resolve(hasRegularWidth: hasRegularWidth,
                                        containerWidth: containerWidth,
                                        accessibilityTextSize: accessibilityTextSize) {
        case .studioStacked: return .studioStacked
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

    /// A `scrollPosition` write: keep the incoming id, or ignore it so a
    /// rebuilt scroller cannot jump the stored spot to the top.
    public enum ScrollAnchorWrite: Equatable, Sendable {
        case ignore
        case accept
    }

    /// Deterministic guard for a stored scroll id when a scroller is rebuilt
    /// (opening the phone). Never uses a clock or a main-queue turn.
    ///
    /// Phases: `idle` → `armed` (a stored id and a new scroller) → `adopted`
    /// (the scroller reported the held id) or `userScrolled` (the user dragged)
    /// → `released`. An art write that arrives before `arm`, or after the 0.45s
    /// layout animation, is ignored until adoption or a user scroll. A user
    /// scroll back to the art is then kept. While armed or adopted, any id
    /// other than the held one is ignored; that is the old DEBUG probe guard,
    /// for every stored id, in Release too.
    public struct ScrollAnchorMachine: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            case idle
            case armed
            case adopted
            case userScrolled
            case released
        }

        public private(set) var phase: Phase = .idle
        public private(set) var held: String = ""
        /// Identity of the scroller this cycle is tracking. Empty means none.
        public private(set) var layout: String = ""

        public init() {}

        /// Arm for a (re)built scroller. A new `layout` always starts a cycle:
        /// a non-empty stored id arms, an empty one is idle. Calls for the same
        /// layout after adoption, a user scroll, or release are no-ops, so a
        /// later user scroll back to the art is not re-armed away.
        public mutating func arm(held stored: String, layout: String) {
            if !layout.isEmpty, layout == self.layout {
                switch phase {
                case .adopted, .userScrolled, .released:
                    return
                case .armed, .idle:
                    break
                }
            }
            self.layout = layout
            if stored.isEmpty {
                held = ""
                phase = .idle
            } else {
                held = stored
                phase = .armed
            }
        }

        /// A scrollPosition write. Passing `layout` arms first when this is a
        /// new scroller, so an art write that lands before a separate `arm`
        /// call cannot overwrite the stored id.
        public mutating func write(_ incoming: String?, stored: String = "",
                                   layout: String? = nil) -> ScrollAnchorWrite {
            if let layout, !layout.isEmpty {
                let seed = stored.isEmpty ? held : stored
                arm(held: seed, layout: layout)
            }
            let next = incoming ?? ""
            switch phase {
            case .idle, .released:
                return .accept
            case .userScrolled:
                phase = .released
                return .accept
            case .armed:
                if !held.isEmpty, next == held {
                    phase = .adopted
                    return .accept
                }
                return .ignore
            case .adopted:
                if !held.isEmpty, next == held { return .accept }
                return .ignore
            }
        }

        /// The user is dragging the scroller. Later writes, including the art, are kept.
        public mutating func noteUserScrolled() {
            switch phase {
            case .armed, .adopted:
                phase = .userScrolled
            case .idle, .released, .userScrolled:
                break
            }
        }
    }

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
