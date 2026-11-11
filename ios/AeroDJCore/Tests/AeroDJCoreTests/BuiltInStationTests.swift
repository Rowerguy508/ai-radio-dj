import XCTest
@testable import AeroDJCore

/// #442: Morning Calm and Late Night ship with catalog song seeds the existing
/// seed engine can build a queue from.
final class BuiltInStationTests: XCTestCase {
    func testEachBuiltInStationHasNonEmptyCatalogSongSeeds() {
        XCTAssertEqual(BuiltInStations.all.map(\.name), ["Morning Calm", "Late Night"])
        var seen: Set<String> = []
        for station in BuiltInStations.all {
            let seeds = station.configuration.seeds
            XCTAssertFalse(seeds.isEmpty, station.name)
            XCTAssertEqual(station.configuration.validated().seeds, seeds, station.name)
            XCTAssertEqual(station.configuration.reach, .related, station.name)
            XCTAssertTrue(station.configuration.requestedIntegrations.isEmpty, station.name)
            XCTAssertFalse(station.configuration.briefing.enabled, station.name)
            for seed in seeds {
                XCTAssertEqual(seed.kind, .song, station.name)
                XCTAssertEqual(seed.source, .catalog, station.name)
                XCTAssertFalse(seed.catalogID.isEmpty, station.name)
                XCTAssertTrue(seed.catalogID.allSatisfy(\.isNumber), "\(station.name) seed id \(seed.catalogID)")
                XCTAssertFalse(seed.name.isEmpty, station.name)
                XCTAssertTrue(seen.insert(seed.catalogID).inserted, "seed \(seed.catalogID) is on more than one station")
            }
        }
    }

    func testBuiltInIdsMatchTheStationRows() {
        XCTAssertEqual(BuiltInStations.morningCalm.id.uuidString, "7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D")
        XCTAssertEqual(BuiltInStations.lateNight.id.uuidString, "8D3B2C21-5F60-4B7C-9D0E-1F2A3B4C5D6E")
        XCTAssertEqual(BuiltInStations.morningCalm.summary, "Warm, unhurried host")
        XCTAssertEqual(BuiltInStations.lateNight.summary, "Smooth vinyl-bar vibes")
        XCTAssertEqual(BuiltInStations.station(id: BuiltInStations.morningCalm.id)?.name, "Morning Calm")
        XCTAssertNil(BuiltInStations.station(id: UUID()))
    }
}
