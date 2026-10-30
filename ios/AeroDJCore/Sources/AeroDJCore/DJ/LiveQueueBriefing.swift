import Foundation

/// What the player reads when a queue starts. Core has no Studio or SwiftUI type.
public struct LiveQueueBriefingInput: Sendable, Equatable {
    public var items: [ConnectionItem]
    public var preferences: BriefingPreferences
    /// Source-item sensitivity keyed by Connections row id. A missing id is blocked.
    public var sensitivityByItemID: [UUID: Sensitivity]

    public init(items: [ConnectionItem], preferences: BriefingPreferences,
                sensitivityByItemID: [UUID: Sensitivity] = [:]) {
        self.items = items
        self.preferences = preferences
        self.sensitivityByItemID = sensitivityByItemID
    }
}

/// The Studio fields `PlayerView` already holds. Implemented by `StudioPresentationModel`.
@MainActor
public protocol LiveQueueStudio: AnyObject {
    var liveQueueBriefing: LiveQueueBriefingInput { get }
}

extension StudioPresentationModel: LiveQueueStudio {
    public var liveQueueBriefing: LiveQueueBriefingInput {
        // The map `ConnectionsModel` builds (`ConnectionItem.sensitivityMap`), not a copy.
        // A row with no sensitivity is absent from it and is blocked below.
        LiveQueueBriefingInput(items: connections.items, preferences: station.active.briefing,
                               sensitivityByItemID: connections.sensitivityByItemID)
    }
}

/// The briefing provider `PlayerView` passes to `MusicSearch.live`.
///
/// Adapts consent-approved Connections rows into `ContextItem`s and asks
/// `MorningBriefingEngine` for the handoff. It does not write cue text.
/// The briefing plays once per local day, on the first listening session of that
/// day at any hour (owner, Oct 29 2026). Once `BriefingDayLedger` says today was
/// briefed, it is a later show with no carry-forward, so personal speech stays nil.
public enum LiveQueueBriefing {
    /// Closure `PlayerView` passes as the `briefing` argument. The studio and the
    /// day ledger are read when the closure runs, which is when play starts.
    /// `days` is the same ledger `DJBreakSession` marks when a briefing starts playing.
    @MainActor
    public static func provider(
        studio: some LiveQueueStudio,
        days: BriefingDayLedger,
        now: (@MainActor () -> Date)? = nil,
        calendar: Calendar = .current
    ) -> @MainActor () -> ApprovedShowHandoff {
        let clock = now ?? { days.now() }
        return {
            let input = studio.liveQueueBriefing
            return handoff(items: input.items, preferences: input.preferences, now: clock(), calendar: calendar,
                           briefedToday: days.hasBriefedToday,
                           sensitivityByItemID: input.sensitivityByItemID)
        }
    }

    /// Not yet briefed today plus an approved row: the engine's handoff. Briefing off, or
    /// nothing approved: `revokedOrUnapproved`, which `forQueue()` turns into nil.
    /// Already briefed today: a later show with no carry-forward. The time of day no
    /// longer matters (`preferences.window` is not read here).
    /// `prepared` keeps the caller's script, then applies the same section check
    /// as `approvedRows`. An approved cue whose section is off is reported on
    /// `omittedDisabledSection` and is not offered to a later show. Consent
    /// stays in `forQueue()`.
    public static func handoff(
        items: [ConnectionItem],
        preferences: BriefingPreferences,
        now: Date,
        calendar: Calendar = .current,
        prepared: NarrationHandoff? = nil,
        briefedToday: Bool = false,
        sensitivityByItemID: [UUID: Sensitivity] = [:]
    ) -> ApprovedShowHandoff {
        let morning = preferences.enabled && !briefedToday
        let speakable = approvedRows(items, preferences: preferences)
        if !preferences.enabled || (morning && speakable.isEmpty && prepared == nil) {
            return ApprovedShowHandoff(isMorningShow: morning, approved: nil, revokedOrUnapproved: true,
                                       connectionItems: items)
        }
        guard morning else {
            return ApprovedShowHandoff(isMorningShow: false, approved: nil, revokedOrUnapproved: false,
                                       carryForward: nil, connectionItems: items)
        }
        let script: NarrationHandoff?
        let omitted: [NarrationCue]
        if let prepared {
            let checked = preparedKeepingEnabledSections(prepared, items: items, preferences: preferences)
            script = checked.handoff
            omitted = checked.omitted
        } else {
            script = narration(from: speakable, now: now, calendar: calendar,
                               targetSeconds: preferences.targetSeconds,
                               sensitivityByItemID: sensitivityByItemID)
            omitted = []
        }
        return ApprovedShowHandoff(isMorningShow: true, approved: script, revokedOrUnapproved: false,
                                   connectionItems: items, omittedDisabledSection: omitted)
    }

