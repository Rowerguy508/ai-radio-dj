import Foundation

/// The listen player (`FoldedPlayer`) in a container wider than any phone held upright: the
/// unfolded Duo's split view, or any compact-mode container below the Studio switch.
/// `isWide` (at least `wideMinWidth`) is the old centred column, including iPhone landscape.
/// Build 44 (#460) is horizontal only when that width is also at least `duoMinHeight`
/// (the unfolded Duo). Below `wideMinWidth` nothing changes.
///
/// Pure and UI-free so it is unit tested on Linux. Points of the container, never the device.
public enum FoldedColumnLayout {
    /// Wider than every iPhone in portrait (440 pt today) with room to spare, and still
    /// below `StudioLayoutMetrics.studioMinWidth`, where the Studio can take over.
    public static let wideMinWidth: Double = 500
    /// Readable column cap. The art is capped lower (420), so the art usually decides.
    public static let columnMaxWidth: Double = 560
    /// The column never gets narrower than this, so the station chip, Queue and Tune fit.
    public static let columnMinWidth: Double = 360
    /// Outer margin either side of the column.
    public static let edgeInset: Double = 32
    /// Height of the in-column header row that carries ⋯ (44 pt touch target).
    public static let headerHeight: Double = 44

    /// Spacing tokens on the 8 pt grid, top to bottom.
    public enum Spacing {
        public static let headerToArt: Double = 8
        public static let artToTitle: Double = 24
        public static let titleToStatus: Double = 12
        public static let statusToControls: Double = 24
        public static let betweenControls: Double = 16
        public static let transportToToolbar: Double = 24
    }

    public static func isWide(containerWidth: Double) -> Bool {
        containerWidth.isFinite && containerWidth >= wideMinWidth
    }

    /// The art side and the column width for a wide container. The art fits the width (less
    /// the margins and the column cap) and the height (less what the column needs below it);
    /// the column is the art width, never below `columnMinWidth` or wider than the container.
    public static func metrics(containerWidth: Double, containerHeight: Double,
                               reserveBelowArt: Double,
                               artMin: Double, artMax: Double) -> (artSide: Double, column: Double) {
        let available = max(0, containerWidth - edgeInset * 2)
        let byWidth = min(available, columnMaxWidth)
        let byHeight = containerHeight - reserveBelowArt - headerHeight - Spacing.headerToArt
        let art = max(artMin, min(byWidth, byHeight, artMax))
        let column = min(available, max(columnMinWidth, min(art, columnMaxWidth)))
        return (min(art, column), column)
    }

    /// Shortest container that gets the horizontal Duo split.
    ///
    /// The split uses the full width, so controls sit at both edges. A wide compact
    /// container that is not this tall is not the Duo detail: iPhone landscape is at
    /// most 430 pt tall, and the compact-to-regular probe is 680 pt (`studioMinWidth` − 64
    /// by 680). On a phone window that container is wider than the screen, and a control
    /// at its left edge is off-screen. Those sizes keep the centred column, whose controls
    /// sit in the middle and stay hittable. The threshold is `studioMinWidth` (716): above
    /// the probe and every landscape phone, and below the Duo detail (640 × 820). No
    /// device model is consulted.
    public static var duoMinHeight: Double { StudioLayoutMetrics.studioMinWidth }

    /// Where the transport lives.
    /// - Phone portrait, and anything under `wideMinWidth`: controls pinned at the bottom.
    /// - Wide but shorter than `duoMinHeight` (iPhone landscape, and the compact resize probe): the previous centred column.
    /// - Wide and at least `duoMinHeight` (unfolded Duo): the horizontal right side.
    public enum ControlPlacement: Equatable, Sendable {
        case phoneBottom
        case centredColumn
        case duoHorizontal
    }

    /// Full-width Duo layout (#460). The fold is an empty gutter on the centre line.
    /// Artwork stays entirely in the left half. The right half is a content column plus
    /// a thin symbol bar. `topClearance` is empty under the status cluster and Live Activity.
    public struct DuoHorizontal: Equatable, Sendable {
        public let edgeInset: Double
        public let leftWidth: Double
        public let foldGutter: Double
        public let contentWidth: Double
        public let barWidth: Double
        public let topClearance: Double
        public let artSide: Double

