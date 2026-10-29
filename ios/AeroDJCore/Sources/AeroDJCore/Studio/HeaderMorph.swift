import Foundation

/// Pure interpolation for the morphing large-title header (Stations screen). The header's
/// state is a function of how far the list has scrolled, so the SwiftUI view only measures
/// the offset and applies these values. Unit tested on Linux.
///
/// `progress` runs 0 (expanded: large title and subtitle) to 1 (collapsed: compact inline bar).
public struct HeaderMorph: Equatable, Sendable {
    /// 0 = expanded, 1 = collapsed.
    public var progress: Double
    /// Large title and subtitle.
    public var largeOpacity: Double
    /// Large title scale, anchored on its leading edge.
    public var largeScale: Double
    /// Compact inline bar in the navigation bar.
    public var inlineOpacity: Double
    /// The inline bar rises into place by this many points as it appears.
    public var inlineYOffset: Double

    public init(progress: Double, largeOpacity: Double, largeScale: Double,
                inlineOpacity: Double, inlineYOffset: Double) {
        self.progress = progress
        self.largeOpacity = largeOpacity
        self.largeScale = largeScale
        self.inlineOpacity = inlineOpacity
        self.inlineYOffset = inlineYOffset
    }

    /// Smallest large-title scale, at full collapse.
    public static let collapsedScale: Double = 0.82
    /// The inline bar starts to appear here, after the large title has mostly faded.
    public static let inlineStart: Double = 0.55
    /// The inline bar rises from this offset.
    public static let inlineRise: Double = 6
    /// Reduce Motion: one crossfade at this progress instead of a continuous morph.
    public static let crossfadeAt: Double = 0.5

    public static let expanded = HeaderMorph(progress: 0, largeOpacity: 1, largeScale: 1,
                                             inlineOpacity: 0, inlineYOffset: inlineRise)

    /// 0…1 from the scrolled distance (positive = content moved up) and the distance over
    /// which the header collapses (its own height). Overscroll and bad input clamp.
    public static func progress(scrolled: Double, collapseDistance: Double) -> Double {
        guard scrolled.isFinite, collapseDistance.isFinite, collapseDistance > 0 else { return 0 }
        return min(1, max(0, scrolled / collapseDistance))
    }

    /// The header at `progress`. Reduce Motion gives a plain crossfade: no scale and no rise,
    /// and each title is either shown or hidden (the view animates that change as a fade).
    public static func at(progress raw: Double, reduceMotion: Bool) -> HeaderMorph {
        let p = raw.isFinite ? min(1, max(0, raw)) : 0
        if reduceMotion {
            let collapsed = p >= crossfadeAt
            return HeaderMorph(progress: p, largeOpacity: collapsed ? 0 : 1, largeScale: 1,
                               inlineOpacity: collapsed ? 1 : 0, inlineYOffset: 0)
        }
        // The large title is gone a little before full collapse, so the two never overlap.
        let largeOpacity = max(0, 1 - p / 0.8)
        let inline = smoothstep(min(1, max(0, (p - inlineStart) / (1 - inlineStart))))
        return HeaderMorph(progress: p,
                           largeOpacity: largeOpacity,
                           largeScale: 1 - p * (1 - collapsedScale),
                           inlineOpacity: inline,
                           inlineYOffset: (1 - inline) * inlineRise)
    }

    private static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}
