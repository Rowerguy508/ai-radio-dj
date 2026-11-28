import Foundation

/// #465 01-folded: metrics and DJ-status rules for the Duo outer-screen compact reskin.
///
/// Pure and UI-free so Linux can test them. Ships ungated (owner, 9:53 PM, logged on
/// #300 and #491): the iPhone and the folded Duo draw this reskin whenever the folded
/// player is at phone width with a track showing. `FoldedStyle` and
/// `FoldedPlayer.compactBody` stay for every other phone-width state (nothing playing,
/// starting, failed). The mockup's outer size is 390 × 844 pt.
///
/// The tinted ring around play was deferred from item 9. These tokens do not depend
/// on `GlassTreatment` or the item 9 branch, which is not on integration yet.
public enum FoldedOuterLayout {
    /// Mockup content gutter (`left: 24`).
    public static let contentInset: Double = 24
    /// Art inset in the mockup (`left: 30`).
    public static let artInset: Double = 30
    /// Art corner radius in the 01-folded mockup.
    public static let artRadius: Double = 28
    public static let titlePointSize: Double = 34
    public static let artistPointSize: Double = 15
    /// The 80 pt horizontal transport capsule. Mockup D draws no transport row on this screen
    /// (Play/Pause and Skip moved to the rail in #537, the scrubber in D), so nothing draws
    /// it. It survives only as arithmetic: `artReserveBelowWithRail` subtracts it, and
    /// `RailDLayout.closedArtReserveBelow` builds on that, so changing it would still move the
    /// closed art. Kept at 80 so that math and the play-ring fit below are unchanged. -Nova
    public static let transportHeight: Double = 80
    public static let transportRadius: Double = 40
    /// Play/Pause disc. The mockup drew 64 pt; this uses the shipped 68 pt transport target
    /// (#484 LiquidGlassTransportTests) so the iPhone keeps the same Play/Pause size.
    public static let playSide: Double = 68
    /// Outset ring around play, deferred from item 9: a 6 pt teal halo.
    public static let playRingWidth: Double = 6
    public static let playRingOpacity: Double = 0.25
    /// sRGB 47, 212, 190 — the mockup's Morning Calm tint. Not yet hooked to the opened station.
    public static let playRingRed: Double = 47 / 255
    public static let playRingGreen: Double = 212 / 255
    public static let playRingBlue: Double = 190 / 255
    /// 52, the shipped Skip target (#484 LiquidGlassTransportTests), not the mockup's 44.
    public static let skipSide: Double = 52
    public static let statusPillHeight: Double = 28
    /// #537 (owner, build 49: "Too cluttered when closed"): the title and the artist are one
    /// line each, truncated at the tail. VoiceOver still reads both in full.
    public static let titleLineLimit = 1
    public static let artistLineLimit = 1

    /// Owner (Nov 27, 2026, relayed by Orion): "Fix the cut-off station and song names at large
    /// text first." At accessibility sizes in the closed Duo's status-column layout (a trailing
    /// system inset, the window value #626 tucks the rail into), the station, song and artist
    /// names wrap instead of truncating (HIG Dynamic Type: let text wrap, let the layout grow).
    /// Nil is SwiftUI's unlimited `lineLimit`. Every other case returns `oneLine` unchanged: the
    /// default sizes, and the iPhone (no trailing inset) at every size, so iPhone snapshots,
    /// including its AX captures, stay byte-identical.
    public static func nameLineLimit(_ oneLine: Int, accessibilityText: Bool,
                                     trailingSystemInset: Double) -> Int? {
        wrapsNames(accessibilityText: accessibilityText, trailingSystemInset: trailingSystemInset) ? nil : oneLine
    }

    /// True when `nameLineLimit` lets the names wrap (and the header centres its wrapped lines).
    public static func wrapsNames(accessibilityText: Bool, trailingSystemInset: Double) -> Bool {
        accessibilityText && trailingSystemInset.isFinite && trailingSystemInset > 0.5
    }

    /// Where the closed player's quiet DJ line ("DJ break after this song") goes.
    public enum DJLinePlacement: Equatable, Sendable {
        /// Default sizes: in the upper part, under the title row (#537).
        case belowNames
        /// Accessibility sizes (#310 / #345): pinned in the controls under the upper part.
        case pinnedAboveControls
        /// #668 AX5 follow-up (Orion, Nov 27, -Nova): in the upper part's own flow, under the
        /// station, song and artist names, so it scrolls with them and can never sit over them.
        case inFlowBelowNames
    }

