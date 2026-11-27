import Foundation

// Open-Duo Stations (owner, 2026-11-17 10:24 ET, relayed by Orion): all three designs from the
// mockups (A tile grid, B Daytime / After dark list, C featured card plus a "Switch to" list),
// picked with Settings > "Stations layout", default A. Rail D sits on the right; on Stations its
// top slot (Collapse on the player) is a 44 pt now-playing thumbnail that opens the player.
// Replaces #551's open-Duo carousel. Pure and UI-free so Linux tests the numbers. -Nova

/// Which open-Duo Stations design the listener picked. Stored as a plain `UserDefaults.standard`
/// string under `defaultsKey`, like the talk-over toggle (`DJTalkoverFlag`). Never the App Group.
public enum StationsLayoutStyle: String, CaseIterable, Equatable, Sendable, Identifiable {
    /// A: big colour tiles.
    case tiles
    /// B: editorial rows grouped Daytime | After dark.
    case editorial
    /// C: the now-playing station as a featured card, the rest as a "Switch to" list.
    case featured

    /// Unset or unknown means A (owner: "Default to A").
    public static let defaultStyle: StationsLayoutStyle = .tiles
    /// `UserDefaults.standard` key. Not in the App Group suite with tokens or consent.
    public static let defaultsKey = "AeroDJStationsLayout"

    public var id: String { rawValue }

    /// Settings row title.
    public var title: String {
        switch self {
        case .tiles: "Tile grid"
        case .editorial: "Daytime and After dark"
        case .featured: "Now playing first"
        }
    }

    /// Settings row subtitle.
    public var summary: String {
        switch self {
        case .tiles: "Big colour tiles, two to a page"
        case .editorial: "A list with large artwork, split by time of day"
        case .featured: "The station you hear, then a quick Switch to list"
        }
    }

    /// A stored raw value, or the default when it is missing or not one of ours.
    public static func resolve(raw: String?) -> StationsLayoutStyle {
        raw.flatMap(StationsLayoutStyle.init(rawValue:)) ?? defaultStyle
    }

    /// Reads the saved choice (never writes).
    public static func stored(defaults: UserDefaults = .standard) -> StationsLayoutStyle {
        resolve(raw: defaults.string(forKey: defaultsKey))
    }

    /// Saves the choice. The Settings row writes the same key through `@AppStorage`.
    public static func save(_ style: StationsLayoutStyle, defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: defaultsKey)
    }
}

public enum DuoStationsLayout {
    // MARK: Gate

    /// True only on the open Duo: the same container test the player uses for its Duo layout
    /// (`FoldedColumnLayout.controlPlacement == .duoHorizontal`), the unfolded display upright
    /// (640 × 820) or sideways (820 × 640). Every iPhone (portrait or landscape, Plus and Max
    /// included) and the closed Duo are false at either width class, so they keep today's
    /// Stations screen. Sizes are the whole container, safe area included.
    ///
    /// Build 54 (owner: "I am not seeing any changes to the ui"): this used to need the compact
    /// class, so an open Duo that reports regular width never drew these Stations. The width
    /// class no longer gates it. Compact is exactly the old rule. Regular also needs the phone
    /// idiom (`isPhoneIdiom`: only a foldable phone is ever this wide and tall) or a fold the
    /// system reports (`hasFold`: a hinge sample or an active division from `FoldDivisionProbe`).
    /// An iPad has neither, so every iPad window (full screen, Split View, Stage Manager) at
    /// regular width keeps today's sidebar list. Size alone cannot tell them apart: an iPad
    /// Split View slice (778 × 820, 790 × 834) is open-Duo sized. -Nova
    public static func usesOpenDuoStations(hasRegularWidth: Bool, containerWidth: Double,
                                           containerHeight: Double, hasFold: Bool = false,
                                           isPhoneIdiom: Bool = false) -> Bool {
        guard containerWidth.isFinite, containerHeight.isFinite,
              containerWidth > 0, containerHeight > 0 else { return false }
        guard FoldedColumnLayout.controlPlacement(containerWidth: containerWidth,
                                                  containerHeight: containerHeight) == .duoHorizontal
        else { return false }
        return !hasRegularWidth || hasFold || isPhoneIdiom
    }

