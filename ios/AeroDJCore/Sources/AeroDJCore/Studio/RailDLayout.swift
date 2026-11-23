import Foundation

/// Mockup D (owner: "Yes, build it", relayed by Orion): one full-height 56 pt glass rail on
/// the trailing edge of every listen player that draws a rail. Top to bottom: (Collapse on the
/// open Duo), ⋯, Play/Pause, Skip, Queue, Sleep timer, the vertical song-position bar with
/// the elapsed time above it and the remaining time below it, and the live dot. The
/// horizontal scrubber is gone from those screens.
///
/// The iPhone and the closed Duo share `FoldedPlayer.foldedOuterBody`
/// (`FoldedOuterLayout.usesOuterReskin`), so they get the same rail. The open Duo keeps its
/// two halves, the sidebar-open rail column (Build 51, -Atlas) and the collapsed pinned
/// column; only the rail and the column contents are restyled.
///
/// Pure and UI-free so Linux can test the numbers. -Nova
public enum RailDLayout {
    // MARK: Rail

    /// Same column as `FoldedOuterLayout.closedRailWidth` and `FoldedColumnLayout.duoBarWidth`.
    public static let railWidth: Double = 56
    /// Gap between the rail and the trailing edge of the container (closed screen and rail column).
    public static let trailingInset: Double = 8
    /// Gap above and below the rail on the closed screen (level with the header's Back).
    public static let closedVerticalInset: Double = 8
    /// Continuous corner radius of the rail glass (spec B / D: 28).
    public static let railCornerRadius: Double = 28
    /// One plate. Every rail control is at least this in both directions.
    public static var controlSize: Double { DuoRailLayout.controlSize }
    public static var spacing: Double { DuoRailLayout.spacing }
    public static var capPadding: Double { DuoRailLayout.verticalPadding }

    /// What the rail draws, top to bottom.
    public enum Slot: String, Equatable, Sendable {
        case collapse
        case more
        case playPause
        case skip
        case queue
        case sleepTimer
        case scrubber
        case liveDot
    }

    /// `hasCollapse`: the open Duo's rail (the chevron stays). `showsTransport`: Play/Pause and
    /// Skip (a track). `showsScrubber`: a track with a known duration; otherwise a spacer
    /// holds the live dot at the bottom, as before.
    public static func slots(hasCollapse: Bool, showsTransport: Bool, showsScrubber: Bool) -> [Slot] {
        var slots: [Slot] = hasCollapse ? [.collapse, .more] : [.more]
        if showsTransport { slots += [.playPause, .skip] }
        slots += [.queue, .sleepTimer]
        if showsScrubber { slots.append(.scrubber) }
        slots.append(.liveDot)
        return slots
    }

    // MARK: Vertical scrubber

    /// 11 pt tabular times, inside the 56 pt column.
    public static let timeLabelPointSize: Double = 11
    public static let timeLabelHeight: Double = 14
    /// Between a time label and the track.
    public static let timeGap: Double = 4
    /// Width of the scrubber element (the labels and the track): wider than the 44 pt thumb
    /// target and inside the 56 pt rail.
    public static let scrubberWidth: Double = 52
    public static let trackWidth: Double = 4
    public static let trackWidthDragging: Double = 8
    public static let thumbVisible: Double = 12
    public static let thumbVisibleDragging: Double = 20
    /// The thumb's hit target. The whole bar is the drag target, so this is a floor.
    public static let thumbHitSide: Double = 44
    /// The track never gets shorter than one thumb target.
    public static var minTrackLength: Double { thumbHitSide }
    /// A drag is claimed only after this much movement, mostly vertical (edge gestures).
    public static let dragClaimDistance: Double = 10

    /// Height of everything in the scrubber element other than the track.
    public static var scrubberChrome: Double { 2 * (timeLabelHeight + timeGap) }

    /// Height of the rail's stack with the track at zero length: plates, gaps, the scrubber's
    /// labels and the cap padding. A spacer (no scrubber) counts as its minimum.
    public static func fixedHeight(_ slots: [Slot]) -> Double {
        let plates = Double(slots.filter { $0 != .scrubber }.count) * controlSize
        let gaps = Double(max(0, slots.count - 1)) * spacing
        let scrubber = slots.contains(.scrubber) ? scrubberChrome : DuoRailLayout.spacerMinLength + spacing
        return plates + gaps + scrubber + capPadding * 2
    }

    /// Track length left inside a rail glass of `railHeight`.
    public static func trackLength(railHeight: Double, slots: [Slot]) -> Double {
        guard railHeight.isFinite, railHeight > 0, slots.contains(.scrubber) else { return 0 }
        return max(0, railHeight - fixedHeight(slots))
    }