        public init(edgeInset: Double, leftWidth: Double, foldGutter: Double, contentWidth: Double,
                    barWidth: Double, topClearance: Double, artSide: Double) {
            self.edgeInset = edgeInset
            self.leftWidth = leftWidth
            self.foldGutter = foldGutter
            self.contentWidth = contentWidth
            self.barWidth = barWidth
            self.topClearance = topClearance
            self.artSide = artSide
        }

        /// The content column begins strictly to the right of the centre fold.
        public var contentMinX: Double { edgeInset + leftWidth + foldGutter }
        /// The rail is the trailing edge of the content column.
        public var barMinX: Double { contentMinX + contentWidth }
    }

    /// Symbol-only bar. Wide enough for a 44 pt target, not for a scrubber or a title.
    public static let duoBarWidth: Double = 56
    /// Empty band on the centre line. No control is placed in it.
    public static let duoFoldGutter: Double = 28
    public static let duoEdgeInset: Double = 16
    /// Clear of the status cluster and Live Activity before the first control.
    public static let duoStatusClearance: Double = 56

    public static func controlPlacement(containerWidth: Double, containerHeight: Double) -> ControlPlacement {
        guard isWide(containerWidth: containerWidth) else { return .phoneBottom }
        guard containerHeight.isFinite, containerHeight >= duoMinHeight else { return .centredColumn }
        return .duoHorizontal
    }

    /// Horizontal Duo metrics. Phone widths do not call this.
    ///
    /// At 640 × 820 the content column is 234 pt: `640 − edge − bar − (mid + gutter / 2)`,
    /// which is `640 − 16 − 56 − 334`. The Search Apple Music control measured 203.7 × 34.3,
    /// so it fits that column. Its screen origin of x = −115 on the 652 × 680 probe was the
    /// player centred in the 390 pt iPhone 16e window with the button on the 16 pt leading
    /// inset: `(390 − 652) / 2 + 16 = −115`. It was not a content-column overflow.
    public static func duoHorizontal(containerWidth: Double, containerHeight: Double,
                                    artMin: Double, artMax: Double) -> DuoHorizontal {
        let mid = containerWidth / 2
        let left = max(0, mid - duoFoldGutter / 2 - duoEdgeInset)
        let content = max(0, containerWidth - duoEdgeInset - duoBarWidth - (mid + duoFoldGutter / 2))
        let art = min(left, artMax, max(artMin, containerHeight * 0.42))
        return DuoHorizontal(edgeInset: duoEdgeInset, leftWidth: left, foldGutter: duoFoldGutter,
                             contentWidth: content, barWidth: duoBarWidth,
                             topClearance: duoStatusClearance, artSide: art)
    }
}

/// Where the unfolded rail's More menu sits. The box is the safe-area size: the menu
/// stays inward of the rail, inside that box, on the wide Duo and on the narrow split.
public struct DuoMoreMenuLayout: Equatable, Sendable {
    public var width: Double
    public var maxHeight: Double
    /// From the trailing edge of the safe box to the menu's trailing edge.
    public var trailingGap: Double
    public var topGap: Double

    public init(width: Double, maxHeight: Double, trailingGap: Double, topGap: Double) {
        self.width = width
        self.maxHeight = maxHeight
        self.trailingGap = trailingGap
        self.topGap = topGap
    }

    public static func resolve(safeWidth: Double, safeHeight: Double) -> DuoMoreMenuLayout {
        let column = FoldedColumnLayout.duoHorizontal(containerWidth: max(0, safeWidth),
                                                      containerHeight: max(safeHeight, 1),
                                                      artMin: 140, artMax: 420)
        let trailingGap = min(max(0, safeWidth - 44), column.edgeInset + column.barWidth + 8)
        let available = max(44, safeWidth - trailingGap)
        let width = min(220, available, max(44, column.contentWidth - 8))
        let topGap = min(column.topClearance, max(0, safeHeight - 44))
        let maxHeight = max(44, safeHeight - topGap - 8)
        return DuoMoreMenuLayout(width: width, maxHeight: maxHeight, trailingGap: trailingGap, topGap: topGap)
    }