    // MARK: Geometry

    public enum Pose: String, Equatable, Sendable {
        /// Sideways (wider than tall): two book pages either side of a vertical fold.
        case book
        /// Upright: one page.
        case portrait
    }

    /// One page's horizontal span, in the container's points.
    public struct Page: Equatable, Sendable {
        public var minX: Double
        public var maxX: Double
        public init(minX: Double, maxX: Double) {
            self.minX = minX
            self.maxX = maxX
        }
        public var width: Double { max(0, maxX - minX) }
    }

    public struct Geometry: Equatable, Sendable {
        public var pose: Pose
        /// One page upright, two in the book pose (leading, trailing).
        public var pages: [Page]
        /// The fold band nothing tappable may overlap. Nil upright.
        public var fold: Page?
        /// Rail D's leading edge: `containerWidth - trailingInset - railWidth`.
        public var railMinX: Double
        public var railMaxX: Double
    }

    /// Outer gutter on the leading edge (mock: 24).
    public static let leadingGutter: Double = 24
    /// Gap between a page and the fold band (mock: 16, so 380 | 396…424 | 440).
    public static let foldGutter: Double = 16
    /// Gap between the trailing page and the rail: 16 in the book pose (740 | 756), 24 upright.
    public static let bookRailGutter: Double = 16
    public static let portraitRailGutter: Double = 24
    /// The fold band when the SDK reports none: centred, `FoldedColumnLayout.duoFoldGutter` wide
    /// (396…424 at 820 pt, the same band as `RailDCapture.foldBand`).
    public static var defaultFoldWidth: Double { FoldedColumnLayout.duoFoldGutter }
    /// Gap above and below the rail glass (Rail D's closed screen: 8).
    public static var railVerticalInset: Double { RailDLayout.closedVerticalInset }

    /// Build 54 (-Nova): on the device the status cluster (time, battery ring) is a column on
    /// the trailing edge, a trailing safe-area inset (≈ 73 pt in the owner's @3x shots), and the
    /// rail sat inside it, ≈ 90 pt from the window edge. The screen now spans the window's width
    /// (`ignoresSafeArea` horizontally), so the rail is `RailDLayout.trailingInset` from the
    /// window edge. Measured on physical Duo build 57 (`open-duo-player.png` `2853×2007` and
    /// `closed-duo-stations.png` `1398×2034`): the status cluster (bed / time / battery ring /
    /// Wi-Fi / dots) ends at ≈ 110 pt from the window top on open landscape (and ≈ 158 pt on
    /// closed portrait, where the system toolbar starts at ≈ 172 pt). 124 pt clears the dots
    /// with ≈ 14 pt breathing room in both orientations (-Nova).
    public static let statusColumnClearance: Double = 124

    /// Gap from the top of the safe area to the rail glass. `railVerticalInset` (8) with no
    /// trailing unsafe column: every simulator capture and every window today, unchanged.
    public static func railTopInset(trailingUnsafeWidth: Double) -> Double {
        guard trailingUnsafeWidth.isFinite, trailingUnsafeWidth > 0.5 else { return railVerticalInset }
        return max(railVerticalInset, statusColumnClearance)
    }

    /// Trailing inset for the closed-Duo Now Playing rail (`ClosedVerticalRail`).
    /// On iPhone and every simulator capture (`trailingUnsafeWidth <= 0.5`), returns
    /// `RailDLayout.trailingInset` (8 pt) so iPhone snapshots stay byte-identical.
    /// On physical closed Duo (`trailingUnsafeWidth ≈ 84 pt`), centers the 56 pt rail
    /// under the top-right status cluster (matching `closed-duo-stations.png`). -Nova
    public static func closedRailTrailingInset(trailingUnsafeWidth: Double) -> Double {
        guard trailingUnsafeWidth.isFinite, trailingUnsafeWidth > 0.5 else { return RailDLayout.trailingInset }
        let centered = (trailingUnsafeWidth - RailDLayout.railWidth) / 2 + 6
        return min(24, max(RailDLayout.trailingInset, centered))
    }

