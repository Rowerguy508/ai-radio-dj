import XCTest
@testable import AeroDJCore

/// #438 (-Atlas): a station queue is tagged with the station it plays, so the car names that
/// station on Now Playing and marks its row, wherever the station was opened. Deterministic:
/// pure values, no clock, no player.
final class StationQueueOwnerTests: XCTestCase {
    private let rainyID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let summaryCanary = "ZZ_SUMMARY_ZZ"

    private func configuration(_ token: String) -> StationConfiguration {
        var configuration = StationConfiguration.default
        configuration.seeds = [StationSeed(kind: .artist, catalogID: token, name: token)]
        return configuration.validated()
    }

    private var rainy: StationRecipe {
        StationRecipe(id: rainyID, name: "Rainy Day", configuration: configuration("rainy"))
    }

    /// The car screen the way `CarPlaySceneDelegate.projected()` builds it: built-ins in
    /// `BuiltInStations` order (the phone's `Station.defaultStations`), then saved stations.
    private func car(playing tag: StationRef?, opened: StationRef?, recipes: [StationRecipe]) -> CarPlayScreenModel {
        let builtIn = BuiltInStations.all.map {
            CarPlayBuiltInStation(id: $0.id.uuidString, name: $0.name, detail: $0.summary)
        }
        let track = TrackInfo(id: "song", title: "Slow Burn", artistName: "Neon Harbor")
        return CarPlayScreen.project(builtIn: builtIn, created: CreatedStations.entries(from: recipes),
                                     snapshot: PlaybackSnapshot(station: tag, nowPlaying: track, transport: .playing),
                                     opened: opened, access: .authorized)
    }

    private func playingRowNames(_ model: CarPlayScreenModel) -> [String] {
        model.rows.filter(\.showsPlayingIndicator).map(\.name)
    }

    // MARK: - Owner

    func testABuiltInStationOwnsItsQueueByItsRowID() {
        let late = BuiltInStations.lateNight
        let owner = StationQueueOwner.station(lastApplied: late.id, recipes: [rainy], committed: late.configuration)
        XCTAssertEqual(owner, StationRef(id: late.id.uuidString, name: "Late Night"))
    }

    func testASavedStationOwnsItsQueueByItsRecipeID() {
        let owner = StationQueueOwner.station(lastApplied: rainyID, recipes: [rainy], committed: rainy.configuration)
        XCTAssertEqual(owner, StationRef(id: rainyID.uuidString, name: "Rainy Day"))
    }

    func testNoOwnerWhenTheCommittedStationIsNotTheOneApplied() {
        let morning = BuiltInStations.morningCalm
        // Nothing applied yet (launch, before any row tap).
        XCTAssertNil(StationQueueOwner.station(lastApplied: nil, recipes: [rainy], committed: rainy.configuration))
        // Seeds edited after the apply: the committed station is no longer that saved station.
        XCTAssertNil(StationQueueOwner.station(lastApplied: rainyID, recipes: [rainy], committed: configuration("edited")))
        XCTAssertNil(StationQueueOwner.station(lastApplied: morning.id, recipes: [], committed: configuration("edited")))
        // The recipe was deleted.
        XCTAssertNil(StationQueueOwner.station(lastApplied: rainyID, recipes: [], committed: rainy.configuration))
        // A configuration with no seeds is not a station.
        XCTAssertNil(StationQueueOwner.station(lastApplied: rainyID, recipes: [rainy], committed: .default))
        // A blank name is never put on the car.
        let blank = StationRecipe(id: rainyID, name: " \n ", configuration: configuration("rainy"))
        XCTAssertNil(StationQueueOwner.station(lastApplied: rainyID, recipes: [blank], committed: blank.configuration))
    }

    func testTheTagNamesOnlyTheStation() {
        let recipe = StationRecipe(id: rainyID, name: "Rainy Day", configuration: configuration(summaryCanary))
        let owner = StationQueueOwner.station(lastApplied: rainyID, recipes: [recipe], committed: recipe.configuration)
        XCTAssertEqual(owner?.name, "Rainy Day")
        XCTAssertFalse(owner?.name.contains(summaryCanary) ?? true)
        XCTAssertEqual(owner?.id, rainyID.uuidString)
    }

