import Foundation
import XCTest
@testable import AeroDJCore

/// Open-Duo Stations (A tile grid, B Daytime / After dark, C featured + Switch to), the
/// "Stations layout" setting and Rail D's now-playing thumbnail. -Nova
final class DuoStationsLayoutTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DuoStationsLayoutTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Setting

    func testDefaultIsTheTileGrid() {
        XCTAssertEqual(StationsLayoutStyle.defaultStyle, .tiles)
        XCTAssertEqual(StationsLayoutStyle.stored(defaults: defaults), .tiles, "unset is A")
        XCTAssertNil(defaults.object(forKey: StationsLayoutStyle.defaultsKey), "reading never writes")
    }

    func testEveryChoicePersistsAndReadsBack() {
        for style in StationsLayoutStyle.allCases {
            StationsLayoutStyle.save(style, defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: StationsLayoutStyle.defaultsKey), style.rawValue)
            XCTAssertEqual(StationsLayoutStyle.stored(defaults: defaults), style)
            // A second store on the same suite (a relaunch) reads the same choice.
            let relaunched = UserDefaults(suiteName: suiteName)!
            XCTAssertEqual(StationsLayoutStyle.stored(defaults: relaunched), style)
        }
    }

    func testUnknownOrEmptyStoredValueFallsBackToA() {
        defaults.set("carousel", forKey: StationsLayoutStyle.defaultsKey)
        XCTAssertEqual(StationsLayoutStyle.stored(defaults: defaults), .tiles)
        defaults.set("", forKey: StationsLayoutStyle.defaultsKey)
        XCTAssertEqual(StationsLayoutStyle.stored(defaults: defaults), .tiles)
        XCTAssertEqual(StationsLayoutStyle.resolve(raw: nil), .tiles)
    }

    func testStorageIsAPlainPrefNotTheAppGroup() {
        // A stable plain key, so the @AppStorage row and `stored` agree; no group suite name.
        XCTAssertEqual(StationsLayoutStyle.defaultsKey, "AeroDJStationsLayout")
        XCTAssertFalse(StationsLayoutStyle.defaultsKey.hasPrefix("group."))
        XCTAssertEqual(StationsLayoutStyle.allCases.map(\.rawValue), ["tiles", "editorial", "featured"])
        XCTAssertEqual(Set(StationsLayoutStyle.allCases.map(\.title)).count, 3)
    }

    func testSettingRoundTripsOnTheMainActor() {
        // The Settings row writes from the main actor; the screen reads there too.
        let name = suiteName
        let stored: StationsLayoutStyle = MainActor.assumeIsolated {
            let store = UserDefaults(suiteName: name)!
            StationsLayoutStyle.save(.featured, defaults: store)
            return StationsLayoutStyle.stored(defaults: store)
        }
        XCTAssertEqual(stored, .featured)
    }

    // MARK: Gate

    func testOnlyTheOpenDuoGetsTheNewStations() {
        // Open Duo, upright and sideways (compact class).
        XCTAssertTrue(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: false, containerWidth: 640, containerHeight: 820))
        XCTAssertTrue(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: false, containerWidth: 820, containerHeight: 640))
        // Every iPhone, portrait and landscape, and the closed Duo: unchanged.
        for (w, h) in [(375.0, 667.0), (390, 844), (393, 852), (402, 874), (430, 932), (440, 956),
                       (667, 375), (844, 390), (874, 402), (932, 430), (956, 440)] {
            XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: false, containerWidth: w, containerHeight: h),
                           "\(w) × \(h)")
            XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: true, containerWidth: w, containerHeight: h),
                           "\(w) × \(h) regular")
        }
        // Regular width (iPad, the sidebar-open Duo) keeps the sidebar list.
        XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: true, containerWidth: 820, containerHeight: 640))
        XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: true, containerWidth: 640, containerHeight: 820))
        // Narrow Split View and the 652 × 680 resize probe stay on the phone path.
        XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: false, containerWidth: 340, containerHeight: 760))
        XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: false, containerWidth: 652, containerHeight: 680))
        // Unmeasured.
        XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: false, containerWidth: 0, containerHeight: 0))
        XCTAssertFalse(DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: false, containerWidth: .nan, containerHeight: 820))
    }

    // MARK: Geometry (Rail D rules)

    func testBookPoseMatchesTheMockAndKeepsTheFoldClear() {
        let g = DuoStationsLayout.geometry(containerWidth: 820, containerHeight: 640)
        XCTAssertEqual(g.pose, .book)
        XCTAssertEqual(g.railMinX, 756)
        XCTAssertEqual(g.railMaxX, 812, "8 pt from the trailing edge")
        XCTAssertEqual(g.railMaxX - g.railMinX, 56)
        XCTAssertEqual(g.fold, .init(minX: 396, maxX: 424))
        XCTAssertEqual(g.pages, [.init(minX: 24, maxX: 380), .init(minX: 440, maxX: 740)])
        for page in g.pages {
            XCTAssertFalse(RailDLayout.intersectsFold(minX: page.minX, maxX: page.maxX, foldMinX: 396, foldMaxX: 424))
            XCTAssertLessThan(page.maxX, g.railMinX)
        }
    }

    func testBookPoseFollowsAReportedFold() {
        let g = DuoStationsLayout.geometry(containerWidth: 820, containerHeight: 640, foldMinX: 400, foldMaxX: 420)
        XCTAssertEqual(g.fold, .init(minX: 400, maxX: 420))
        XCTAssertEqual(g.pages[0].maxX, 384)
        XCTAssertEqual(g.pages[1].minX, 436)
        // A nonsense division keeps the centred band.
        let bad = DuoStationsLayout.geometry(containerWidth: 820, containerHeight: 640, foldMinX: 790, foldMaxX: 800)
        XCTAssertEqual(bad.fold, .init(minX: 396, maxX: 424))
    }

    func testPortraitIsOnePageBesideTheRail() {
        let g = DuoStationsLayout.geometry(containerWidth: 640, containerHeight: 820)
        XCTAssertEqual(g.pose, .portrait)
        XCTAssertNil(g.fold)
        XCTAssertEqual(g.railMinX, 576)
        XCTAssertEqual(g.pages, [.init(minX: 24, maxX: 552)])
    }

    func testRailDTokens() {
        XCTAssertEqual(DuoStationsLayout.thumbnailSide, 44)
        XCTAssertLessThanOrEqual(DuoStationsLayout.thumbnailArtSide, DuoStationsLayout.thumbnailSide)
        XCTAssertEqual(DuoStationsLayout.tileCornerRadius, 28)
        XCTAssertEqual(DuoStationsLayout.railVerticalInset, 8)
        XCTAssertGreaterThanOrEqual(DuoStationsLayout.switchRowMinHeight, 44)
    }

    // MARK: Content

    func testTilesAreTwoPerBookPageAndThreeUpright() {
        XCTAssertEqual(DuoStationsLayout.tileColumns(pose: .book), 2)
        XCTAssertEqual(DuoStationsLayout.tileColumns(pose: .portrait), 3)
        XCTAssertEqual(DuoStationsLayout.pageSplit(Array(1...8), pose: .book), [[1, 2, 3, 4], [5, 6, 7, 8]])
        XCTAssertEqual(DuoStationsLayout.pageSplit(Array(1...3), pose: .book), [[1, 2], [3]])
        XCTAssertEqual(DuoStationsLayout.pageSplit([Int](), pose: .book), [[], []])
        XCTAssertEqual(DuoStationsLayout.pageSplit(Array(1...3), pose: .portrait), [[1, 2, 3]])
        XCTAssertEqual(DuoStationsLayout.tileHeight(available: 476, rows: 2), 230)
        XCTAssertEqual(DuoStationsLayout.tileHeight(available: 100, rows: 2), DuoStationsLayout.minTileHeight)
        XCTAssertEqual(DuoStationsLayout.tileHeight(available: 500, rows: 0), DuoStationsLayout.minTileHeight)
    }

    func testDaytimeAndAfterDarkGrouping() {
        let morning = BuiltInStations.morningCalm.id
        let late = BuiltInStations.lateNight.id
        XCTAssertEqual(DuoStationsLayout.builtInDaypart(id: morning), .daytime)
        XCTAssertEqual(DuoStationsLayout.builtInDaypart(id: late), .afterDark)
        XCTAssertNil(DuoStationsLayout.builtInDaypart(id: UUID()))
        // Built-ins plus three created stations: the created ones balance the two groups.
        let a = UUID(), b = UUID(), c = UUID()
        let groups = DuoStationsLayout.group([morning, late, a, b, c], known: DuoStationsLayout.builtInDaypart(id:))
        XCTAssertEqual(groups.map(\.0), [.daytime, .afterDark])
        XCTAssertEqual(groups[0].1, [morning, a, c])
        XCTAssertEqual(groups[1].1, [late, b])
        XCTAssertEqual(DuoStationsLayout.Daypart.daytime.title, "Daytime")
        XCTAssertEqual(DuoStationsLayout.Daypart.afterDark.title, "After dark")
    }

    func testNowPlayingAndFeaturedStation() {
        let ids = ["A", "B", "C"]
        XCTAssertEqual(DuoStationsLayout.nowPlayingIndex(stationIDs: ids, snapshotStationID: "B"), 1)
        XCTAssertNil(DuoStationsLayout.nowPlayingIndex(stationIDs: ids, snapshotStationID: "Z"))
        XCTAssertNil(DuoStationsLayout.nowPlayingIndex(stationIDs: ids, snapshotStationID: nil))
        XCTAssertNil(DuoStationsLayout.nowPlayingIndex(stationIDs: ids, snapshotStationID: ""))
        XCTAssertEqual(DuoStationsLayout.featuredIndex(count: 3, playing: 2), 2)
        XCTAssertEqual(DuoStationsLayout.featuredIndex(count: 3, playing: nil), 0)
        XCTAssertEqual(DuoStationsLayout.featuredIndex(count: 3, playing: 7), 0)
        XCTAssertNil(DuoStationsLayout.featuredIndex(count: 0, playing: nil))
    }

    func testThumbnailReplacesCollapseAtTheTopOfTheRail() {
        XCTAssertEqual(DuoStationsLayout.railSlots(hasNowPlaying: true, showsScrubber: true),
                       [.nowPlayingThumbnail, .more, .playPause, .skip, .queue, .sleepTimer, .scrubber, .liveDot])
        XCTAssertEqual(DuoStationsLayout.railSlots(hasNowPlaying: true, showsScrubber: false),
                       [.nowPlayingThumbnail, .more, .playPause, .skip, .queue, .sleepTimer, .liveDot])
        XCTAssertEqual(DuoStationsLayout.railSlots(hasNowPlaying: false, showsScrubber: true),
                       [.nowPlayingThumbnail, .more, .queue, .sleepTimer, .liveDot])
        // Only the top slot differs from the player's open-Duo rail.
        let player = RailDLayout.slots(hasCollapse: true, showsTransport: true, showsScrubber: true)
        let stations = DuoStationsLayout.railSlots(hasNowPlaying: true, showsScrubber: true)
        XCTAssertEqual(stations.map(\.railD), player)
        XCTAssertEqual(player.first, .collapse)
        XCTAssertEqual(DuoStationsLayout.thumbnailLabel(stationName: "Harbor Lights"), "Open player, now playing Harbor Lights")
        XCTAssertEqual(DuoStationsLayout.thumbnailLabel(stationName: nil), "Open player, nothing playing")
    }

    func testFullRailFitsBothPosesWithTheSongBar() {
        let slots = DuoStationsLayout.railSlots(hasNowPlaying: true, showsScrubber: true)
        // Book pose 640 tall: 624 glass, seven 44 pt plates, seven 10 pt gaps, 6 pt caps, 36 pt of times.
        XCTAssertEqual(DuoStationsLayout.railHeight(containerHeight: 640), 624)
        let plates: Double = 7 * 44
        let gaps: Double = 7 * 10
        let fixed = plates + gaps + 36 + 12
        XCTAssertEqual(fixed, 426)
        XCTAssertEqual(DuoStationsLayout.railTrackLength(containerHeight: 640, slots: slots), 624 - fixed)
        XCTAssertTrue(DuoStationsLayout.railFits(containerHeight: 640, slots: slots))
        XCTAssertTrue(DuoStationsLayout.railFits(containerHeight: 820, slots: slots))
        XCTAssertGreaterThan(DuoStationsLayout.railTrackLength(containerHeight: 820, slots: slots),
                             DuoStationsLayout.railTrackLength(containerHeight: 640, slots: slots))
        XCTAssertFalse(DuoStationsLayout.railFits(containerHeight: 400, slots: slots))
        XCTAssertEqual(DuoRailLayout.spacing, 10)
        XCTAssertEqual(DuoRailLayout.controlSize, 44)
    }

    func testMorePanelStaysOnTheTrailingPage() {
        let book = DuoStationsLayout.geometry(containerWidth: 820, containerHeight: 640)
        let panel = DuoStationsLayout.morePanelFrame(book, containerWidth: 820)
        XCTAssertEqual(panel.trailingGap, 820 - 756 + 8)
        XCTAssertEqual(panel.width, 756 - 8 - 440)
        // Its leading edge (820 - gap - width) is the trailing page's, right of the fold band.
        XCTAssertGreaterThanOrEqual(820 - panel.trailingGap - panel.width, book.fold!.maxX)
        let portrait = DuoStationsLayout.geometry(containerWidth: 640, containerHeight: 820)
        let upright = DuoStationsLayout.morePanelFrame(portrait, containerWidth: 640)
        XCTAssertEqual(upright.trailingGap, 640 - 576 + 8)
        XCTAssertEqual(upright.width, 576 - 8 - 24)
    }
}
