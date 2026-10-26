import XCTest
@testable import AeroDJCore

#if DEBUG
// P3 truthfulness: in the test station, "Stop using" a source must behave as it does live.
// Before, fixture items stayed approved under the static granted consent, so a stopped Calendar
// still listed "Items (2)" and its events kept narrating. -Fry
@MainActor
final class TestStationStopUsingTests: XCTestCase {
    func testStopUsingAFixtureSourceRemovesItsItemsFromConnectionsAndTheBriefing() async throws {
        let composition = ConnectionsComposition.testStationFixtures(TestStationFixtures())
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: TestStation.configuration))),
            consent: composition.consent)
        await station.load()
        let log = PurgeRecorder()
        let connections = ConnectionsModel(station: station, sourceReader: composition.sourceReader,
                                           providers: composition.providers, purger: log)
        await connections.refresh()
        let calendarIDs = Set(connections.items(for: .calendar).map(\.id))
        XCTAssertFalse(calendarIDs.isEmpty, "the fixture has calendar events")
        XCTAssertTrue(connections.source(.calendar).actions.contains(.revoke))

        _ = await connections.perform(.revoke, onSource: .calendar)

        XCTAssertTrue(connections.items(for: .calendar).isEmpty, "no Items (n) for a source no longer used")
        XCTAssertFalse(connections.source(.calendar).mayShowConnected)
        let purged = await log.ids
        XCTAssertTrue(calendarIDs.isSubset(of: purged), "its narration was purged")
        var narrated: [ContextItem] = []
        for source in composition.contextSources { narrated += try await source.fetchItems() }
        XCTAssertFalse(narrated.contains { $0.source == .calendar }, "and it leaves the next briefing")
        XCTAssertTrue(narrated.contains { $0.source == .obsidian }, "other sources are untouched")

        await connections.refresh()
        XCTAssertTrue(connections.items(for: .calendar).isEmpty, "a later refresh does not bring them back")
    }
}

private actor PurgeRecorder: NarrationPurging {
    private(set) var ids: Set<UUID> = []
    func purge(sourceItemIDs: Set<UUID>) async { ids.formUnion(sourceItemIDs) }
}
#endif
