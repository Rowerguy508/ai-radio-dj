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
        // Rows do not carry `aerodj-sensitivity`. An unknown id is blocked below.
        LiveQueueBriefingInput(items: connections.items, preferences: station.active.briefing,
                               sensitivityByItemID: [:])
    }
}

/// The briefing provider `PlayerView` passes to `MusicSearch.live`.
///
/// Adapts consent-approved Connections rows into `ContextItem`s and asks
/// `MorningBriefingEngine` for the handoff. It does not write cue text.
/// Since #332 personal updates may air at any time of day (`BriefingPreferences.window` no
/// longer gates them). A song tap and a station start read the same provider; a shared
/// `PersonalUpdateLedger` keeps each update to once per local day.
public enum LiveQueueBriefing {
    /// Closure `PlayerView` passes as the `briefing` argument, and the one a station start
    /// reads (#332). The studio and the ledger are read when the closure runs, which is when
    /// play starts. Pass the app's single `ledger` to every provider so a tap and a station
    /// start share the once-a-day limit. Nil: no repeat limit (tests and previews only).
    @MainActor
    public static func provider(
        studio: some LiveQueueStudio,
        now: (@MainActor () -> Date)? = nil,
        calendar: Calendar = .current,
        ledger: PersonalUpdateLedger? = nil
    ) -> @MainActor () -> ApprovedShowHandoff {
        let clock = now ?? { Date() }
        return {
            let input = studio.liveQueueBriefing
            return handoff(items: input.items, preferences: input.preferences, now: clock(), calendar: calendar,
                           sensitivityByItemID: input.sensitivityByItemID, ledger: ledger)
        }
    }

    /// An approved row, at any time of day: the engine's handoff. Briefing off, or
    /// nothing approved: `revokedOrUnapproved`, which `forQueue()` turns into nil.
    /// `prepared` keeps the caller's script, then applies the same section check
    /// as `approvedRows`. An approved cue whose section is off is reported on
    /// `omittedDisabledSection` and is not offered to a later show.
    /// Then the #332 limits: an update that already aired today (`ledger`) is
    /// `.dropped(.repeatLimit)`, and one whose row expired is `.dropped(.windowPassed)`,
    /// both on `omittedByLimit`. Consent stays in `forQueue()`.
    public static func handoff(
        items: [ConnectionItem],
        preferences: BriefingPreferences,
        now: Date,
        calendar: Calendar = .current,
        prepared: NarrationHandoff? = nil,
        sensitivityByItemID: [UUID: Sensitivity] = [:],
        ledger: PersonalUpdateLedger? = nil
    ) -> ApprovedShowHandoff {
        let speakable = approvedRows(items, preferences: preferences)
        if !preferences.enabled || (speakable.isEmpty && prepared == nil) {
            return ApprovedShowHandoff(isMorningShow: preferences.enabled, approved: nil, revokedOrUnapproved: true,
                                       connectionItems: items)
        }
        let script: NarrationHandoff?
        let omitted: [NarrationCue]
        var limited: [NarrationScheduleEntry] = []
        if let prepared {
            let checked = preparedKeepingEnabledSections(prepared, items: items, preferences: preferences)
            script = checked.handoff
            omitted = checked.omitted
        } else {
            // Rows held back by a #332 limit never reach the engine: it would drop an expired row
            // unreported, and an update that already aired today would take another's place.
            let today = ledger?.limitedItemIDs(at: now) ?? []
            var eligible: [ConnectionItem] = []
            for row in speakable {
                if let end = row.expiresAt, end <= now {
                    limited.append(NarrationScheduleEntry(cue: reportOnlyCue(for: row), outcome: .dropped(.windowPassed)))
                } else if today.contains(row.id) {
                    limited.append(NarrationScheduleEntry(cue: reportOnlyCue(for: row), outcome: .dropped(.repeatLimit)))
                } else {
                    eligible.append(row)
                }
            }
            script = narration(from: eligible, now: now, calendar: calendar,
                               targetSeconds: preferences.targetSeconds,
                               sensitivityByItemID: sensitivityByItemID)
            omitted = []
        }
        let gated = script.map { applyLimits($0, items: items, now: now, ledger: ledger) }
        limited += gated?.omitted ?? []
        return ApprovedShowHandoff(isMorningShow: true, approved: gated?.handoff, revokedOrUnapproved: false,
                                   connectionItems: items, omittedDisabledSection: omitted,
                                   omittedByLimit: NarrationScheduleReport(entries: limited))
    }

    /// #332 limits on content cues, in cue order. Framing cues pass through.
    /// - row `expiresAt` passed: `.dropped(.windowPassed)` (never carried forward),
    /// - item already aired today, or a second cue for the same item: `.dropped(.repeatLimit)`.
    static func applyLimits(_ handoff: NarrationHandoff, items: [ConnectionItem], now: Date,
                            ledger: PersonalUpdateLedger?) -> (handoff: NarrationHandoff, omitted: [NarrationScheduleEntry]) {
        let limitedToday = ledger?.limitedItemIDs(at: now) ?? []
        var seen: Set<UUID> = []
        var kept: [NarrationCue] = []
        var omitted: [NarrationScheduleEntry] = []
        for cue in handoff.cues.sorted(by: { $0.order < $1.order }) {
            guard let id = cue.sourceItemID else { kept.append(cue); continue }
            let row = items.first { $0.id == id }
            if let end = row?.expiresAt, end <= now {
                omitted.append(NarrationScheduleEntry(cue: cue, outcome: .dropped(.windowPassed)))
            } else if limitedToday.contains(id) || !seen.insert(id).inserted {
                omitted.append(NarrationScheduleEntry(cue: cue, outcome: .dropped(.repeatLimit)))
            } else {
                kept.append(cue)
            }
        }
        return (NarrationHandoff(cues: kept, maxSpokenSeconds: handoff.maxSpokenSeconds,
                                 experienceSeconds: handoff.experienceSeconds), omitted)
    }

    /// Report-only entry for a row that never became a cue. Empty text and 0 s: it cannot be
    /// spoken, and it carries only the row's id, source and provenance. The kind matches what
    /// the engine gives a row with no clock time (calendar: event; notes: note; shared: follow-up).
    static func reportOnlyCue(for item: ConnectionItem) -> NarrationCue {
        let kind: BriefingScriptSegment.Kind
        switch item.integration {
        case .calendar: kind = .upcomingEvent
        case .obsidian: kind = .note
        case .shareInbox: kind = .followUp
        }
        return NarrationCue(id: item.id, order: 0, group: 0, kind: kind, text: "", estimatedSeconds: 0,
                            maxSeconds: 0, sourceItemID: item.id, source: source(for: item.integration),
                            provenance: "connection:\(item.id.uuidString)")
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