    /// `foldMinX` / `foldMaxX`: a reported vertical division, if any. Otherwise the book pose
    /// keeps the centred `defaultFoldWidth` band clear anyway, so a flat open Duo never puts a
    /// tile under the hinge either.
    ///
    /// `leadingInset` (build 54, -Nova): the window's leading unsafe width. The screen spans the
    /// window's width, so a status column on the leading edge (the Duo turned the other way)
    /// moves the leading page in by that much. 0 everywhere today, which is the old geometry.
    public static func geometry(containerWidth: Double, containerHeight: Double,
                                foldMinX: Double? = nil, foldMaxX: Double? = nil,
                                leadingInset: Double = 0) -> Geometry {
        let width = max(0, containerWidth.isFinite ? containerWidth : 0)
        let height = max(0, containerHeight.isFinite ? containerHeight : 0)
        let lead = leadingGutter + (leadingInset.isFinite ? max(0, leadingInset) : 0)
        let railMinX = max(0, width - RailDLayout.trailingInset - RailDLayout.railWidth)
        let railMaxX = max(0, width - RailDLayout.trailingInset)
        if width > height {
            var fold = Page(minX: (width - defaultFoldWidth) / 2, maxX: (width + defaultFoldWidth) / 2)
            if let foldMinX, let foldMaxX, foldMinX.isFinite, foldMaxX.isFinite,
               foldMaxX >= foldMinX, foldMinX > lead, foldMaxX < railMinX {
                fold = Page(minX: foldMinX, maxX: foldMaxX)
            }
            let leading = Page(minX: lead, maxX: max(lead, fold.minX - foldGutter))
            let trailingMin = fold.maxX + foldGutter
            let trailing = Page(minX: trailingMin, maxX: max(trailingMin, railMinX - bookRailGutter))
            return Geometry(pose: .book, pages: [leading, trailing], fold: fold,
                            railMinX: railMinX, railMaxX: railMaxX)
        }
        let page = Page(minX: lead, maxX: max(lead, railMinX - portraitRailGutter))
        return Geometry(pose: .portrait, pages: [page], fold: nil, railMinX: railMinX, railMaxX: railMaxX)
    }

    /// #507 rest (-Nova): the narrowest book page that still holds a row of 44 pt targets, two
    /// tile columns and the gap between them (104 pt). A narrower page is left empty.
    public static var bookPageMinWidth: Double {
        Double(tileColumns(pose: .book)) * StudioLayoutMetrics.touchTargetMin + tileGap
    }

    /// #507 rest (-Nova): the Stations pages around the fold the system reports, through the
    /// player's gates (`FoldAwareness.bookPoseFold`). No book-pose fold (no reading, a closed or
    /// fully open hinge, a horizontal laptop division, a phone-sized container) is exactly
    /// `geometry(containerWidth:containerHeight:leadingInset:)`, today's centred band. A
    /// reported fold gives `geometry` with that band, so a centred one draws the same pages as
    /// before. A fold that leaves a page narrower than `bookPageMinWidth` leaves that page empty:
    /// the other page is the only one (drawn as the upright single page) and `fold` stays set, so
    /// no tile, row or header button is laid out on the crease. A band that reaches the rail is
    /// not a fold this screen can avoid and keeps the centred band, as `geometry` does.
    public static func bookGeometry(containerWidth: Double, containerHeight: Double,
                                    hinge: FoldAwareness.HingeSample?, divisions: [FoldAwareness.Division],
                                    leadingInset: Double = 0) -> Geometry {
        let base = geometry(containerWidth: containerWidth, containerHeight: containerHeight,
                            leadingInset: leadingInset)
        guard base.pose == .book,
              let division = FoldAwareness.bookPoseFold(containerWidth: containerWidth,
                                                        containerHeight: containerHeight,
                                                        hinge: hinge, divisions: divisions),
              division.maxX < base.railMinX else { return base }
        let width = max(0, containerWidth)
        let fold = Page(minX: max(0, division.minX), maxX: min(width, division.maxX))
        let lead = leadingGutter + (leadingInset.isFinite ? max(0, leadingInset) : 0)
        let leading = Page(minX: lead, maxX: max(lead, fold.minX - foldGutter))
        let trailingMin = max(lead, fold.maxX + foldGutter)
        let trailing = Page(minX: trailingMin, maxX: max(trailingMin, base.railMinX - bookRailGutter))
        let holds = [leading, trailing].filter { $0.width >= bookPageMinWidth }
        return Geometry(pose: holds.count == 2 ? .book : .portrait, pages: holds, fold: fold,
                        railMinX: base.railMinX, railMaxX: base.railMaxX)
    }