    /// True when every plate and a track of at least `minTrackLength` fit. The rail never
    /// shrinks a plate below 44 pt; a shorter window scrolls nothing and keeps the track at
    /// its 44 pt floor (the glass then overflows its frame, which no shipped size does).
    public static func fits(railHeight: Double, slots: [Slot]) -> Bool {
        guard railHeight.isFinite, railHeight > 0 else { return false }
        if slots.contains(.scrubber) { return trackLength(railHeight: railHeight, slots: slots) >= minTrackLength }
        return railHeight >= fixedHeight(slots)
    }

    /// The song position at `y` in the scrubber element (labels included). The fill runs top to
    /// bottom: 0:00 at the top of the track, the end at the bottom. Drag down seeks forward.
    public static func position(atElementY y: Double, elementHeight: Double, duration: TimeInterval) -> TimeInterval {
        let length = max(0, elementHeight - scrubberChrome)
        let onTrack = y - (timeLabelHeight + timeGap)
        return ScrubberState.position(atX: onTrack, width: length, duration: duration)
    }

    /// Thumb centre from the top of the track.
    public static func thumbOffset(fraction: Double, trackLength: Double) -> Double {
        guard fraction.isFinite, trackLength.isFinite, trackLength > 0 else { return 0 }
        return min(max(0, fraction), 1) * trackLength
    }

    /// Claims a drag once it has moved `dragClaimDistance` and more vertically than
    /// horizontally, so a sideways swipe or a short touch on the edge rail is left alone.
    public static func claimsDrag(translationX: Double, translationY: Double) -> Bool {
        guard translationX.isFinite, translationY.isFinite else { return false }
        return abs(translationY) >= dragClaimDistance && abs(translationY) > abs(translationX)
    }

    // MARK: Closed screen (iPhone and closed Duo)

    /// D's bigger title and artist: the horizontal scrubber's row went to the type.
    public static let closedTitlePointSize: Double = 40
    public static let closedArtistPointSize: Double = 17
    /// The horizontal scrubber's block under the content column (4 pt track, the 15 pt time
    /// row, its 4 pt gap and the 16 pt bottom inset, rounded to the 8 pt grid).
    public static let removedScrubberBlock: Double = 40
    /// What the bigger title and artist take back from the art.
    public static var titleGrowth: Double {
        (closedTitlePointSize - FoldedOuterLayout.titlePointSize)
            + (closedArtistPointSize - FoldedOuterLayout.artistPointSize)
    }
    /// Height kept under the art with D: #537's reserve beside the rail (the 80 pt transport
    /// row already gone), less the scrubber block, plus the bigger type. 254 - 40 + 8.
    public static var closedArtReserveBelow: Double {
        FoldedOuterLayout.artReserveBelowWithRail - removedScrubberBlock + titleGrowth
    }

    /// Art side on the closed screen: the column beside the rail less its gutters, capped by
    /// the height less `closedArtReserveBelow`, clamped to `minSide...maxSide` (min wins).
    public static func closedArtSide(containerWidth: Double, containerHeight: Double,
                                     minSide: Double, maxSide: Double) -> Double {
        let byWidth = FoldedOuterLayout.columnWidthBesideRail(containerWidth: containerWidth)
            - FoldedOuterLayout.artInsetBesideRail * 2
        let byHeight = containerHeight - closedArtReserveBelow
        return max(minSide, min(byWidth, byHeight, maxSide))
    }

    /// Rail glass height on the closed screen.
    public static func closedRailHeight(containerHeight: Double) -> Double {
        max(0, containerHeight - closedVerticalInset * 2)
    }

    // MARK: Open Duo

    /// Portrait, or landscape as the L1 book spread or the L2 centred layout.
    public enum OpenArrangement: String, Equatable, Sendable {
        /// Taller than wide: art, title and the DJ chip in the leading half.
        case portrait
        /// L1: art centred in the leading half; title, artist, DJ chip and Up next in the trailing
        /// half, left-aligned and vertically centred to the art. Nothing sits on the fold.
        case spread
        /// L2: art and title centred across the player area. Only when the Duo is known to be
        /// flat (fold inactive). The DJ chip and Up next stay in the trailing half.
        case centred
    }

    /// L2 only when the hinge reports fully open (flat) or the reported vertical division is
    /// inactive. An unknown hinge, a missing reading (this SDK) and a partly open hinge all get
    /// L1, which keeps everything off the centre line: a spread on a flat Duo looks fine, the
    /// centred art on a half-folded one would sit in the crease.
    public static func openArrangement(containerWidth: Double, containerHeight: Double,
                                       hinge: FoldAwareness.HingeSample?,
                                       divisions: [FoldAwareness.Division]) -> OpenArrangement {
        guard containerWidth.isFinite, containerHeight.isFinite, containerWidth > containerHeight else {
            return .portrait
        }
        if hinge?.status == .fullyOpen { return .centred }
        let vertical = divisions.filter { $0.isVertical && $0.height >= containerHeight * 0.5 }
        if !vertical.isEmpty, !vertical.contains(where: \.isActive) { return .centred }
        return .spread
    }