    /// Section check for a script the caller already built. A content cue whose
    /// row may be narrated, and whose integration is not an enabled section, is
    /// omitted. Cues with no matching row stay in the script so `forQueue()` can
    /// still apply consent. Omitted cues are not deferred.
    private static func preparedKeepingEnabledSections(
        _ prepared: NarrationHandoff,
        items: [ConnectionItem],
        preferences: BriefingPreferences
    ) -> (handoff: NarrationHandoff, omitted: [NarrationCue]) {
        var kept: [NarrationCue] = []
        var omitted: [NarrationCue] = []
        for cue in prepared.cues {
            guard let id = cue.sourceItemID, let item = items.first(where: { $0.id == id }) else {
                kept.append(cue)
                continue
            }
            if item.state.mayBeNarrated && !preferences.sections.contains(section(for: item.integration)) {
                omitted.append(cue)
            } else {
                kept.append(cue)
            }
        }
        return (NarrationHandoff(cues: kept, maxSpokenSeconds: prepared.maxSpokenSeconds,
                                 experienceSeconds: prepared.experienceSeconds), omitted)
    }

    /// Consent and section selection only. Sentence composition stays in the engine.
    private static func approvedRows(_ items: [ConnectionItem], preferences: BriefingPreferences) -> [ConnectionItem] {
        guard preferences.enabled else { return [] }
        return items.filter { item in
            item.state.mayBeNarrated
                && preferences.sections.contains(section(for: item.integration))
                && !item.title.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).isEmpty
        }
    }

    /// One briefing builder. Rows become engine inputs: title, source, provenance,
    /// the row's consent, and the source item's sensitivity. No clock time and no
    /// summary, because a Connections row does not have them. A sensitivity the
    /// adapter cannot see is `.blocked`, so the engine drops the row.
    private static func narration(from items: [ConnectionItem], now: Date, calendar: Calendar,
                                  targetSeconds: Int, sensitivityByItemID: [UUID: Sensitivity]) -> NarrationHandoff {
        let spokenCap = min(max(targetSeconds, BriefingPreferences.targetRange.lowerBound), 150)
        let engine = MorningBriefingEngine(
            configuration: MorningBriefingConfiguration(experienceSeconds: 300, maxSpokenSeconds: spokenCap),
            calendar: calendar,
            now: { now })
        let context = items.map { item in
            ContextItem(id: item.id, source: source(for: item.integration), createdAt: now,
                        title: item.title, summary: "",
                        sensitivity: sensitivityByItemID[item.id] ?? .blocked,
                        consent: consent(for: item.state),
                        expiresAt: item.expiresAt, provenance: "connection:\(item.id.uuidString)")
        }
        return engine.script(from: context).handoff(maxSpokenSeconds: spokenCap)
    }

    /// Consent comes from the Connections row. Only `.approved` is granted.
    /// Every other case is non-granted. A new `ConnectionItemState` fails this switch until it is mapped.
    static func consent(for state: ConnectionItemState) -> ConsentState {
        switch state {
        case .approved: .granted
        case .pendingApproval: .notRequested
        case .flaggedForReview: .notRequested
        case .expired: .revoked
        case .revoked: .revoked
        case .unavailable: .denied
        }
    }

    private static func section(for integration: StationIntegration) -> BriefingSection {
        switch integration {
        case .calendar: .calendar
        case .shareInbox: .sharedItems
        case .obsidian: .notes
        }
    }

    private static func source(for integration: StationIntegration) -> ContextSourceKind {
        switch integration {
        case .calendar: .calendar
        case .obsidian: .obsidian
        case .shareInbox: .userShared
        }
    }
}
