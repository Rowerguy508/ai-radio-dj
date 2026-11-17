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
        guard isBookPose(containerWidth: containerWidth, containerHeight: containerHeight,
                         hinge: hinge) else { return unchanged }
        guard let fold = bookFold(in: divisions, containerWidth: containerWidth,
                                  containerHeight: containerHeight) else { return unchanged }
        return Decision(isBookPose: true, metrics: bookMetrics(
            containerWidth: containerWidth, containerHeight: containerHeight,
            fold: fold, artMin: artMin, artMax: artMax))
    }

    /// Narrowest side of the fold (after the `duoEdgeInset`s) that takes the collapsed-rail
    /// column. Under it, `bookColumn` is nil and the column stays centred as before (#548).
    public static let bookColumnMinSideWidth: Double = 260

    /// The single centred column the Duo shows once its rail is collapsed (#479), in book pose.
    /// `minX` and `width` are container points; `artSide` is clamped to the column.
    public struct BookColumn: Equatable, Sendable {
        public var minX: Double
        public var width: Double
        public var artSide: Double

        public init(minX: Double, width: Double, artSide: Double) {
            self.minX = minX
            self.width = width
            self.artSide = artSide
        }

        public var maxX: Double { minX + width }
    }

    /// #507: with the rail collapsed, the wide Duo draws one centred column (art, transport,
    /// scrubber, toolbar). Centred on a 640 pt display it spans the crease. In book pose the
    /// whole column moves to one side of the fold: the leading side, unless the trailing side
    /// is wider. That side must be at least `bookColumnMinSideWidth`. It keeps its preferred width when that fits, otherwise it takes the side's
    /// width (`duoEdgeInset` from the edge, flush with the fold), and stays centred in the side.
    ///
    /// Nil when the chosen side is narrower than `bookColumnMinSideWidth`, and whenever `resolve` is not book pose (no fold, flat or closed hinge, laptop pose,
    /// a phone or the iPhone-landscape centred column): the caller keeps today's centred column.
    public static func bookColumn(containerWidth: Double, containerHeight: Double,
                                  hinge: HingeSample?, divisions: [Division],
                                  column: Double, artSide: Double) -> BookColumn? {
        guard column.isFinite, artSide.isFinite, column > 0 else { return nil }
        guard isBookPose(containerWidth: containerWidth, containerHeight: containerHeight, hinge: hinge),
              let fold = bookFold(in: divisions, containerWidth: containerWidth,
                                  containerHeight: containerHeight) else { return nil }
        let edge = FoldedColumnLayout.duoEdgeInset
        let innerEnd = max(edge, containerWidth - edge)
        let foldMin = min(max(fold.minX, edge), innerEnd)
        let foldMax = min(max(fold.maxX, foldMin), innerEnd)
        let leading = (start: edge, width: foldMin - edge)
        let trailing = (start: foldMax, width: innerEnd - foldMax)
        let side = trailing.width > leading.width ? trailing : leading
        guard side.width >= bookColumnMinSideWidth else { return nil }
        let width = min(column, side.width)
        return BookColumn(minX: side.start + (side.width - width) / 2, width: width,
                          artSide: max(0, min(artSide, width)))
    }

    /// The gates `resolve` applies before it looks for a fold.
    private static func isBookPose(containerWidth: Double, containerHeight: Double, hinge: HingeSample?) -> Bool {
        guard containerWidth.isFinite, containerHeight.isFinite,
              containerWidth > 0, containerHeight > 0 else { return false }
        guard FoldedColumnLayout.controlPlacement(containerWidth: containerWidth,
                                                  containerHeight: containerHeight) == .duoHorizontal else {
            return false
        }
        if let hinge {
            switch hinge.status {
            case .closed, .fullyOpen:
                return false
            case .partiallyOpen, .unknown:
                return true
            }
        }
        return true
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
