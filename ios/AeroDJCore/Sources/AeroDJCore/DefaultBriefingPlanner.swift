import Foundation

/// Rules-first planner: builds a briefing from allowed, narratable `ContextItem`s.
/// Deterministic, no LLM, no fabricated facts. Only narratable items are included.
public struct DefaultBriefingPlanner: BriefingPlanner {
    public init() {}

    public func plan(from items: [ContextItem], targetSpokenSeconds: Int) async throws -> BriefingPlan {
        // Only items the user has granted consent for and that aren't blocked.
        let allowed = items
            .filter { $0.isNarratable }
            .filter { $0.expiresAt.map { $0 > Date() } ?? true }
            .sorted { $0.eventAt ?? $0.createdAt < $1.eventAt ?? $1.createdAt }

        // Budget: cap total spoken seconds at target, ~150 wpm.
        let wordsPerSecond = 150.0 / 60.0
        var remaining = Double(targetSpokenSeconds)
        var segments: [BriefingSegment] = []

        for item in allowed {
            let wordCount = Double(item.summary.split(separator: " ").count)
            let seconds = Int((wordCount / wordsPerSecond).rounded(.up))
            guard Double(seconds) <= remaining else { break }
            segments.append(BriefingSegment(
                text: item.summary,
                sourceItemID: item.id,
                estimatedSpokenSeconds: seconds
            ))
            remaining -= Double(seconds)
        }

        return BriefingPlan(segments: segments, targetSpokenSeconds: targetSpokenSeconds)
    }
}
