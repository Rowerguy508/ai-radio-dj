import Foundation

/// Turns allowed `ContextItem`s into a structured, attributable briefing plan.
/// Rules-first and deterministic; must never fabricate facts.
public protocol BriefingPlanner: Sendable {
    func plan(from items: [ContextItem], targetSpokenSeconds: Int) async throws -> BriefingPlan
}

/// Schedules spoken interludes between music tracks.
public protocol BroadcastScheduler: Sendable {
    func schedule(plan: BriefingPlan, trackCount: Int) async throws -> BroadcastSchedule
}

public struct InterludeSlot: Codable, Equatable, Sendable {
    public let segment: BriefingSegment
    public let afterTrackIndex: Int
    public init(segment: BriefingSegment, afterTrackIndex: Int) {
        self.segment = segment
        self.afterTrackIndex = afterTrackIndex
    }
}

/// Why a DJ segment was not scheduled. Explicit so callers can log/respond
/// instead of segments silently vanishing.
public enum SegmentDropReason: Codable, Equatable, Sendable {
    case noTracks
    case noSegments
    case onlyOneTrackBoundary // no boundary to speak after
    case notEnoughTracks    // segments exceed available track boundaries
}

/// Explicit scheduling outcome: what got scheduled and what didn't, and why.
public struct BroadcastSchedule: Codable, Equatable, Sendable {
    public let slots: [InterludeSlot]
    public let dropped: [Int: SegmentDropReason]  // segment index -> reason
    public let trackCount: Int

    public init(slots: [InterludeSlot], dropped: [Int: SegmentDropReason], trackCount: Int) {
        self.slots = slots
        self.dropped = dropped
        self.trackCount = trackCount
    }

    public var allScheduled: Bool { dropped.isEmpty }
}

/// Pluggable text-to-speech. Secrets live server-side only.
public protocol VoiceProvider: Sendable {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact
}

public struct VoiceProfile: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RequestContext: Codable, Equatable, Sendable {
    public let stationID: String
    public let isReusableGeneric: Bool
    public init(stationID: String, isReusableGeneric: Bool) {
        self.stationID = stationID
        self.isReusableGeneric = isReusableGeneric
    }
}

public struct VoiceArtifact: Codable, Equatable, Sendable {
    public let data: Data
    public let durationSeconds: Double
    public let billableUnits: Int
    public let provider: String
    public let cacheKey: String?
    public init(data: Data, durationSeconds: Double, billableUnits: Int, provider: String, cacheKey: String?) {
        self.data = data
        self.durationSeconds = durationSeconds
        self.billableUnits = billableUnits
        self.provider = provider
        self.cacheKey = cacheKey
    }
}

/// Read-only source of personal context. Never implies whole-inbox access.
public protocol ContextSource: Sendable {
    var source: ContextSourceKind { get }
    func fetchItems() async throws -> [ContextItem]
}

/// Records per-user TTS/briefing usage. Callers enforce budgets; this protocol does not.
public protocol UsageMeter: Sendable {
    func record(_ usage: UsageRecord) async throws
    func currentUsage(for userID: String) async throws -> UsageSummary
}

public struct UsageRecord: Codable, Equatable, Sendable {
    public let userID: String
    public let provider: String
    public let characters: Int
    public let generatedSeconds: Double
    public let estimatedBillableUnits: Int
    public let observedCost: Double?
    public init(userID: String, provider: String, characters: Int, generatedSeconds: Double, estimatedBillableUnits: Int, observedCost: Double?) {
        self.userID = userID
        self.provider = provider
        self.characters = characters
        self.generatedSeconds = generatedSeconds
        self.estimatedBillableUnits = estimatedBillableUnits
        self.observedCost = observedCost
    }
}

public struct UsageSummary: Codable, Equatable, Sendable {
    public let userID: String
    public let generatedSeconds: Double
    public let estimatedBillableUnits: Int
    /// Number of recorded calls in the meter's window.
    public let callCount: Int
    public init(userID: String, generatedSeconds: Double, estimatedBillableUnits: Int, callCount: Int) {
        self.userID = userID
        self.generatedSeconds = generatedSeconds
        self.estimatedBillableUnits = estimatedBillableUnits
        self.callCount = callCount
    }
}
