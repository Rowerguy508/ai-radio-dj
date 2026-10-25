import Foundation

/// Deterministically distributes spoken segments across track boundaries.
/// Segments are spaced evenly; any segment that cannot fit is reported
/// explicitly (never silently dropped).
public struct DefaultBroadcastScheduler: BroadcastScheduler {
    public init() {}

    public func schedule(plan: BriefingPlan, trackCount: Int) async throws -> BroadcastSchedule {
        guard trackCount > 1 else {
            // One or zero tracks → no boundary to speak after.
            let reason: SegmentDropReason = trackCount <= 0 ? .noTracks : .onlyOneTrackBoundary
            var dropped: [Int: SegmentDropReason] = [:]
            for i in plan.segments.indices { dropped[i] = reason }
            return BroadcastSchedule(slots: [], dropped: dropped, trackCount: trackCount)
        }
        guard !plan.segments.isEmpty else {
            return BroadcastSchedule(slots: [], dropped: [:], trackCount: trackCount)
        }

        // At most one interlude per track boundary; evenly spaced.
        let usable = min(plan.segments.count, trackCount)
        let scheduled = Array(plan.segments.prefix(usable))
        let step = Double(trackCount) / Double(usable)

        let slots = scheduled.enumerated().map { index, segment in
            let afterTrackIndex = min(trackCount - 1, Int((Double(index) + 0.5) * step))
            return InterludeSlot(segment: segment, afterTrackIndex: afterTrackIndex)
        }

        // Report any segments that couldn't be placed.
        var dropped: [Int: SegmentDropReason] = [:]
        for i in usable..<plan.segments.count {
            dropped[i] = .notEnoughTracks
        }
        return BroadcastSchedule(slots: slots, dropped: dropped, trackCount: trackCount)
    }
}