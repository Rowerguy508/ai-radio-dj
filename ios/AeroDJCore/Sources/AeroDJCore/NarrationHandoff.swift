import Foundation

// Engine -> scheduler handoff contract (#43 -> #34).
//
// The engine hands over bounded, sourced, ordered cues. Whatever schedules
// them returns exactly one explicit outcome per cue (scheduled, deferred or
// dropped with a reason), so nothing approved disappears silently. Playback
// and voice rendering stay with the scheduler/audio engine (Claudio).

/// Where a cue plays relative to whole music tracks. Tracks are never trimmed.
public enum NarrationPlacement: Codable, Hashable, Comparable, Sendable {
    case beforeFirstTrack
    case afterTrack(Int)
}

/// One spoken segment, bounded and attributable.
public struct NarrationCue: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// Position in the briefing; scheduled cues must keep this order.
    public let order: Int
    /// Cues sharing a group play at the same boundary, in order. Adjacent
    /// groups may be merged into one boundary; a group is never split.
    public let group: Int
    public let kind: BriefingScriptSegment.Kind
    public let text: String
    public let estimatedSeconds: Int
    /// Hard bound for the rendered clip. Longer audio is reported
    /// `.dropped(.overDuration)`; it is never cut off mid-sentence.
    public let maxSeconds: Int
    public let sourceItemID: UUID?
    public let source: ContextSourceKind?
    public let provenance: String?

    // Filled in by the voice renderer (nil until rendered).
    /// Measured length of the rendered clip; replaces `estimatedSeconds`.
    public var renderedSeconds: Double?
    /// Voice and provider that produced the clip (e.g. "avspeech", "cartesia").
    public var voiceID: String?
    public var providerID: String?
    /// Cache key of the rendered clip (hash of text + voice + provider + format).
    public var audioCacheKey: String?

    public init(id: UUID, order: Int, group: Int, kind: BriefingScriptSegment.Kind, text: String,
                estimatedSeconds: Int, maxSeconds: Int, sourceItemID: UUID?, source: ContextSourceKind?,
                provenance: String?, renderedSeconds: Double? = nil, voiceID: String? = nil,
                providerID: String? = nil, audioCacheKey: String? = nil) {
        self.id = id
        self.order = order
        self.group = group
        self.kind = kind
        self.text = text
        self.estimatedSeconds = estimatedSeconds
        self.maxSeconds = maxSeconds
        self.sourceItemID = sourceItemID
        self.source = source
        self.provenance = provenance
        self.renderedSeconds = renderedSeconds
        self.voiceID = voiceID
        self.providerID = providerID
        self.audioCacheKey = audioCacheKey
    }

    /// Seconds the scheduler should plan with: measured when rendered, else estimated.
    public var plannedSeconds: Double { renderedSeconds ?? Double(estimatedSeconds) }
    public var isRendered: Bool { renderedSeconds != nil }

    /// Approved personal content (not opener/closer framing).
    public var isContent: Bool { sourceItemID != nil }

    public func accepts(renderedSeconds: Double) -> Bool { renderedSeconds <= Double(maxSeconds) }

    static func bound(estimated: Int, budget: Int) -> Int {
        min(max(budget, estimated), estimated + max(3, estimated / 2))
    }
}

public struct NarrationHandoff: Codable, Equatable, Sendable {
    public let cues: [NarrationCue]
    /// Total spoken-time ceiling; the scheduled cues' estimates never exceed it.
    public let maxSpokenSeconds: Int
    /// Target show length (estimate; music may stretch it, never shrink it).
    public let experienceSeconds: Int

    public var groups: [[NarrationCue]] {
        Dictionary(grouping: cues, by: \.group).sorted { $0.key < $1.key }.map { $0.value.sorted { $0.order < $1.order } }
    }

    /// Bridge for `BroadcastScheduler` implementations that take a `BriefingPlan` (#34).
    public var plan: BriefingPlan {
        BriefingPlan(segments: cues.map {
            BriefingSegment(id: $0.id, text: $0.text, sourceItemID: $0.sourceItemID, estimatedSpokenSeconds: $0.estimatedSeconds)
        }, targetSpokenSeconds: maxSpokenSeconds)
    }
}

