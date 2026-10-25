import Foundation

/// Deterministically distributes spoken segments across track boundaries.
/// Segments are spaced evenly; more segments than tracks are dropped.
public struct DefaultBroadcastScheduler: BroadcastScheduler {
    public init() {}

    public func schedule(plan: BriefingPlan, trackCount: Int) async throws -> [InterludeSlot] {
        guard trackCount > 0 else { return [] }
        guard !plan.segments.isEmpty else { return [] }

        // At most one interlude per track boundary; evenly spaced.
        let usable = min(plan.segments.count, trackCount)
        let segments = Array(plan.segments.prefix(usable))
        let step = Double(trackCount) / Double(usable)

        return segments.enumerated().map { index, segment in
            let afterTrackIndex = min(trackCount - 1, Int((Double(index) + 0.5) * step))
            return InterludeSlot(segment: segment, afterTrackIndex: afterTrackIndex)
        }
    }
}