    // MARK: Content

    /// Tile columns per page: two per book page (four tiles to a page in the mock), three upright.
    public static func tileColumns(pose: Pose) -> Int {
        pose == .book ? 2 : 3
    }

    /// Gap between tiles and between list rows.
    public static let tileGap: Double = 16
    /// Tile and featured-card corner radius (Rail D's 28).
    public static var tileCornerRadius: Double { RailDLayout.railCornerRadius }
    /// A tile is never shorter than this (big type plus the art glyph).
    public static let minTileHeight: Double = 180
    /// Editorial artwork side: 84 on the leading page and for the playing row upright, else 76 / 64.
    public static func editorialArtSide(pose: Pose, page: Int, isPlaying: Bool) -> Double {
        switch pose {
        case .book: page == 0 ? 84 : 76
        case .portrait: isPlaying ? 84 : 64
        }
    }
    /// C's "Switch to" rows: a 44 pt art plate and a 44 pt play button, never shorter than 56.
    public static let switchRowMinHeight: Double = 56
    /// C upright: the featured card's height above the list.
    public static let portraitFeaturedHeight: Double = 300

    /// Splits stations across the book's two pages: the first half (rounded up) on the leading
    /// page. Upright, everything is one page.
    public static func pageSplit<T>(_ items: [T], pose: Pose) -> [[T]] {
        guard pose == .book else { return [items] }
        let lead = (items.count + 1) / 2
        return [Array(items.prefix(lead)), Array(items.dropFirst(lead))]
    }

    /// A tile height that fits `rows` rows in `available` points, never under `minTileHeight`.
    public static func tileHeight(available: Double, rows: Int) -> Double {
        guard rows > 0, available.isFinite else { return minTileHeight }
        let fit = (available - tileGap * Double(rows - 1)) / Double(rows)
        return max(minTileHeight, fit.rounded(.down))
    }

    // MARK: A's grid at the window's bottom edge (build 56, 951 × 669 CI shots, -Nova)

    /// A's header above the grid: the title row (52) and the subtitle line (40), as the mock.
    public static let tileHeaderBlock: Double = 92
    /// A's `.padding(6)` round the grid: room for the playing ring, which sits outside the tile.
    public static let tileRingInset: Double = 6
    /// Gap from the last tile row to the window's bottom edge: the side gutter (24), so the grid
    /// has the same margin at the bottom as at the leading edge. Build 56 ran the second row to
    /// 3 pt from the edge of the 951 × 669 window and the scroll view clipped it.
    public static var tileGridBottomMargin: Double { leadingGutter }

    /// A's tile height on a page `pageHeight` tall (the window less `railVerticalInset` above and
    /// below, as `DuoStationsScreen` draws it) under a `headerBlock` header: `rows` rows from the
    /// ring inset under the header down to `tileGridBottomMargin` above the window's bottom edge,
    /// never under `minTileHeight`. 951 × 669 (page 653, header 92): 261, the rows end at 644 of
    /// 669. 820 × 640: 247. Upright 640 × 820, three rows: 219.
    public static func fittedTileHeight(pageHeight: Double, headerBlock: Double, rows: Int) -> Double {
        guard pageHeight.isFinite, headerBlock.isFinite else { return minTileHeight }
        let below = max(0, tileGridBottomMargin - railVerticalInset)
        return tileHeight(available: pageHeight - headerBlock - tileRingInset - below, rows: rows)
    }