    /// The menu's frame inside `safe`. It never crosses `safe`.
    public func rect(in safe: CGRect) -> CGRect {
        let height = min(maxHeight, max(44, safe.height - topGap - 8))
        let x = safe.maxX - trailingGap - width
        return CGRect(x: x, y: safe.minY + topGap, width: width, height: height)
    }
}

/// Presentational Duo rules (#460). They read flags the UI already has. They do not
/// touch playback or the DJ session.
public enum DuoPresentation {
    /// The orb shows in the right column only while the player has confirmed the DJ is speaking.
    public static func showsVisualizer(isOnAir: Bool) -> Bool { isOnAir }

    /// The thin bar's On Air mark uses the same label as the rest of the app, or nothing.
    public static func onAirBadge(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        return label
    }

    /// The unfolded rail's live dot. Lit only while `onAirLabel` is present, which
    /// `DJStudioState` sets only for `.speaking`. Idle, preparing, ready and failed stay off.
    public static func railLiveDotLit(_ state: DJStudioState) -> Bool {
        state.onAirLabel != nil
    }

    /// The day-part wash never moves, so Reduce Motion has nothing to stop.
    public static let washAnimates = false

    /// Content-layer tint only. Reduce Transparency drops it rather than frosting the art.
    public static func washOpacity(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 0 : 0.16
    }
}

/// Choices for the unfolded rail's sleep timer. The rail calls the existing pause
/// action when one elapses. This does not start, skip or seek.
public enum DuoSleepTimer {
    public static let minuteChoices = [15, 30, 45, 60]

    public static func accessibilityValue(minutes: Int?) -> String {
        guard let minutes else { return "Off" }
        return "\(minutes) minutes"
    }
}


/// The unfolded Duo's right rail (#465). Play/pause and skip sit on the rail, not in the
/// content column's transport row. Phone portrait and the centred column are unchanged.
///
/// Layout only: sizes and the control order. The views live in `DuoVerticalRail`.
public enum DuoRailLayout {
    /// App-owned hit target, the same 44 pt plate as the other rail controls.
    public static let controlSize: Double = 44
    /// Spacing between rail items (`VStack` spacing in `DuoVerticalRail`).
    public static let spacing: Double = 10
    /// Vertical padding inside the rail's glass column.
    public static let verticalPadding: Double = 6
    /// Flexible gap that holds the live dot at the bottom of the rail.
    public static let spacerMinLength: Double = 8
    /// The rail's frame starts below the status cluster, same as `duoStatusClearance`.
    public static var frameTopClearance: Double { FoldedColumnLayout.duoStatusClearance }
    /// Bottom inset of the custom rail inside the container.
    public static let frameBottomPadding: Double = 8

    /// Rail slots, top to bottom. `playPause` and `skip` are omitted when there is no track.
    public enum Slot: String, Equatable, Sendable {
        case collapse
        case more
        case playPause
        case skip
        case queue
        case sleepTimer
        case liveDot
    }

    /// Collapse and More stay at the top, then play/pause and skip, then queue and the
    /// sleep timer, with the live dot at the bottom. Chrome and transport stay grouped.
    public static func slots(showsTransport: Bool) -> [Slot] {
        if showsTransport {
            return [.collapse, .more, .playPause, .skip, .queue, .sleepTimer, .liveDot]
        }
        return [.collapse, .more, .queue, .sleepTimer, .liveDot]
    }

    /// Height of the rail's stacked content, including inner padding and the bottom spacer.
    public static func stackHeight(showsTransport: Bool) -> Double {
        let slots = slots(showsTransport: showsTransport)
        let items = Double(slots.count + 1) // spacer before the live dot
        return Double(slots.count) * controlSize
            + spacing * (items - 1)
            + spacerMinLength
            + verticalPadding * 2
    }

    /// Inner height left for that stack in a container of `containerHeight`.
    public static func availableStackHeight(containerHeight: Double) -> Double {
        max(0, containerHeight - frameTopClearance - frameBottomPadding)
    }

    /// True when every rail control fits without clipping or dropping a control.
    public static func fits(containerHeight: Double, showsTransport: Bool) -> Bool {
        guard containerHeight.isFinite, containerHeight > 0 else { return false }
        return availableStackHeight(containerHeight: containerHeight) >= stackHeight(showsTransport: showsTransport)
    }
}
