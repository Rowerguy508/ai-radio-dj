import XCTest
@testable import AeroDJCore

final class BroadcastSchedulerTests: XCTestCase {
    func testSegmentsEvenlySpacedAcrossTracks() async throws {
        let scheduler = DefaultBroadcastScheduler()
        let segments = (0..<4).map { i in
            BriefingSegment(text: "Seg \(i)", estimatedSpokenSeconds: 10)
        }
        let plan = BriefingPlan(segments: segments, targetSpokenSeconds: 40)
        let slots = try await scheduler.schedule(plan: plan, trackCount: 8)
        XCTAssertEqual(slots.count, 4)
        // Distinct boundaries, all within track count.
        let indexes = slots.map { $0.afterTrackIndex }
        XCTAssertEqual(Set(indexes).count, 4)
        XCTAssertTrue(indexes.allSatisfy { $0 < 8 })
    }

    func testMoreSegmentsThanTracksDropped() async throws {
        let scheduler = DefaultBroadcastScheduler()
        let segments = (0..<10).map { i in
            BriefingSegment(text: "Seg \(i)", estimatedSpokenSeconds: 10)
        }
        let plan = BriefingPlan(segments: segments, targetSpokenSeconds: 100)
        let slots = try await scheduler.schedule(plan: plan, trackCount: 3)
        XCTAssertEqual(slots.count, 3)
    }

    func testEmptyPlanNoSlots() async throws {
        let scheduler = DefaultBroadcastScheduler()
        let plan = BriefingPlan(segments: [], targetSpokenSeconds: 60)
        let slots = try await scheduler.schedule(plan: plan, trackCount: 5)
        XCTAssertTrue(slots.isEmpty)
    }

    func testZeroTracksNoSlots() async throws {
        let scheduler = DefaultBroadcastScheduler()
        let segments = [BriefingSegment(text: "Hi", estimatedSpokenSeconds: 5)]
        let plan = BriefingPlan(segments: segments, targetSpokenSeconds: 5)
        let slots = try await scheduler.schedule(plan: plan, trackCount: 0)
        XCTAssertTrue(slots.isEmpty)
    }
}