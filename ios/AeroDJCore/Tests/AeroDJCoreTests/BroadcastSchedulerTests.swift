import XCTest
@testable import AeroDJCore

final class BroadcastSchedulerTests: XCTestCase {
    private func segments(_ count: Int) -> [BriefingSegment] {
        (0..<count).map { i in
            BriefingSegment(text: "Seg \(i)", estimatedSpokenSeconds: 10)
        }
    }

    func testSegmentsEvenlySpacedAcrossTracks() async throws {
        let scheduler = DefaultBroadcastScheduler()
        let plan = BriefingPlan(segments: segments(4), targetSpokenSeconds: 40)
        let schedule = try await scheduler.schedule(plan: plan, trackCount: 8)
        XCTAssertEqual(schedule.slots.count, 4)
        XCTAssertTrue(schedule.allScheduled)
        let indexes = schedule.slots.map { $0.afterTrackIndex }
        XCTAssertEqual(Set(indexes).count, 4)
        XCTAssertTrue(indexes.allSatisfy { $0 < 8 })
    }

    func testMoreSegmentsThanTracksReportedNotSilentDropped() async throws {
        let scheduler = DefaultBroadcastScheduler()
        let plan = BriefingPlan(segments: segments(10), targetSpokenSeconds: 100)
        let schedule = try await scheduler.schedule(plan: plan, trackCount: 3)
        XCTAssertEqual(schedule.slots.count, 3)
        XCTAssertFalse(schedule.allScheduled)
        // Exactly 7 overflow segments reported as notEnoughTracks.
        XCTAssertEqual(schedule.dropped.count, 7)
        XCTAssertTrue(schedule.dropped.values.allSatisfy { $0 == .notEnoughTracks })
    }

    func testZeroTracksExplicitlyDropped() async throws {
        let scheduler = DefaultBroadcastScheduler()
        let plan = BriefingPlan(segments: segments(2), targetSpokenSeconds: 20)
        let schedule = try await scheduler.schedule(plan: plan, trackCount: 0)
        XCTAssertTrue(schedule.slots.isEmpty)
        XCTAssertFalse(schedule.allScheduled)
        XCTAssertEqual(schedule.dropped, [0: .noTracks, 1: .noTracks])
    }

    func testSingleTrackNoBoundary() async throws {
        let scheduler = DefaultBroadcastScheduler()
        let plan = BriefingPlan(segments: segments(2), targetSpokenSeconds: 20)
        let schedule = try await scheduler.schedule(plan: plan, trackCount: 1)
        XCTAssertTrue(schedule.slots.isEmpty)
        XCTAssertEqual(schedule.dropped[0], .onlyOneTrackBoundary)
    }

    func testEmptyPlanNoDrops() async throws {
        let scheduler = DefaultBroadcastScheduler()
        let plan = BriefingPlan(segments: [], targetSpokenSeconds: 60)
        let schedule = try await scheduler.schedule(plan: plan, trackCount: 5)
        XCTAssertTrue(schedule.slots.isEmpty)
        XCTAssertTrue(schedule.allScheduled) // nothing to drop, no error
    }
}