public enum NarrationDeferralReason: String, Codable, Sendable {
    /// No track boundary left for it in this show; offer it again next show.
    case noTrackBoundary
    /// The scheduler failed; nothing was played.
    case schedulerFailed
}

public enum NarrationDropReason: String, Codable, Sendable {
    /// Opener/closer framing the scheduler had no room for.
    case notPlacedByScheduler
    /// The scheduler returned different text for this id (never speak it).
    case alteredByScheduler
    /// Rendered audio exceeded `maxSeconds`.
    case overDuration
    /// Every voice route failed or was over its cost cap; nothing to play.
    case renderFailed
    /// Placing it would exceed `maxSpokenSeconds`.
    case overBudget
    /// Personal content without a source/provenance to attribute it to; never spoken.
    case unattributed
}

public enum NarrationOutcome: Codable, Equatable, Sendable {
    case scheduled(NarrationPlacement)
    case deferred(NarrationDeferralReason)
    case dropped(NarrationDropReason)
}

public struct NarrationScheduleEntry: Equatable, Sendable {
    public let cue: NarrationCue
    public let outcome: NarrationOutcome
}

/// Exactly one entry per handed-over cue, in cue order.
public struct NarrationScheduleReport: Equatable, Sendable {
    public let entries: [NarrationScheduleEntry]
    /// Segment ids a scheduler returned that were never handed over (ignored).
    public let unexpectedSegmentIDs: [UUID]

    public init(entries: [NarrationScheduleEntry], unexpectedSegmentIDs: [UUID] = []) {
        self.entries = entries
        self.unexpectedSegmentIDs = unexpectedSegmentIDs
    }

    public func outcome(for id: UUID) -> NarrationOutcome? { entries.first { $0.cue.id == id }?.outcome }

    /// What the audio engine plays: boundaries in order, cues in briefing order.
    public var timeline: [(placement: NarrationPlacement, cues: [NarrationCue])] {
        var byPlacement: [NarrationPlacement: [NarrationCue]] = [:]
        for entry in entries { if case .scheduled(let p) = entry.outcome { byPlacement[p, default: []].append(entry.cue) } }
        return byPlacement.keys.sorted().map { ($0, byPlacement[$0]!.sorted { $0.order < $1.order }) }
    }

    /// Approved content that was not scheduled (deferred or dropped), for logging/UI.
    public var unscheduledContent: [NarrationScheduleEntry] {
        entries.filter { entry in
            guard entry.cue.isContent else { return false }
            if case .scheduled = entry.outcome { return false }
            return true
        }
    }
}

/// Implemented by the broadcast scheduler (#34).
public protocol NarrationScheduling: Sendable {
    func schedule(_ handoff: NarrationHandoff, trackCount: Int) async -> NarrationScheduleReport
}

/// Checks a report against the handoff contract. Empty means conforming.
public enum NarrationContract {
    public static func violations(of report: NarrationScheduleReport, for handoff: NarrationHandoff,
                                  trackCount: Int) -> [String] {
        var problems: [String] = []
        if report.entries.map(\.cue) != handoff.cues { problems.append("outcomes must cover every cue exactly once, in order") }
        if !report.unexpectedSegmentIDs.isEmpty { problems.append("scheduler returned unknown segment ids") }
        var lastPlacement: NarrationPlacement?
        var groupPlacement: [Int: NarrationPlacement] = [:]
        var spoken = 0.0
        for entry in report.entries {
            guard case .scheduled(let placement) = entry.outcome else { continue }
            if case .afterTrack(let index) = placement, !(0..<trackCount).contains(index) {
                problems.append("cue \(entry.cue.order) placed after nonexistent track \(index)")
            }
            if trackCount == 0, placement != .beforeFirstTrack { problems.append("no tracks: cue \(entry.cue.order) must be beforeFirstTrack") }
            if let last = lastPlacement, placement < last { problems.append("cue \(entry.cue.order) scheduled out of order") }
            lastPlacement = placement
            if let existing = groupPlacement[entry.cue.group], existing != placement {
                problems.append("group \(entry.cue.group) split across boundaries")
            }
            groupPlacement[entry.cue.group] = placement
            spoken += entry.cue.plannedSeconds
            if entry.cue.renderedSeconds.map({ $0 > Double(entry.cue.maxSeconds) }) == true {
                problems.append("cue \(entry.cue.order) rendered longer than maxSeconds")
            }
            if entry.cue.kind == .opener, placement != .beforeFirstTrack { problems.append("opener must play before the first track") }
            if entry.cue.kind == .closer, trackCount > 0, placement != .afterTrack(trackCount - 1) {
                problems.append("closer must play after the last track")
            }
        }
        if spoken > Double(handoff.maxSpokenSeconds) { problems.append("scheduled speech exceeds maxSpokenSeconds") }
        return problems
    }
}

