import Foundation

/// The listen player (`FoldedPlayer`) in a container wider than any phone held upright: the
/// unfolded Duo's split view (sidebar + detail) or any compact-mode container below the
/// Studio switch. Owner feedback on build 25 (d955152): at that width the player spread to
/// both edges, the title sat left under centred art, and the controls pinned to the bottom
/// left a large gap under the DJ status chip. In a wide container everything is drawn in
/// one centred column instead, with the art width as the column width.
///
/// Pure and UI-free so it is unit tested on Linux. Points of the container, never the device.
/// Below `wideMinWidth` nothing changes: the iPhone portrait layout stays as it is.
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
}
