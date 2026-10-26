import XCTest
@testable import AeroDJCore

final class QueueGenerationTests: XCTestCase {
    /// The boundary task was suspended on the old queue. `play()` replaced it.
    /// `startNextTrack` must leave the new queue at the song `play()` started.
    func testStaleGenerationBoundaryDoesNotAdvanceTheNewQueue() {
        var generation = QueueGeneration()
        let original = generation.beginQueue()
        var index = 2
        let oldCount = 6

        let replacement = generation.beginQueue()
        index = 0
        let newCount = 4
        let advanced = QueueGenerationGuard.nextTrack(
            after: 2,
            captured: original,
            live: generation.value,
            queueCount: newCount
        )

        XCTAssertNil(advanced, "a replaced queue is not jumped to the old boundary's next index")
        XCTAssertEqual(index, 0)
        XCTAssertNotEqual(original, replacement)
        XCTAssertNotEqual(
            QueueGenerationGuard.nextTrack(after: 2, captured: original, live: original, queueCount: oldCount),
            advanced
        )
        XCTAssertFalse(QueueGenerationGuard.isCurrent(captured: original, live: generation.value))
    }

    /// The same queue is still current, so the boundary loads the following song.
    func testSameGenerationBoundaryAdvancesToTheNextTrack() {
        var generation = QueueGeneration()
        let live = generation.beginQueue()
        var index = 2
        let next = QueueGenerationGuard.nextTrack(
            after: index,
            captured: live,
            live: generation.value,
            queueCount: 6
        )
        XCTAssertEqual(next, 3)
        if let next { index = next }
        XCTAssertEqual(index, 3)
        XCTAssertTrue(QueueGenerationGuard.isCurrent(captured: live, live: generation.value))

        let end = QueueGenerationGuard.nextTrack(
            after: 5,
            captured: live,
            live: generation.value,
            queueCount: 6
        )
        XCTAssertNil(end, "the last song of this queue does not invent another index")
        XCTAssertEqual(index, 3)
    }
}