    /// The landscape spread's leading inset into the trailing half: the type starts this far
    /// after the fold (fold.maxX + 24, the mock's 448 pt at 820 × 640).
    public static let spreadTrailingInset: Double = 24
    /// Build 56 (951 × 669 CI shots, -Nova): the open Duo's L1 trailing page stops this far short
    /// of the rail glass, so Up next and the station chips (ending in Tune) no longer run into
    /// the rail's leading edge (≈ 2 pt in the shots). The Stations trailing page's gap to the
    /// same rail (`DuoStationsLayout.bookRailGutter`, 16), so both screens end their content at
    /// the same x.
    public static var openSpreadRailGutter: Double { DuoStationsLayout.bookRailGutter }
    /// Header row (station name) above the art in every open arrangement.
    public static let openHeaderHeight: Double = 52
    /// Vertical breathing room around the spread art.
    public static let spreadArtVerticalInset: Double = 24
    /// Gutter either side of the art inside the leading half.
    public static let spreadArtHorizontalInset: Double = 16

    /// L1 art: the leading half less its gutters, capped by the height less the header and
    /// the vertical insets, clamped to `minSide...maxSide` (min wins). 820 × 566 → 348.
    public static func spreadArtSide(leftWidth: Double, containerHeight: Double,
                                     minSide: Double, maxSide: Double) -> Double {
        let byWidth = leftWidth - spreadArtHorizontalInset * 2
        let byHeight = containerHeight - openHeaderHeight - spreadArtVerticalInset * 2
        return max(minSide, min(byWidth, byHeight, maxSide))
    }

    /// Height under the L2 art: the title block, the shifted DJ chip and Up next.
    public static let centredReserveBelowArt: Double = 216
    /// L2 art: the player area less its gutters, capped by the height less the header and
    /// what sits under the art.
    public static func centredArtSide(playerWidth: Double, containerHeight: Double,
                                      minSide: Double, maxSide: Double) -> Double {
        let byWidth = playerWidth - spreadArtHorizontalInset * 2
        let byHeight = containerHeight - openHeaderHeight - centredReserveBelowArt
        return max(minSide, min(byWidth, byHeight, maxSide))
    }

    /// The sidebar-open rail column (`FoldedColumnLayout.usesRailColumn`): leading inset,
    /// gutter before the rail, the rail and its 8 pt trailing inset. Tighter than build 51's
    /// 16 / 16 / 16 so a 290 pt portrait sidebar leaves the column the DJ chip needs.
    public static let railColumnLeadingInset: Double = 16
    public static let railColumnGutter: Double = 12
    /// `barWidth` is 0 when the system draws the rail (Atlas's #552 guard), as in
    /// `FoldedColumnLayout.railColumnMetrics`.
    public static func railColumnWidth(detailWidth: Double, barWidth: Double = railWidth) -> Double {
        guard detailWidth.isFinite, barWidth.isFinite else { return 0 }
        return max(0, detailWidth - railColumnLeadingInset - railColumnGutter - max(0, barWidth) - trailingInset)
    }

    /// The rail column's art: D's column with Atlas's reserve under the art
    /// (`FoldedColumnLayout.railColumnReserveBelowArt`, the accessibility one at AX sizes), the
    /// same clamp as `FoldedColumnLayout.railColumnMetrics`, never wider than the column. Only the
    /// column width differs from his metrics (D's 16 / 12 / 8 insets, 12 pt wider).
    public static func railColumnArtSide(column: Double, containerHeight: Double, accessibilityTextSize: Bool,
                                         artMin: Double, artMax: Double) -> Double {
        let reserve = accessibilityTextSize
            ? FoldedColumnLayout.railColumnReserveBelowArtAccessibility
            : FoldedColumnLayout.railColumnReserveBelowArt
        let art = max(artMin, min(column, containerHeight - reserve, artMax))
        return min(art, max(0, column))
    }

    /// The open title size: 34 pt in the two halves, 28 pt in the narrow rail column.
    public static let openTitlePointSize: Double = 34
    public static let railColumnTitlePointSize: Double = 28
    /// Below this column width the title steps down to `railColumnTitlePointSize`.
    public static let largeTitleMinColumn: Double = 280

    /// True when `[minX, maxX]` overlaps the fold band (open interval: touching is clear).
    public static func intersectsFold(minX: Double, maxX: Double, foldMinX: Double, foldMaxX: Double) -> Bool {
        minX < foldMaxX && maxX > foldMinX
    }
}
