import Foundation

/// Two panes for the regular-width listen player (#465 item 4).
///
/// The primary pane is the artwork and the controls. The secondary pane is the
/// up-next timeline. Compact width, a phone-sized container, and a short wide
/// container stay `.unchanged`, so the existing player is left as it is.
///
/// At an accessibility text size the two regions stay in one scrolling column.
/// The frames are the container's points. Nothing here reads playback, the DJ
/// session, or a device model.
///
/// `ArrangementView` (iOS 27.1) is the system container for `.split` when that
/// SDK is present. These frames are what the player draws on the SDK this tree
/// builds with, and what Linux checks.
public enum ArrangementPaneLayout {
    /// Every control the panes place is at least this tall and this wide.
    public static let hitTarget: Double = StudioLayoutMetrics.touchTargetMin
    public static let edgeInset: Double = 16
    public static let gutter: Double = 16
    /// Share of the split axis given to the artwork and controls, before rounding.
    /// The timeline keeps the rest, which stays at least a 44 pt target on the Duo sizes.
    public static let primaryShare: Double = 0.70

    public enum Axis: String, Equatable, Sendable {
        case horizontal
        case vertical
    }

    public struct Frame: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    /// Both regions, in container points. `primary` is artwork and controls.
    /// `secondary` is the up-next timeline.
    public struct Metrics: Equatable, Sendable {
        public var axis: Axis
        public var primary: Frame
        public var secondary: Frame
        public var edgeInset: Double
        public var gutter: Double

        public init(axis: Axis, primary: Frame, secondary: Frame, edgeInset: Double, gutter: Double) {
            self.axis = axis
            self.primary = primary
            self.secondary = secondary
            self.edgeInset = edgeInset
            self.gutter = gutter
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Keep the player that is already on screen.
        case unchanged
        /// Artwork and controls in one pane, the timeline in the other.
        case split(Metrics)
        /// The same two regions, stacked in one column. Accessibility text sizes.
        case singleColumn(Metrics)
    }

    /// `hasRegularWidth` is `horizontalSizeClass == .regular`. A compact or missing
    /// size class is `.unchanged` at every size. A regular container that is not the
    /// tall listen layout (`FoldedColumnLayout.duoHorizontal`) is also `.unchanged`,
    /// which is the phone portrait and the short landscape column.
    public static func resolve(hasRegularWidth: Bool, containerWidth: Double, containerHeight: Double,
                               accessibilityTextSize: Bool) -> Decision {
        guard hasRegularWidth,
              containerWidth.isFinite, containerHeight.isFinite,
              containerWidth > 0, containerHeight > 0 else { return .unchanged }
        guard FoldedColumnLayout.controlPlacement(containerWidth: containerWidth,
                                                  containerHeight: containerHeight) == .duoHorizontal else {
            return .unchanged
        }
        let metrics = frames(containerWidth: containerWidth, containerHeight: containerHeight)
        guard metrics.primary.width >= hitTarget, metrics.primary.height >= hitTarget,
              metrics.secondary.width >= hitTarget, metrics.secondary.height >= hitTarget else {
            return .unchanged
        }
        if accessibilityTextSize {
            return .singleColumn(metrics)
        }
        return .split(metrics)
    }

    /// The On Air string the panes may draw, or nil. The only input is
    /// `DJStudioState.onAirLabel`. An empty string draws nothing.
    public static func liveMark(onAirLabel: String?) -> String? {
        guard let onAirLabel, onAirLabel.contains(where: { !$0.isWhitespace }) else { return nil }
        return onAirLabel
    }

    // MARK: - Frames

    /// Wider than tall splits left and right. Otherwise the artwork and controls
    /// are above the timeline. Accessibility uses the same frames; the view puts
    /// them in one scroll view instead of two panes.
    private static func frames(containerWidth: Double, containerHeight: Double) -> Metrics {
        let edge = edgeInset
        let gap = gutter
        let innerWidth = containerWidth - edge * 2
        let innerHeight = containerHeight - edge * 2
        if containerWidth > containerHeight {
            let available = innerWidth - gap
            let primaryWidth = (available * primaryShare).rounded(.down)
            let secondaryWidth = available - primaryWidth
            return Metrics(
                axis: .horizontal,
                primary: Frame(x: edge, y: edge, width: primaryWidth, height: innerHeight),
                secondary: Frame(x: edge + primaryWidth + gap, y: edge,
                                 width: secondaryWidth, height: innerHeight),
                edgeInset: edge, gutter: gap)
        }
        let available = innerHeight - gap
        let primaryHeight = (available * primaryShare).rounded(.down)
        let secondaryHeight = available - primaryHeight
        return Metrics(
            axis: .vertical,
            primary: Frame(x: edge, y: edge, width: innerWidth, height: primaryHeight),
            secondary: Frame(x: edge, y: edge + primaryHeight + gap,
                             width: innerWidth, height: secondaryHeight),
            edgeInset: edge, gutter: gap)
    }
}