    /// #668 AX5 follow-up (-Nova): on 5a0a3904 the AX5 status-column shot showed the wrapped song
    /// title cut off at the pinned DJ chip's top edge and the artist hidden. The chip was pinned
    /// under the upper part, whose ScrollView clipped the wrapped names at that edge. Wherever the
    /// names wrap (`wrapsNames`) on the closed body beside a status column (the phone reader's
    /// `trailingUnsafeWidth`, which the split slices never pass), the chip moves into the names'
    /// own flow. Every other case keeps its #537 / #310 placement, so default sizes, the iPhone
    /// (no trailing inset) and the slices draw exactly as before.
    public static func djLinePlacement(accessibilityText: Bool, trailingSystemInset: Double,
                                       outerTrailingUnsafeWidth: Double) -> DJLinePlacement {
        guard accessibilityText else { return .belowNames }
        let besideStatusColumn = outerTrailingUnsafeWidth.isFinite && outerTrailingUnsafeWidth > 0.5
        return besideStatusColumn && wrapsNames(accessibilityText: accessibilityText,
                                                trailingSystemInset: trailingSystemInset)
            ? .inFlowBelowNames : .pinnedAboveControls
    }

    /// #668 AX5 follow-up (-Nova): a wrapped name must break between words, never inside one
    /// ("Mornin" / "g Calm" on the 5a0a3904 AX5 shot). Text breaks inside a word only when that word
    /// is wider than the line, so the name is drawn at the first of these scales at which its
    /// longest word fits on one line (largest first), and at the last one otherwise. 0.7 is the
    /// floor, so the type stays an accessibility size. Wrapped names only.
    public static let wrappedNameScales: [Double] = [1, 0.9, 0.8, 0.7]

    /// The widest-by-characters word of `name` (whitespace-separated), the one most likely to need
    /// a smaller scale. The view measures the real glyph width; this only picks the probe string.
    /// Empty for an empty or all-space name.
    public static func longestWord(in name: String) -> String {
        let words: [Substring] = name.split(whereSeparator: { (c: Character) in c.isWhitespace })
        return words.max(by: { $0.count < $1.count }).map(String.init) ?? ""
    }

    /// The first `wrappedNameScales` entry at which a word `wordWidth` wide (at scale 1) fits in
    /// `lineWidth`; the last entry when none does. Mirrors the view's `ViewThatFits` order, for tests.
    public static func wrappedNameScale(wordWidth: Double, lineWidth: Double) -> Double {
        wrappedNameScales.first(where: { wordWidth * $0 <= lineWidth }) ?? wrappedNameScales[wrappedNameScales.count - 1]
    }
    /// Height kept for the header, title, DJ line and pinned controls under the art at
    /// default text sizes (accessibility sizes use `FoldedStyle.artReserveAccessibility`).
    /// #537 gives the art what the NEXT row (44 + 12) and the Playing-from toolbar
    /// (52 + 12 + 8) used to take: 470 - 128.
    public static let artReserveBelow: Double = 342
    /// The reserve before #537, kept so the tests can show the art only ever grew.
    public static let artReserveBelowBefore537: Double = 470

    /// Art side at default text sizes: the width less the art insets, capped by the height
    /// less `artReserveBelow`, then clamped to `minSide...maxSide` (min wins).
    public static func artSide(containerWidth: Double, containerHeight: Double,
                               minSide: Double, maxSide: Double,
                               reserveBelow: Double = artReserveBelow) -> Double {
        let byWidth = containerWidth - artInset * 2
        let byHeight = containerHeight - reserveBelow
        return max(minSide, min(byWidth, byHeight, maxSide))
    }

    // MARK: Closed trailing rail (#537 scope addition)

    /// Width of the closed reskin's trailing rail: the #479 rail's 44 pt plates plus 6 pt each side.
    public static let closedRailWidth: Double = 56
    /// Gap between the rail and the container's trailing edge.
    public static let closedRailEdgeInset: Double = 8
    /// Art inset beside the rail (the content gutter, not the mockup's 30, so the art keeps width).
    public static let artInsetBesideRail: Double = contentInset
    /// Height under the art with the transport row gone from the bottom controls: the
    /// 80 pt capsule and its 8 pt gap moved to the rail. 342 - 88.
    public static let artReserveBelowWithRail: Double = artReserveBelow - (transportHeight + 8)

