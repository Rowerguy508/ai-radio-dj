import Foundation

// Station-start personal update (-Fry, #332). Before #332 a station queue never carried a
// briefing handoff, so personal updates only reached the DJ after a song tap. A station START
// (idle Play starting the station, or a created-station row opening it with nothing queued) now
// asks the same provider a song tap uses (`LiveQueueBriefing.provider`) and offers at most one
// personal update to the new queue.
//
// This type only decides WHEN to ask and HOW MANY to offer. It does not decide eligibility:
// time of day, once-a-day repeat limits and time-sensitive expiry belong to the briefing
// planner (Echo, #332 Core side). Consent stays fail-closed through `ApprovedShowHandoff.forQueue()`,
// and `DJBreakSession.queueStarted` re-checks every cue against its source row, so nothing here
// can widen what may be narrated. A boundary hand-off (refill, or a station change taking over at
// a song boundary) keeps today's behavior: no briefing handoff.

/// Which station hand-off is starting a queue.
public enum StationHandOffKind: String, Equatable, Sendable, CaseIterable {
    /// Play with nothing queued started the station (`stationQueueForIdlePlay`).
    case idlePlayStart
    /// A created-station row was opened while idle (`CreatedStationStarter.open`).
    case createdStationStart
    /// A refill or replacement at a natural song boundary (`stationQueueAtBoundary`).
    case boundary

    /// Only a station start may carry a personal update.
    public var isStationStart: Bool { self != .boundary }
}

/// What a station hand-off passes to `DJBreakSession.beginQueueInBackground`.
public struct StationStartOffer: Equatable, Sendable {
    public var briefing: NarrationHandoff?
    public var sources: [ConnectionItem]

    public static let none = StationStartOffer(briefing: nil, sources: [])
}

public enum StationStartBriefing {
    /// At most one personal update on a station start. The start break is the first thing the
    /// listener hears from a new station, so it stays one music-first item even before the
    /// planner's own one-per-break limit applies. Change here only (tests read this constant).
    public static let maxPersonalUpdatesOnStart = 1

    /// The offer for a hand-off of `kind`. `briefing` is read only for a station start, at the
    /// moment it starts (the same read time as a song tap). Nil when nothing may air.
    @MainActor
    public static func offer(for kind: StationHandOffKind,
                             briefing: (@MainActor () -> ApprovedShowHandoff)?) -> StationStartOffer {
        guard kind.isStationStart, let briefing else { return .none }
        let handoff = briefing()
        // Consent: forQueue() drops every content cue whose row is not approved (fail-closed).
        guard let approved = handoff.forQueue() else { return .none }
        let content = approved.cues.filter(\.isContent).sorted { $0.order < $1.order }
        guard !content.isEmpty else { return .none }
        let kept = Set(content.prefix(maxPersonalUpdatesOnStart).map(\.id))
        let cues = approved.cues.filter { !$0.isContent || kept.contains($0.id) }
        return StationStartOffer(
            briefing: NarrationHandoff(cues: cues, maxSpokenSeconds: approved.maxSpokenSeconds,
                                       experienceSeconds: approved.experienceSeconds),
            sources: handoff.connectionItems)
    }
}
