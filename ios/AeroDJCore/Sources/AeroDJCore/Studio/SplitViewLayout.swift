import Foundation

/// Side-by-side Split View (#465 item 6, #499). Now Playing, Library, Stations and
/// Settings share this decision. It takes the width class and the container, the same
/// inputs as the outer-to-inner layout, plus the leading and trailing safe areas.
/// Those two insets are independent: a split does not have matching sides.
///
/// A missing width class is passed as `hasRegularWidth: false`, so it stays compact.
/// A full-screen iPhone does not adapt: portrait insets match, and landscape is
/// shorter than `FoldedColumnLayout.duoMinHeight`. Equal insets keep `preferredBarEdge`,
/// which is the side that screen already uses.
///
/// Pure and UI-free so it is unit tested on Linux. Points of the container, never a device.
public enum SplitViewLayout {
    /// The four split widths. Bands are container points, not a device model.
    public enum Span: Equatable, Sendable {
        /// Under 420 pt: one-third and Slide Over, including the 340 pt sample.
        case compactNarrow
        /// 420 pt up to 620: the half sample is 540.
        case half
        /// 620 pt up to 900: the wide sample is 680. A regular window this wide is still
        /// under the Studio switch.
        case twoThirds
        /// 900 pt and wider, and the compact-class Duo detail (at least 600 × 716).
        case full

        public var name: String {
            switch self {
            case .compactNarrow: "compactNarrow"
            case .half: "half"
            case .twoThirds: "twoThirds"
            case .full: "full"
            }
        }
    }

    /// The outer edge. The larger safe-area inset is that side of the screen.
    public enum BarEdge: Equatable, Sendable {
        case leading
        case trailing

        public var name: String {
            switch self {
            case .leading: "leading"
            case .trailing: "trailing"
            }
        }
    }

    public static let touchTarget = StudioLayoutMetrics.touchTargetMin

    /// One split the UI test sizes the app to. `width` and `height` are the window,
    /// before the safe area is removed.
    public struct Sample: Equatable, Sendable {
        public let name: String
        public let width: Double
        public let height: Double
        public let leading: Double
        public let trailing: Double
        public let hasRegularWidth: Bool

        public init(name: String, width: Double, height: Double, leading: Double, trailing: Double,
                    hasRegularWidth: Bool) {
            self.name = name
            self.width = width
            self.height = height
            self.leading = leading
            self.trailing = trailing
            self.hasRegularWidth = hasRegularWidth
        }
    }

    /// Compact narrow, outer edge leading. Short enough to stay the phone column.
    public static let narrow = Sample(name: "narrow", width: 340, height: 760,
                                      leading: 28, trailing: 0, hasRegularWidth: false)
    /// Half, regular width class, outer edge leading. Wide enough for the Duo column.
    public static let half = Sample(name: "half", width: 540, height: 760,
                                    leading: 28, trailing: 0, hasRegularWidth: true)
    /// Two-thirds, outer edge trailing. Still under `studioMinWidth`.
    public static let wide = Sample(name: "wide", width: 680, height: 760,
                                    leading: 0, trailing: 28, hasRegularWidth: true)
    /// Full window, outer edge leading.
    public static let full = Sample(name: "full", width: 1024, height: 1366,
                                    leading: 20, trailing: 0, hasRegularWidth: true)

    public static let samples = [narrow, half, wide, full]

    public static func sample(named name: String) -> Sample? {
        samples.first { $0.name == name }
    }

    public struct Chrome: Equatable, Sendable {
        public var span: Span
        public var barEdge: BarEdge
        public var leading: Double
        public var trailing: Double
        /// False for a full-screen iPhone and for equal insets. Callers then keep
        /// the placement they already had.
        public var adapts: Bool
        /// Container width after each inset is removed on its own side.
        public var contentWidth: Double

        public init(span: Span, barEdge: BarEdge, leading: Double, trailing: Double,
                    adapts: Bool, contentWidth: Double) {
            self.span = span
            self.barEdge = barEdge
            self.leading = leading
            self.trailing = trailing
            self.adapts = adapts
            self.contentWidth = contentWidth
        }

        public var decisionText: String { "\(span.name) \(barEdge.name)" }

        public var leavesRoomForTouchTarget: Bool {
            contentWidth + 0.001 >= SplitViewLayout.touchTarget
        }
    }

    public struct SidePadding: Equatable, Sendable {
        public var leading: Double
        public var trailing: Double
        public var asymmetric: Bool

        public init(leading: Double, trailing: Double, asymmetric: Bool) {
            self.leading = leading
            self.trailing = trailing
            self.asymmetric = asymmetric
        }
    }

    public static func span(hasRegularWidth: Bool, containerWidth: Double, containerHeight: Double) -> Span {
        let width = finite(containerWidth)
        let height = finite(containerHeight)
        // The unfolded Duo detail is a compact-class window, 640 × 820. It is the full
        // inner display, not a two-thirds slice of a wider pad.
        if !hasRegularWidth, width >= 600, height >= FoldedColumnLayout.duoMinHeight {
            return .full
        }
        if width < 420 { return .compactNarrow }
        if width < 620 { return .half }
        if width < 900 { return .twoThirds }
        return .full
    }

    /// The outer edge is the side with the greater inset. A tie keeps `preferred`.
    public static func barEdge(leading: Double, trailing: Double, preferred: BarEdge) -> BarEdge {
        let lead = finite(leading)
        let trail = finite(trailing)
        if lead > trail + 0.5 { return .leading }
        if trail > lead + 0.5 { return .trailing }
        return preferred
    }

    public static func chrome(hasRegularWidth: Bool, containerWidth: Double, containerHeight: Double,
                              leadingInset: Double, trailingInset: Double,
                              preferredBarEdge: BarEdge) -> Chrome {
        let width = finite(containerWidth)
        let height = finite(containerHeight)
        let lead = finite(leadingInset)
        let trail = finite(trailingInset)
        let span = span(hasRegularWidth: hasRegularWidth, containerWidth: width, containerHeight: height)
        let asymmetric = abs(lead - trail) > 0.5
        // Landscape phones are shorter than the Duo and their insets already differ
        // (the sensor housing is on one side). That path stays the centred column.
        let landscapePhone = height < FoldedColumnLayout.duoMinHeight
        let adapts = asymmetric && !landscapePhone && width > 0 && height > 0
        let edge = adapts ? barEdge(leading: lead, trailing: trail, preferred: preferredBarEdge) : preferredBarEdge
        return Chrome(span: span, barEdge: edge, leading: lead, trailing: trail, adapts: adapts,
                      contentWidth: max(0, width - lead - trail))
    }

    /// Padding for one side each. `applied` is the inset SwiftUI has already used, so a
    /// view that is already inside the safe area does not add it again. A symmetric pair
    /// stays `designInset` on both sides. An asymmetric pair uses each side's own extra
    /// and does not copy the larger one across.
    public static func sidePadding(measuredLeading: Double, measuredTrailing: Double,
                                   appliedLeading: Double, appliedTrailing: Double,
                                   designInset: Double) -> SidePadding {
        let extraLead = max(0, finite(measuredLeading) - finite(appliedLeading))
        let extraTrail = max(0, finite(measuredTrailing) - finite(appliedTrailing))
        let design = finite(designInset)
        let lead = design + extraLead
        let trail = design + extraTrail
        return SidePadding(leading: lead, trailing: trail, asymmetric: abs(lead - trail) > 0.5)
    }

    private static func finite(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}