    /// Width left for the art column, header excluded, once the rail is drawn.
    public static func columnWidthBesideRail(containerWidth: Double) -> Double {
        max(0, containerWidth - closedRailWidth - closedRailEdgeInset)
    }

    /// Art side with the rail: the column less its insets, capped by the height less
    /// `artReserveBelowWithRail`, clamped to `minSide...maxSide` (min wins).
    public static func artSideBesideRail(containerWidth: Double, containerHeight: Double,
                                         minSide: Double, maxSide: Double) -> Double {
        let byWidth = columnWidthBesideRail(containerWidth: containerWidth) - artInsetBesideRail * 2
        let byHeight = containerHeight - artReserveBelowWithRail
        return max(minSide, min(byWidth, byHeight, maxSide))
    }

    /// What the closed (phone-width) reskin's ⋯ menu adds above Connections (#537): the
    /// Playing-from row's Queue and Tune, and the rating star from the title row.
    public enum ClosedMoreItem: String, Equatable, Sendable, CaseIterable {
        case queue
        case tune
        case rating
    }

    /// Queue always (the Playing-from chip always opened it). Tune only where the toolbar
    /// showed it (`showsWorkspaceButtons`). Rating only where the star was drawn (a rating
    /// controller that can rate). `queueOnRail` (mockup D): Queue is a rail plate
    /// (`queue.affordance`), so ⋯ does not repeat it.
    public static func closedMoreItems(showsWorkspaceButtons: Bool, canRate: Bool,
                                       queueOnRail: Bool = false) -> [ClosedMoreItem] {
        var items: [ClosedMoreItem] = queueOnRail ? [] : [.queue]
        if showsWorkspaceButtons { items.append(.tune) }
        if canRate { items.append(.rating) }
        return items
    }

    /// The MIC chip as a badge on the art corner (#537): only while the DJ is live.
    /// Mic down draws nothing. Accessibility sizes pin ON AIR above the scrubber instead.
    public static func artBadge(for status: Status, statusPinned: Bool) -> Status? {
        guard !statusPinned else { return nil }
        switch status {
        case .onAir: return status
        case .micDown: return nil
        }
    }

    /// The pinned status pill at accessibility sizes (#537): ON AIR only, never Mic down.
    public static func pinnedPill(for status: Status) -> Status? {
        switch status {
        case .onAir: return status
        case .micDown: return nil
        }
    }

    /// Outer diameter of play plus its ring (68 + 6 + 6). Fits in the 80 pt capsule.
    public static var playOuterSide: Double { playSide + playRingWidth * 2 }

    /// A measured container that overrides a view's own geometry, e.g. the split host's
    /// container (#501 `splitMeasure`). Nil means the caller's own geometry.
    public struct ContainerSize: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// The one rule both `PlayingScreen` (system back hidden, ⋯ moved in) and
    /// `FoldedPlayer.body` (which body draws) use for the reskin: phone width and a track.
    ///
    /// Width only, on purpose. PlayingScreen measures above the navigation bar and
    /// FoldedPlayer below it, so their heights differ, but their widths are the same. Phone
    /// width (`!FoldedColumnLayout.isWide`) is exactly `controlPlacement == .phoneBottom` at
    /// any height, so the two callers cannot disagree. `override` (when given) wins over
    /// `containerWidth`, so a host that measures the container can pass it to both.
    public static func usesOuterReskin(containerWidth: Double, override: ContainerSize? = nil,
                                       showsTrack: Bool) -> Bool {
        guard showsTrack else { return false }
        let width = override?.width ?? containerWidth
        return !FoldedColumnLayout.isWide(containerWidth: width)
    }

    /// On Air comes only from `DJStudioState.onAirLabel`. Ready and failed never light as
    /// On Air. A failed break stays a quiet skip (mic down, no break error).
    public enum Status: Equatable, Sendable {
        /// Confirmed speaking. The string is exactly `onAirLabel`.
        case onAir(String)
        /// Idle, preparing, ready, or a failed break. Never labelled On Air.
        case micDown
    }

    public static func status(onAirLabel: String?) -> Status {
        if let onAirLabel, !onAirLabel.isEmpty {
            return .onAir(onAirLabel)
        }
        return .micDown
    }

    /// Convenience: reads the label from the state, never from a second flag.
    public static func status(of state: DJStudioState) -> Status {
        status(onAirLabel: state.onAirLabel)
    }
}
