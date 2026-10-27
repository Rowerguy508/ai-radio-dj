import Foundation

/// Rules-first planner: builds a briefing from allowed, narratable `ContextItem`s.
/// Deterministic, no LLM, no fabricated facts. Only narratable items are included.
public struct DefaultBriefingPlanner: BriefingPlanner {
    /// Speaking rate used to estimate segment duration.
    public static let wordsPerMinute = 150.0

    private let now: @Sendable () -> Date

    /// - Parameter now: time source used for expiry checks; injectable for tests.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func plan(from items: [ContextItem], targetSpokenSeconds: Int) async throws -> BriefingPlan {
        let currentTime = now()
        let allowed = items
            .filter { $0.isNarratable(at: currentTime) }
            .sorted { $0.eventAt ?? $0.createdAt < $1.eventAt ?? $1.createdAt }

        var remaining = targetSpokenSeconds
        var segments: [BriefingSegment] = []

        for item in allowed {
            let seconds = Self.estimatedSpokenSeconds(for: item.summary)
            // Skip items that don't fit rather than ending the briefing, so one
            // long item can't silence every later, shorter one.
            guard seconds <= remaining else { continue }
            segments.append(BriefingSegment(
                text: item.summary,
                sourceItemID: item.id,
                estimatedSpokenSeconds: seconds
            ))
            remaining -= seconds
        }

        return BriefingPlan(segments: segments, targetSpokenSeconds: targetSpokenSeconds)
    }

    /// Estimated spoken duration, rounded up to whole seconds.
    static func estimatedSpokenSeconds(for text: String) -> Int {
        let wordCount = Double(text.split(whereSeparator: \.isWhitespace).count)
        return Int((wordCount / (wordsPerMinute / 60.0)).rounded(.up))
    }
}