    /// The grid's padding under its ring inset, inside the scroll view: the page ends
    /// `railVerticalInset` above the window's bottom edge, so a grid scrolled to its end also
    /// keeps `tileGridBottomMargin` under the last row (8 + 6 + 10 = 24).
    public static var tileGridBottomPadding: Double {
        max(0, tileGridBottomMargin - railVerticalInset - tileRingInset)
    }

    /// The last row's bottom edge in window points: the page's top inset, the header, the ring
    /// inset and `rows` rows with `tileGap` between them.
    public static func lastTileRowMaxY(headerBlock: Double, tileHeight: Double, rows: Int) -> Double {
        let count = Double(max(0, rows))
        return railVerticalInset + headerBlock + tileRingInset + tileHeight * count + tileGap * max(0, count - 1)
    }

    // MARK: Daytime / After dark (B)

    public enum Daypart: String, CaseIterable, Equatable, Sendable {
        case daytime
        case afterDark

        public var title: String {
            switch self {
            case .daytime: "Daytime"
            case .afterDark: "After dark"
            }
        }
    }

    /// The built-in stations' parts of the day. Morning Calm is daytime; Late Night after dark.
    public static func builtInDaypart(id: UUID) -> Daypart? {
        switch id {
        case BuiltInStations.morningCalm.id: .daytime
        case BuiltInStations.lateNight.id: .afterDark
        default: nil
        }
    }

    /// Groups stations into Daytime then After dark, keeping list order inside each. A station
    /// with a known part (`known`) goes there; any other (a created station has no time of day)
    /// joins the shorter group, Daytime on a tie, so the two book pages stay balanced.
    public static func group<T>(_ items: [T], known: (T) -> Daypart?) -> [(Daypart, [T])] {
        var day: [T] = []
        var night: [T] = []
        var unknown: [T] = []
        for item in items {
            switch known(item) {
            case .daytime: day.append(item)
            case .afterDark: night.append(item)
            case nil: unknown.append(item)
            }
        }
        for item in unknown {
            if night.count < day.count { night.append(item) } else { day.append(item) }
        }
        return [(.daytime, day), (.afterDark, night)]
    }

    // MARK: Now playing

    /// The station the player reports (`PlaybackSnapshot.station.id`, a station UUID string),
    /// if it is one of `stationIDs`.
    public static func nowPlayingIndex(stationIDs: [String], snapshotStationID: String?) -> Int? {
        guard let snapshotStationID, !snapshotStationID.isEmpty else { return nil }
        return stationIDs.firstIndex(of: snapshotStationID)
    }

    /// C: the featured card is the playing station; with nothing playing, the first station.
    public static func featuredIndex(count: Int, playing: Int?) -> Int? {
        guard count > 0 else { return nil }
        if let playing, playing >= 0, playing < count { return playing }
        return 0
    }

    /// VoiceOver for the rail's top slot on Stations.
    public static func thumbnailLabel(stationName: String?) -> String {
        guard let stationName, !stationName.isEmpty else { return "Open player, nothing playing" }
        return "Open player, now playing \(stationName)"
    }

    /// Rail D on Stations, top to bottom: the player's open-Duo rail (`RailDLayout.slots`) with
    /// the now-playing thumbnail in Collapse's place. ⋯, Play/Pause and Skip (while a station is
    /// loaded), Queue, the sleep timer, the vertical song bar with its times (a track with a known
    /// duration; otherwise the spacer) and the live dot, all Rail D's own views.
    public enum RailSlot: String, Equatable, Sendable {
        case nowPlayingThumbnail
        case more
        case playPause
        case skip
        case queue
        case sleepTimer
        case scrubber
        case liveDot

