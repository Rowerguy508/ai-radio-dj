import Foundation

/// Pure geometry for the Stations carousel (wireframe 01). A card's place on the arc is a
/// function of its scroll phase only: -1 is one card-width to the leading side, 0 is centred,
/// 1 is one card-width to the trailing side. The SwiftUI view feeds `ScrollTransitionPhase.value`
/// in and applies the result, so the shape of the arc is unit tested on Linux.
///
/// Presentation only: nothing here selects, opens or plays a station.
public struct StationCarouselArc: Equatable, Sendable {
    public var scale: Double
    public var rotationDegrees: Double
    /// Downward offset in points. The centred card sits highest, so the row reads as an arc.
    public var yOffset: Double
    public var opacity: Double

    public init(scale: Double, rotationDegrees: Double, yOffset: Double, opacity: Double) {
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.yOffset = yOffset
        self.opacity = opacity
    }

    public static let centred = StationCarouselArc(scale: 1, rotationDegrees: 0, yOffset: 0, opacity: 1)

    /// Smallest scale, at one card-width from centre.
    public static let edgeScale: Double = 0.86
    /// Tilt at one card-width from centre. Leading cards tilt counter-clockwise, trailing clockwise.
    public static let edgeRotationDegrees: Double = 9
    /// Drop at one card-width from centre. Quadratic in the phase, so the row bends like an arc.
    public static let edgeDrop: Double = 26
    /// Opacity at one card-width from centre. Side cards stay legible.
    public static let edgeOpacity: Double = 0.55

    /// On the open Duo, a phase this close to centre is the centred card, drawn untransformed.
    /// A snapped card's interactive phase can be a hair off zero, which left a near-identity
    /// scale and tilt on the card's glass: the system then resamples that offscreen glass layer
    /// and its two triangles can leave a hairline seam corner to corner (the diagonal line).
    /// 0.02 is about 6 pt of scroll at the Duo's 300 pt card plus 12 pt spacing.
    public static let centreSnapPhase: Double = 0.02

    /// The card's transform at `phase`. Out-of-range or non-finite phases clamp to the edge.
    /// Reduce Motion lays the row flat: no scale, tilt or drop, only the opacity step.
    /// `snapsCentre` (open Duo only) returns exactly `.centred` within `centreSnapPhase`;
    /// false is the curve every iPhone has always drawn.
    public static func at(phase: Double, reduceMotion: Bool, snapsCentre: Bool = false) -> StationCarouselArc {
        let p = phase.isFinite ? min(1, max(-1, phase)) : 0
        if snapsCentre, abs(p) < centreSnapPhase { return .centred }
        let d = abs(p)
        let opacity = 1 - d * (1 - edgeOpacity)
        if reduceMotion {
            return StationCarouselArc(scale: 1, rotationDegrees: 0, yOffset: 0, opacity: opacity)
        }
        return StationCarouselArc(scale: 1 - d * (1 - edgeScale),
                                  rotationDegrees: p * edgeRotationDegrees,
                                  yOffset: d * d * edgeDrop,
                                  opacity: opacity)
    }
}

/// Where the Stations carousel sits on the open Duo (build 51 report). Pure, Linux tested.
public enum StationCarouselLayout {
    /// Room above and below the card row inside the horizontal scroll view, so the dropped,
    /// tilted side cards are inside it. The same values the view has always padded by.
    public static let rowTopPadding: Double = 8
    public static var rowBottomPadding: Double { StationCarouselArc.edgeDrop + 16 }

    /// The open Duo, portrait (640 x 820) or turned sideways (820 x 640): the same rule as the
    /// player's `.duoHorizontal`. Never an iPhone in either orientation (phones are under
    /// `wideMinWidth` in portrait and at most 440 pt tall in landscape), never narrow Split View.
    /// The size is the column including its safe areas and bars.
    public static func isOpenDuo(containerWidth: Double, containerHeight: Double) -> Bool {
        guard containerWidth.isFinite, containerHeight.isFinite,
              containerWidth > 0, containerHeight > 0 else { return false }
        return FoldedColumnLayout.controlPlacement(containerWidth: containerWidth,
                                                   containerHeight: containerHeight) == .duoHorizontal
    }

    /// On the open Duo the card row is clipped to its own frame, which ends at the safe area,
    /// so no card draws or takes taps under the trailing toolbar (Settings, Shared Items, +).
    /// iPhone keeps `scrollClipDisabled` with no clip, exactly as before.
    public static func clipsRow(containerWidth: Double, containerHeight: Double) -> Bool {
        isOpenDuo(containerWidth: containerWidth, containerHeight: containerHeight)
    }

    /// Vertical extent of a card at `phase` in its slot's coordinates (slot top is 0), after
    /// the arc's scale and rotation about the centre and its drop. Used to prove that clipping
    /// the row never cuts a card's top or bottom.
    public static func cardVerticalExtent(cardWidth: Double, cardHeight: Double, phase: Double,
                                          snapsCentre: Bool) -> (minY: Double, maxY: Double) {
        let arc = StationCarouselArc.at(phase: phase, reduceMotion: false, snapsCentre: snapsCentre)
        let theta = abs(arc.rotationDegrees) * .pi / 180
        let half = arc.scale * (cardWidth / 2 * sin(theta) + cardHeight / 2 * cos(theta))
        let centre = cardHeight / 2 + arc.yOffset
        return (centre - half, centre + half)
    }
}
