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

    /// The card's transform at `phase`. Out-of-range or non-finite phases clamp to the edge.
    /// Reduce Motion lays the row flat: no scale, tilt or drop, only the opacity step.
    public static func at(phase: Double, reduceMotion: Bool) -> StationCarouselArc {
        let p = phase.isFinite ? min(1, max(-1, phase)) : 0
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
