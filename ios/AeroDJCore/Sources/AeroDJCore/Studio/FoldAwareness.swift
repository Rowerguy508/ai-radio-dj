import Foundation

/// Book pose for the unfolded Duo (#465 item 2).
///
/// Layout comes from an active vertical division (`reservedRegions(kind: .division)`).
/// The hinge sample (`onHingeChange`) says whether the device is closed, partly open,
/// or fully open. The angle is not a layout input: two angles with the same division
/// produce the same frames. A horizontal division is the laptop pose and is left to
/// that layout. A closed or fully open hinge, a phone-sized container, and a missing
/// division all keep `FoldedColumnLayout.duoHorizontal` unchanged.
///
/// The player stays on the leading side of the fold. The content column and the symbol
/// bar start after it. A column that cannot hold a 44 pt target is given no width, so a
/// fixed-size button is not placed in the crease. Pure and UI-free so Linux can test it.
public enum FoldAwareness {
    /// The statuses `DeviceHinge.Status` reports, plus `.unknown` for an unrecognised case.
    public enum HingeStatus: String, Equatable, Sendable {
        case closed
        case partiallyOpen
        case fullyOpen
        case unknown
    }

    /// One hinge callback. `angleDegrees` is stored for the caller and ignored by `resolve`.
    public struct HingeSample: Equatable, Sendable {
        public var status: HingeStatus
        public var angleDegrees: Double

        public init(status: HingeStatus, angleDegrees: Double) {
            self.status = status
            self.angleDegrees = angleDegrees
        }
    }

    /// One division region in the container's points. The frame already includes margins.
    public struct Division: Equatable, Sendable {
        public var minX: Double
        public var minY: Double
        public var width: Double
        public var height: Double
        public var isActive: Bool

        public init(minX: Double, minY: Double, width: Double, height: Double, isActive: Bool) {
            self.minX = minX
            self.minY = minY
            self.width = width
            self.height = height
            self.isActive = isActive
        }

        public var maxX: Double { minX + width }
        public var maxY: Double { minY + height }

        /// A book fold runs vertically. A band that is wider than it is tall is the laptop crease.
        public var isVertical: Bool { height > width }
    }

    public struct Decision: Equatable, Sendable {
        /// True when the columns were placed around a vertical division.
        public var isBookPose: Bool
        public var metrics: FoldedColumnLayout.DuoHorizontal

        public init(isBookPose: Bool, metrics: FoldedColumnLayout.DuoHorizontal) {
            self.isBookPose = isBookPose
            self.metrics = metrics
        }
    }

    /// `metrics` matches `FoldedColumnLayout.duoHorizontal` unless `isBookPose` is true.
    public static func resolve(containerWidth: Double, containerHeight: Double,
                               hinge: HingeSample?, divisions: [Division],
                               artMin: Double, artMax: Double) -> Decision {
        let ordinary = FoldedColumnLayout.duoHorizontal(
            containerWidth: containerWidth, containerHeight: containerHeight,
            artMin: artMin, artMax: artMax)
        let unchanged = Decision(isBookPose: false, metrics: ordinary)
        guard containerWidth.isFinite, containerHeight.isFinite,
              containerWidth > 0, containerHeight > 0 else { return unchanged }
        guard FoldedColumnLayout.controlPlacement(containerWidth: containerWidth,
                                                  containerHeight: containerHeight) == .duoHorizontal else {
            return unchanged
        }
        if let hinge {
            switch hinge.status {
            case .closed, .fullyOpen:
                return unchanged
            case .partiallyOpen, .unknown:
                break
            }
        }
        guard let fold = bookFold(in: divisions, containerWidth: containerWidth,
                                  containerHeight: containerHeight) else { return unchanged }
        return Decision(isBookPose: true, metrics: bookMetrics(
            containerWidth: containerWidth, containerHeight: containerHeight,
            fold: fold, artMin: artMin, artMax: artMax))
    }

    /// The active vertical division that actually splits this container. A short region
    /// does not, so a tall control is not treated as the hinge.
    private static func bookFold(in divisions: [Division], containerWidth: Double,
                                 containerHeight: Double) -> Division? {
        let span = containerHeight * 0.5
        return divisions
            .filter { division in
                division.isActive && division.isVertical
                    && division.width.isFinite && division.height.isFinite
                    && division.minX.isFinite && division.minY.isFinite
                    && division.width > 0 && division.height >= span
                    && division.maxX > FoldedColumnLayout.duoEdgeInset
                    && division.minX < containerWidth - FoldedColumnLayout.duoEdgeInset
                    && division.maxY > 0 && division.minY < containerHeight
            }
            .max { lhs, rhs in
                if lhs.height != rhs.height { return lhs.height < rhs.height }
                return lhs.width < rhs.width
            }
    }

    /// Columns in container points. The horizontal padding stays `duoEdgeInset`. Everything
    /// inside that padding is the player, the fold, or the controls, and those three do not overlap.
    private static func bookMetrics(containerWidth: Double, containerHeight: Double,
                                    fold: Division, artMin: Double, artMax: Double) -> FoldedColumnLayout.DuoHorizontal {
        let edge = FoldedColumnLayout.duoEdgeInset
        let innerStart = edge
        let innerEnd = max(innerStart, containerWidth - edge)
        let foldMin = min(max(fold.minX, 0), containerWidth)
        let foldMax = min(max(fold.maxX, foldMin), containerWidth)
        let minimum = StudioLayoutMetrics.touchTargetMin

        var left = max(0, min(foldMin, innerEnd) - innerStart)
        var gutter = max(0, min(foldMax, innerEnd) - max(foldMin, innerStart))
        let controlSpan = max(0, innerEnd - max(foldMax, innerStart))

        // A leading sliver narrower than a target cannot hold the rating button.
        if left < minimum {
            gutter += left
            left = 0
        }

        let preferredBar = FoldedColumnLayout.duoBarWidth
        let bar: Double
        let content: Double
        if controlSpan >= preferredBar + minimum {
            bar = preferredBar
            content = controlSpan - preferredBar
        } else if controlSpan >= preferredBar {
            bar = preferredBar
            content = 0
            gutter += controlSpan - preferredBar
        } else if controlSpan >= minimum {
            bar = controlSpan
            content = 0
        } else {
            bar = 0
            content = 0
            gutter += controlSpan
        }

        let art = min(left, artMax, max(artMin, containerHeight * 0.42))
        return FoldedColumnLayout.DuoHorizontal(
            edgeInset: edge, leftWidth: left, foldGutter: gutter,
            contentWidth: content, barWidth: bar,
            topClearance: FoldedColumnLayout.duoStatusClearance,
            artSide: max(0, art))
    }
}
