import Foundation

/// Rules-first planner: builds a briefing from allowed, narratable `ContextItem`s.
/// Deterministic, no LLM, no fabricated facts. Only narratable items are included.
/// Dedupes by provenance, ranks by relevance, bounds segments to 3-6, and
/// attributes each segment to its source.
public struct DefaultBriefingPlanner: BriefingPlanner {
    private let sanitizer = PromptInjectionSanitizer()

    public init() {}

    public func plan(from items: [ContextItem], targetSpokenSeconds: Int) async throws -> BriefingPlan {
        // Only items the user has granted consent for and that aren't blocked.
        let allowed = items
            .filter { $0.isNarratable }
            .filter { $0.expiresAt.map { $0 > Date() } ?? true }

        // Dedupe by provenance (stable source link).
        var seen: Set<String> = []
        let deduped = allowed.filter { seen.insert($0.provenance).inserted }

        // Rank relevance: calendar first (time-sensitive), then shared, then notes.
        let ranked = deduped.sorted { lhs, rhs in
            let l = relevance(lhs), r = relevance(rhs)
            if l != r { return l > r }
            return (lhs.eventAt ?? lhs.createdAt) < (rhs.eventAt ?? rhs.createdAt)
        }

        // Budget: cap total spoken seconds at target, ~150 wpm.
        let wordsPerSecond = 150.0 / 60.0
        var remaining = Double(targetSpokenSeconds)
        var segments: [BriefingSegment] = []

        for item in ranked {
            // Sanitize against prompt injection before narrating.
            let safeSummary = sanitizer.sanitize(item.summary)
            guard !safeSummary.isEmpty else { continue }

            let wordCount = Double(safeSummary.split(separator: " ").count)
            let seconds = Int((wordCount / wordsPerSecond).rounded(.up))
            guard Double(seconds) <= remaining else { break }

            segments.append(BriefingSegment(
                text: safeSummary,
                sourceItemID: item.id,
                estimatedSpokenSeconds: seconds,
                sourceAttribution: sourceLabel(item.source)
            ))
            remaining -= Double(seconds)
        }

        // Bound to 3-6 segments.
        let bounded = Array(segments.prefix(6))
        return BriefingPlan(segments: bounded, targetSpokenSeconds: targetSpokenSeconds)
    }

    /// Calendar events are most time-sensitive; rank them first.
    private func relevance(_ item: ContextItem) -> Int {
        switch item.source {
        case .calendar: return 3
        case .emailShared, .messagesShared: return 2
        case .obsidian, .userShared: return 1
        }
    }

    private func sourceLabel(_ source: ContextSourceKind) -> String {
        switch source {
        case .calendar: return "calendar"
        case .emailShared: return "email"
        case .messagesShared: return "messages"
        case .obsidian: return "notes"
        case .userShared: return "shared"
        }
    }
}
