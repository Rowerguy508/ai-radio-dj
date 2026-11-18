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

    /// True only on the open Duo: compact width class and the same container test the player
    /// uses for its Duo layout (`FoldedColumnLayout.controlPlacement == .duoHorizontal`), the
    /// unfolded display upright (640 × 820) or sideways (820 × 640). Every iPhone (portrait or
    /// landscape, Plus and Max included), the closed Duo and regular width are false, so they
    /// keep today's Stations screen. Sizes are the whole container, safe area included.
    public static func usesOpenDuoStations(hasRegularWidth: Bool, containerWidth: Double,
                                           containerHeight: Double) -> Bool {
        guard !hasRegularWidth, containerWidth.isFinite, containerHeight.isFinite,
              containerWidth > 0, containerHeight > 0 else { return false }
        return FoldedColumnLayout.controlPlacement(containerWidth: containerWidth,
                                                   containerHeight: containerHeight) == .duoHorizontal
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

    /// `foldMinX` / `foldMaxX`: a reported vertical division, if any. Otherwise the book pose
    /// keeps the centred `defaultFoldWidth` band clear anyway, so a flat open Duo never puts a
    /// tile under the hinge either.
    public static func geometry(containerWidth: Double, containerHeight: Double,
                                foldMinX: Double? = nil, foldMaxX: Double? = nil) -> Geometry {
        let width = max(0, containerWidth.isFinite ? containerWidth : 0)
        let height = max(0, containerHeight.isFinite ? containerHeight : 0)
        let railMinX = max(0, width - RailDLayout.trailingInset - RailDLayout.railWidth)
        let railMaxX = max(0, width - RailDLayout.trailingInset)
        if width > height {
            var fold = Page(minX: (width - defaultFoldWidth) / 2, maxX: (width + defaultFoldWidth) / 2)
            if let foldMinX, let foldMaxX, foldMinX.isFinite, foldMaxX.isFinite,
               foldMaxX >= foldMinX, foldMinX > leadingGutter, foldMaxX < railMinX {
                fold = Page(minX: foldMinX, maxX: foldMaxX)
            }
            let leading = Page(minX: leadingGutter, maxX: max(leadingGutter, fold.minX - foldGutter))
            let trailingMin = fold.maxX + foldGutter
            let trailing = Page(minX: trailingMin, maxX: max(trailingMin, railMinX - bookRailGutter))
            return Geometry(pose: .book, pages: [leading, trailing], fold: fold,
                            railMinX: railMinX, railMaxX: railMaxX)
        }
        let page = Page(minX: leadingGutter, maxX: max(leadingGutter, railMinX - portraitRailGutter))
        return Geometry(pose: .portrait, pages: [page], fold: nil, railMinX: railMinX, railMaxX: railMaxX)
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
        let pageMinX = geometry.pages.last?.minX ?? 0
        let width = max(RailDLayout.controlSize, geometry.railMinX - morePanelGap - pageMinX)
        return (width, trailingGap)
    }

    /// The thumbnail's plate and its art: 44 pt target, 38 pt art inside a 2 pt teal ring.
    public static var thumbnailSide: Double { RailDLayout.controlSize }
    public static let thumbnailArtSide: Double = 38
    public static let thumbnailArtRadius: Double = 12
}
