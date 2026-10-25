import Foundation

/// A single spoken segment in a briefing.
public struct BriefingSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let sourceItemID: UUID?
    public let estimatedSpokenSeconds: Int
    public let sourceAttribution: String?

    public init(id: UUID = UUID(), text: String, sourceItemID: UUID? = nil,
                estimatedSpokenSeconds: Int, sourceAttribution: String? = nil) {
        self.id = id
        self.text = text
        self.sourceItemID = sourceItemID
        self.estimatedSpokenSeconds = estimatedSpokenSeconds
        self.sourceAttribution = sourceAttribution
    }
}

/// A planned morning-show segment schedule: spoken interludes interleaved with music.
public struct BriefingPlan: Codable, Equatable, Sendable {
    public let segments: [BriefingSegment]
    public let targetSpokenSeconds: Int
    public let estimatedTotalSpokenSeconds: Int

    public init(segments: [BriefingSegment], targetSpokenSeconds: Int) {
        self.segments = segments
        self.targetSpokenSeconds = targetSpokenSeconds
        self.estimatedTotalSpokenSeconds = segments.reduce(0) { $0 + $1.estimatedSpokenSeconds }
    }

    /// Honest duration label: spoken time is bounded; music stretches the total.
    public var spokenDurationLabel: String {
        let m = estimatedTotalSpokenSeconds / 60
        let s = estimatedTotalSpokenSeconds % 60
        return "\(m)m \(s)s spoken"
    }
}
