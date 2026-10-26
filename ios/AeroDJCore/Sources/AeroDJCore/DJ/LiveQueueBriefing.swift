import Foundation

/// The briefing provider `PlayerView` passes to `MusicSearch.live`.
///
/// Read when play starts, from the Connections rows and briefing preferences the
/// Studio already holds. No MusicKit. Spoken lines use the row title only.
/// Source and provenance stay on the cue. A later show has no carry-forward on
/// the player, so personal speech stays nil outside the morning window.
public enum LiveQueueBriefing {
    /// Closure `PlayerView` passes as the `briefing` argument. `items` and
    /// `preferences` run when the closure runs, which is when play starts.
    public static func provider(
        items: @escaping @MainActor () -> [ConnectionItem],
        preferences: @escaping @MainActor () -> BriefingPreferences,
        now: (@MainActor () -> Date)? = nil,
        calendar: Calendar = .current
    ) -> @MainActor () -> ApprovedShowHandoff {
        let clock = now ?? { Date() }
        return {
            handoff(items: items(), preferences: preferences(), now: clock(), calendar: calendar)
        }
    }

    /// Morning window plus an approved row: that handoff. Briefing off, or nothing
    /// approved: revoked. Outside the window: a later show with no carry-forward.
    /// `prepared` is used instead of title lines when the caller already has a script.
    public static func handoff(
        items: [ConnectionItem],
        preferences: BriefingPreferences,
        now: Date,
        calendar: Calendar = .current,
        prepared: NarrationHandoff? = nil
    ) -> ApprovedShowHandoff {
        let morning = preferences.enabled && preferences.window.contains(now, calendar: calendar)
        let speakable = approvedRows(items, preferences: preferences)
        if !preferences.enabled || (morning && speakable.isEmpty && prepared == nil) {
            return ApprovedShowHandoff(isMorningShow: morning, approved: nil, revokedOrUnapproved: true,
                                       connectionItems: items)
        }
        guard morning else {
            return ApprovedShowHandoff(isMorningShow: false, approved: nil, revokedOrUnapproved: false,
                                       carryForward: nil, connectionItems: items)
        }
        let script = prepared ?? narration(from: speakable, targetSeconds: preferences.targetSeconds)
        return ApprovedShowHandoff(isMorningShow: true, approved: script, revokedOrUnapproved: false,
                                   connectionItems: items)
    }

    private static func approvedRows(_ items: [ConnectionItem], preferences: BriefingPreferences) -> [ConnectionItem] {
        guard preferences.enabled else { return [] }
        return items.filter { item in
            item.state.mayBeNarrated && preferences.sections.contains(section(for: item.integration))
                && !spokenTitle(item.title).isEmpty
        }
    }

    private static func narration(from items: [ConnectionItem], targetSeconds: Int) -> NarrationHandoff {
        let cues: [NarrationCue] = items.enumerated().compactMap { index, item in
            let text = hostLine(item.title, continuing: index > 0)
            guard !text.isEmpty else { return nil }
            let seconds = DefaultBriefingPlanner.estimatedSpokenSeconds(for: text)
            return NarrationCue(
                id: item.id, order: index + 1, group: index, kind: kind(for: item.integration),
                text: text, estimatedSeconds: seconds,
                maxSeconds: NarrationCue.bound(estimated: seconds, budget: 45),
                sourceItemID: item.id, source: source(for: item.integration),
                provenance: "connection:\(item.id.uuidString)")
        }
        let spokenCap = min(max(targetSeconds, BriefingPreferences.targetRange.lowerBound), 150)
        return NarrationHandoff(cues: cues, maxSpokenSeconds: spokenCap, experienceSeconds: 300)
    }

    /// Title only. No clock time, no source tag, no detail the row does not have.
    private static func hostLine(_ title: String, continuing: Bool) -> String {
        let sentence = spokenTitle(title)
        guard !sentence.isEmpty else { return "" }
        return continuing ? "And \(sentence)" : "You've got \(sentence)"
    }

    private static func spokenTitle(_ title: String) -> String {
        let clean = title.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard let last = clean.last else { return "" }
        return ".!?…".contains(last) ? clean : clean + "."
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

    private static func kind(for integration: StationIntegration) -> BriefingScriptSegment.Kind {
        switch integration {
        case .calendar: .upcomingEvent
        case .obsidian: .note
        case .shareInbox: .followUp
        }
    }
}
