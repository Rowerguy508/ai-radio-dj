import XCTest
@testable import AeroDJCore

final class QueueHandoffTests: XCTestCase {
    func testSongEndingWithAnotherSongQueuedAdvancesToIt() {
        XCTAssertEqual(QueueHandoff.afterSongEnds(finishedIndex: 0, count: 3), .advance(to: 1))
        XCTAssertEqual(QueueHandoff.afterSongEnds(finishedIndex: 1, count: 3), .advance(to: 2))
    }

    func testLastSongStopsTheStation() {
        XCTAssertEqual(QueueHandoff.afterSongEnds(finishedIndex: 2, count: 3), .stop)
    }

    func testSingleSongStationStops() {
        XCTAssertEqual(QueueHandoff.afterSongEnds(finishedIndex: 0, count: 1), .stop)
    }

    func testInvalidIndexStops() {
        XCTAssertEqual(QueueHandoff.afterSongEnds(finishedIndex: -1, count: 3), .stop)
        XCTAssertEqual(QueueHandoff.afterSongEnds(finishedIndex: 0, count: 0), .stop)
    }
}