    func testTheOwnerWinsAndThePlayingTagIsOnlyAFallback() {
        let old = StationRef(id: BuiltInStations.morningCalm.id.uuidString, name: "Morning Calm")
        let new = StationRef(id: rainyID.uuidString, name: "Rainy Day")
        XCTAssertEqual(StationQueueOwner.tag(owner: new, playing: old), new)
        XCTAssertEqual(StationQueueOwner.tag(owner: nil, playing: old), old)
        XCTAssertEqual(StationQueueOwner.tag(owner: new, playing: nil), new)
        XCTAssertNil(StationQueueOwner.tag(owner: nil, playing: nil))
    }

    // MARK: - What the car shows

    /// Morning Calm's queue was playing (tagged Morning Calm). The listener picks Rainy Day.
    /// Before #438 the new queue copied Morning Calm's tag: the car said "Morning Calm" and
    /// marked its row while Rainy Day's songs played.
    func testAfterASwitchTheCarNamesAndMarksTheNewStation() {
        let morning = StationRef(id: BuiltInStations.morningCalm.id.uuidString, name: "Morning Calm")
        let owner = StationQueueOwner.station(lastApplied: rainyID, recipes: [rainy], committed: rainy.configuration)
        let tag = StationQueueOwner.tag(owner: owner, playing: morning)
        let opened = StationRef(id: rainyID.uuidString, name: "Rainy Day")
        let model = car(playing: tag, opened: opened, recipes: [rainy])
        XCTAssertEqual(model.nowPlaying?.stationName, "Rainy Day")
        XCTAssertEqual(playingRowNames(model), ["Rainy Day"])
    }

    /// The switch was made on the phone while the car showed Late Night as opened.
    func testAPhoneSwitchIsShownOnTheCarToo() {
        let late = BuiltInStations.lateNight
        let morning = BuiltInStations.morningCalm
        let owner = StationQueueOwner.station(lastApplied: morning.id, recipes: [rainy], committed: morning.configuration)
        let tag = StationQueueOwner.tag(owner: owner, playing: StationRef(id: late.id.uuidString, name: late.name))
        let model = car(playing: tag, opened: StationRef(id: late.id.uuidString, name: late.name), recipes: [rainy])
        XCTAssertEqual(model.nowPlaying?.stationName, "Morning Calm")
        XCTAssertEqual(playingRowNames(model), ["Morning Calm"])
    }

    /// The car connects while a phone-started station already plays: no row was picked on the car.
    func testACarConnectingMidStationStillNamesIt() {
        let owner = StationQueueOwner.station(lastApplied: rainyID, recipes: [rainy], committed: rainy.configuration)
        let model = car(playing: StationQueueOwner.tag(owner: owner, playing: nil), opened: nil, recipes: [rainy])
        XCTAssertEqual(model.nowPlaying?.stationName, "Rainy Day")
        XCTAssertEqual(playingRowNames(model), ["Rainy Day"])
    }

    // MARK: - App adapter (no iOS SDK on Linux: pinned by source)

    func testStationQueuePlayerTagsEveryStationQueueWithItsOwner() throws {
        let ios = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: ios.appendingPathComponent("AeroDJ/StationQueuePlayer.swift"), encoding: .utf8)
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("private weak var studio: StudioPresentationModel?"))
        XCTAssertTrue(code.contains("self.studio = studio"))
        XCTAssertTrue(code.contains("StationQueueOwner.station(lastApplied: $0.lastAppliedRecipeID, recipes: $0.recipes.recipes,"))
        XCTAssertTrue(code.contains("committed: station.committedDisplayed)"))
        XCTAssertTrue(code.contains("let stationRef = StationQueueOwner.tag(owner: owner, playing: music.snapshot.station)"))
        XCTAssertTrue(code.contains("try await music.play(tracks, station: stationRef)"))
        XCTAssertFalse(code.contains("let stationRef = music.snapshot.station"), "a new queue must not copy the old tag")
    }
}