        /// The player rail's slot this one stands in for. The thumbnail takes Collapse's 44 pt plate.
        public var railD: RailDLayout.Slot {
            switch self {
            case .nowPlayingThumbnail: .collapse
            case .more: .more
            case .playPause: .playPause
            case .skip: .skip
            case .queue: .queue
            case .sleepTimer: .sleepTimer
            case .scrubber: .scrubber
            case .liveDot: .liveDot
            }
        }
    }

    public static func railSlots(hasNowPlaying: Bool, showsScrubber: Bool) -> [RailSlot] {
        RailDLayout.slots(hasCollapse: true, showsTransport: hasNowPlaying,
                          showsScrubber: hasNowPlaying && showsScrubber).map { slot in
            switch slot {
            case .collapse: .nowPlayingThumbnail
            case .more: .more
            case .playPause: .playPause
            case .skip: .skip
            case .queue: .queue
            case .sleepTimer: .sleepTimer
            case .scrubber: .scrubber
            case .liveDot: .liveDot
            }
        }
    }

    /// The rail glass's height: the container less `railVerticalInset` above and below.
    public static func railHeight(containerHeight: Double) -> Double {
        max(0, containerHeight - 2 * railVerticalInset)
    }

    /// Song-bar length left in the Stations rail (Rail D's arithmetic, same plates and 10 pt gaps).
    public static func railTrackLength(containerHeight: Double, slots: [RailSlot]) -> Double {
        RailDLayout.trackLength(railHeight: railHeight(containerHeight: containerHeight), slots: slots.map(\.railD))
    }

    /// True when every 44 pt plate and a 44 pt song bar fit in the rail.
    public static func railFits(containerHeight: Double, slots: [RailSlot]) -> Bool {
        RailDLayout.fits(railHeight: railHeight(containerHeight: containerHeight), slots: slots.map(\.railD))
    }

    /// The ⋯ panel: top-aligned with the rail, `morePanelGap` inward of it, and never wider than
    /// the page it opens over (the trailing page in the book pose), so it stays off the fold.
    public static let morePanelGap: Double = 8

    public static func morePanelFrame(_ geometry: Geometry, containerWidth: Double) -> (width: Double, trailingGap: Double) {
        let trailingGap = max(0, containerWidth - geometry.railMinX + morePanelGap)
        // #507 rest: never leading of the fold, even when the leading page is the only one.
        let pageMinX = max(geometry.pages.last?.minX ?? 0, geometry.fold.map { $0.maxX + foldGutter } ?? 0)
        let width = max(RailDLayout.controlSize, geometry.railMinX - morePanelGap - pageMinX)
        return (width, trailingGap)
    }

    /// The thumbnail's plate and its art: 44 pt target, 38 pt art inside a 2 pt teal ring.
    public static var thumbnailSide: Double { RailDLayout.controlSize }
    public static let thumbnailArtSide: Double = 38
    public static let thumbnailArtRadius: Double = 12
}

/// Build 54 (Orion, -Nova): the hardware-model signal behind the app's `DeviceIdiom`. A device
/// whose model identifier starts with "iPhone" counts as a phone even if it reports the pad
/// idiom (the open Duo at the regular width class). Pure, so Linux tests it. The identifier is a
/// hardware model string ("iPhone17,3"), not personal data.
public enum DeviceModel {
    /// "iPhone17,3" true; "iPad14,8", "arm64", "x86_64" and "" false.
    public static func isPhoneModel(identifier: String) -> Bool {
        identifier.hasPrefix("iPhone")
    }

    /// The simulator's `utsname.machine` is the host CPU ("arm64", "x86_64"), so there the
    /// simulated model (`SIMULATOR_MODEL_IDENTIFIER`) is the identifier. On a device, `machine`.
    public static func resolvedIdentifier(machine: String, simulatorModel: String?) -> String {
        let hostCPUs: Set<String> = ["arm64", "x86_64", "i386"]
        guard hostCPUs.contains(machine), let simulatorModel, !simulatorModel.isEmpty else { return machine }
        return simulatorModel
    }
}