extension BriefingScript {
    /// Bounded, sourced, grouped cues for the scheduler: opener + first item,
    /// then one item per group, and the closer in its own final group.
    public func handoff(maxSpokenSeconds: Int) -> NarrationHandoff {
        var group = 0
        var groupHasContent = false
        var cues: [NarrationCue] = []
        for (order, segment) in segments.enumerated() {
            if segment.sourceItemID != nil || segment.kind == .closer {
                if groupHasContent { group += 1 }
                groupHasContent = true
            }
            cues.append(NarrationCue(
                id: segment.id, order: order, group: group, kind: segment.kind, text: segment.text,
                estimatedSeconds: segment.estimatedSpokenSeconds,
                maxSeconds: NarrationCue.bound(estimated: segment.estimatedSpokenSeconds, budget: maxSpokenSeconds),
                sourceItemID: segment.sourceItemID, source: segment.source, provenance: segment.provenance))
        }
        return NarrationHandoff(cues: cues, maxSpokenSeconds: maxSpokenSeconds, experienceSeconds: experienceSeconds)
    }
}

/// Wraps a slot-based scheduler (#34) so its unplaced segments become explicit
/// outcomes. It takes a placement closure rather than `BroadcastScheduler`
/// itself, so it compiles against both #27's `[InterludeSlot]` return type and
/// #34's `BroadcastSchedule` (pass `{ try await s.schedule(plan: $0, trackCount: $1).slots }`).
/// `InterludeSlot` has no before-first-track slot, so an opener it places is a
/// contract violation until the scheduler adopts `NarrationScheduling`.
public struct BroadcastSchedulerAdapter: NarrationScheduling {
    public typealias Placement = @Sendable (BriefingPlan, Int) async throws -> [InterludeSlot]
    private let place: Placement

    public init(place: @escaping Placement) {
        self.place = place
    }

    public func schedule(_ handoff: NarrationHandoff, trackCount: Int) async -> NarrationScheduleReport {
        let slots: [InterludeSlot]
        do {
            slots = try await place(handoff.plan, trackCount)
        } catch {
            return NarrationScheduleReport(entries: handoff.cues.map {
                NarrationScheduleEntry(cue: $0, outcome: $0.isContent ? .deferred(.schedulerFailed) : .dropped(.notPlacedByScheduler))
            })
        }
        let known = Dictionary(uniqueKeysWithValues: handoff.cues.map { ($0.id, $0) })
        var placed: [UUID: NarrationOutcome] = [:]
        var unexpected: [UUID] = []
        var spoken = 0.0
        for slot in slots {
            guard let cue = known[slot.segment.id], placed[cue.id] == nil else { unexpected.append(slot.segment.id); continue }
            if slot.segment.text != cue.text {
                placed[cue.id] = .dropped(.alteredByScheduler)
            } else if cue.renderedSeconds.map({ $0 > Double(cue.maxSeconds) }) == true {
                placed[cue.id] = .dropped(.overDuration)
            } else if spoken + cue.plannedSeconds > Double(handoff.maxSpokenSeconds) {
                placed[cue.id] = .dropped(.overBudget)
            } else {
                spoken += cue.plannedSeconds
                placed[cue.id] = .scheduled(.afterTrack(slot.afterTrackIndex))
            }
        }
        return NarrationScheduleReport(entries: handoff.cues.map { cue in
            NarrationScheduleEntry(cue: cue, outcome: placed[cue.id]
                ?? (cue.isContent ? .deferred(.noTrackBoundary) : .dropped(.notPlacedByScheduler)))
        }, unexpectedSegmentIDs: unexpected)
    }
}
