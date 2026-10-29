import Foundation

// Natural DJ talk between songs. Lines are built only from:
//   - real track metadata passed in from MusicKit (`DJTrack`),
//   - the station name, when it is usable, and
//   - approved briefing cues from `MorningBriefingEngine`.
// Templates add no facts of their own (no genres, years, chart claims, or weather).
// Phrasing pools live in `EditorialPhrasing`. A talk break is one short shape
// (transition, artist focus, station ID, or time-of-day), not a stack of all of them.

/// Track metadata exactly as MusicKit reported it. Empty fields are never spoken.
public struct DJTrack: Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String

    public init(id: String, title: String, artist: String) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum DayPart: String, Sendable, CaseIterable {
    case earlyMorning, morning, afternoon, evening, lateNight

    public init(hour: Int) {
        switch hour {
        case 4..<7: self = .earlyMorning
        case 7..<12: self = .morning
        case 12..<17: self = .afternoon
        case 17..<22: self = .evening
        default: self = .lateNight
        }
    }
}

/// How often the DJ talks. Music takes priority: most boundaries are music-only.
public struct DJCadence: Equatable, Sendable {
    /// Target share of song boundaries that get a music-only break (0...1). The spacing rule
    /// caps what is achievable at `1 / (minSongsBetweenBreaks + 1)`; see `expectedTalkShare`.
    public var talkFraction: Double
    /// Whole songs that must play between two breaks. At least 1 (never back-to-back) unless
    /// `allowsBackToBack`, which only the owner's Chatty override sets.
    public var minSongsBetweenBreaks: Int
    /// Chatty only: a break may follow every song (`minSongsBetweenBreaks` 0).
    public var allowsBackToBack: Bool
    /// Cap for a break with no briefing content.
    public var maxTransitionSeconds: Int
    /// Cap for a break that carries briefing cues. Durable notes that do not fit
    /// may be offered next show; time-sensitive cues are dropped, not deferred.
    public var maxBriefingBreakSeconds: Int

    public init(talkFraction: Double = 0.3, minSongsBetweenBreaks: Int = 2,
                maxTransitionSeconds: Int = 12, maxBriefingBreakSeconds: Int = 45,
                allowsBackToBack: Bool = false) {
        self.talkFraction = min(max(talkFraction, 0), 1)
        self.allowsBackToBack = allowsBackToBack
        self.minSongsBetweenBreaks = max(allowsBackToBack ? 0 : 1, minSongsBetweenBreaks)
        self.maxTransitionSeconds = maxTransitionSeconds
        self.maxBriefingBreakSeconds = maxBriefingBreakSeconds
    }

    /// Share of boundaries with a break that the planner actually delivers over a long session
    /// (no briefing): `talkFraction`, limited by the spacing rule.
    public var expectedTalkShare: Double {
        min(talkFraction, 1 / Double(minSongsBetweenBreaks + 1))
    }

    /// Chance to talk at a boundary the spacing rule allows. After a break, `minSongsBetweenBreaks`
    /// boundaries are forced silent, so rolling `talkFraction` there would under-deliver
    /// (0.3 with a gap of 2 gives about 19%). Solving `share = 1 / (gap + 1 / p)` for `p` makes the
    /// delivered share match `talkFraction`.
    var eligibleBoundaryProbability: Double {
        guard talkFraction > 0 else { return 0 }
        let remaining = 1 - Double(minSongsBetweenBreaks) * talkFraction
        return remaining <= talkFraction ? 1 : min(1, talkFraction / remaining)
    }
}

/// Deterministic PRNG (SplitMix64) so tests can seed a session.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A template pool that does not repeat a line until every usable line has been used,
/// and never repeats the previous line across a reset.
public struct TemplatePool: Sendable {
    public let templates: [String]
    private var used: Set<Int> = []
    private var last: Int?

    public init(_ templates: [String]) { self.templates = templates }

    /// Picks a template whose placeholders can all be filled from `values`; nil if none can.
    public mutating func next(filling values: [String: String], using rng: inout SeededGenerator) -> String? {
        let usable = templates.indices.filter { Self.fill(templates[$0], values) != nil }
        guard !usable.isEmpty else { return nil }
        var fresh = usable.filter { !used.contains($0) }
        if fresh.isEmpty {
            used.subtract(usable)
            fresh = usable.count > 1 ? usable.filter { $0 != last } : usable
        }
        let pick = fresh[Int(rng.next() % UInt64(fresh.count))]
        used.insert(pick)
        last = pick
        return Self.fill(templates[pick], values)
    }

    /// Replaces `{key}` placeholders; nil if any is missing or empty.
    static func fill(_ template: String, _ values: [String: String]) -> String? {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            out += rest[..<open]
            guard let value = values[String(rest[rest.index(after: open)..<close])], !value.isEmpty else { return nil }
            out += value
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

/// Where a spoken line's words came from. Every spoken cue has one.
public enum SpokenAttribution: Equatable, Sendable {
    /// Built only from MusicKit title/artist of these track ids.
    case trackMetadata(trackIDs: [String])
    /// An approved, sanitized briefing item (its text also names the source aloud).
    case personalContext(itemID: UUID, source: ContextSourceKind, provenance: String)
    /// Fixed presenter phrasing with no facts (greeting, lead-in).
    case presenter
}

/// One planned break at a natural song boundary.
public struct DJBreak: Equatable, Sendable {
    /// Plays after this track (0-based) and before the next. Never mid-song.
    public let afterTrack: Int
    /// Spoken in order: optional back-announce/greeting, briefing cues, then the intro of the next song.
    public let cues: [NarrationCue]
    /// Attribution for every cue id in `cues`.
    public let attributions: [UUID: SpokenAttribution]
    public var briefingCueIDs: [UUID] { cues.filter(\.isContent).map(\.id) }
    public var hasBriefing: Bool { cues.contains { $0.isContent } }
    public var estimatedSeconds: Double { cues.reduce(0) { $0 + $1.plannedSeconds } }
}

public struct DJSessionPlan: Equatable, Sendable {
    public let breaks: [DJBreak]
    /// One outcome for every briefing cue: placed in a break, or explicitly deferred/dropped.
    public let briefingReport: NarrationScheduleReport
}

/// Plans a session: where the DJ talks and what it says. State (template pools,
/// RNG) lives for the whole listening session so phrasing does not repeat.
public struct DJScriptWriter: Sendable {
    public var cadence: DJCadence
    /// Spoken in station IDs. Unusable names (empty, braces, instruction-shaped) are skipped.
    public var stationName: String
    private var rng: SeededGenerator
    /// Chooses the break shape. Kept off `rng` so the talk/silence rolls stay put.
    private var editorial: SeededGenerator
    private var backAnnounce = TemplatePool(EditorialPhrasing.backAnnounce)
    private var intro = TemplatePool(EditorialPhrasing.songIntro)
    private var artistFocus = TemplatePool(EditorialPhrasing.artistFocus)
    private var stationIDs = TemplatePool(EditorialPhrasing.stationID)
    private var atmosphere: [DayPart: TemplatePool] = EditorialPhrasing.atmosphere.mapValues { TemplatePool($0) }
    private var briefingLead = TemplatePool([
        "Let me catch you up.",
        "A couple of things before the next song.",
        "While we're between songs.",
    ])
    private var greetings: [DayPart: TemplatePool] = [
        .earlyMorning: TemplatePool(["Early start today.", "Good morning, early riser."]),
        .morning: TemplatePool(["Good morning.", "Morning."]),
        .afternoon: TemplatePool(["Good afternoon.", "Afternoon."]),
        .evening: TemplatePool(["Good evening.", "Evening."]),
        .lateNight: TemplatePool(["Late one tonight.", "Still up? Good."]),
    ]
    private var hasGreeted = false

    public init(cadence: DJCadence = .init(), seed: UInt64 = UInt64.random(in: .min ... .max), stationName: String = "AeroDJ") {
        self.cadence = cadence
        self.stationName = stationName
        self.rng = SeededGenerator(seed: seed)
        self.editorial = SeededGenerator(seed: seed &+ 0x9E37_79B9_7F4A_7C15)
    }

    /// - Parameters:
    ///   - tracks: the queue in play order, from MusicKit.
    ///   - briefing: approved narration from `BriefingScript.handoff`; may be empty.
    ///   - hour: local hour, for time-of-day phrasing.
    ///   - stationName: overrides `self.stationName` for this plan. Default keeps the writer's name.
    public mutating func plan(tracks: [DJTrack], briefing: NarrationHandoff?, hour: Int, stationName: String? = nil) -> DJSessionPlan {
        let station = stationName ?? self.stationName
        let dayPart = DayPart(hour: hour)
        // Briefing content in priority order; opener/closer framing is replaced by DJ phrasing.
        var outcomes: [UUID: NarrationOutcome] = [:]
        // Personal content is spoken only with a source and provenance to attribute it to.
        // Instruction-shaped text is reported and dropped here even if a caller skipped the engine.
        let screen = PromptInjectionSanitizer()
        var pending: [NarrationCue] = []
        for cue in (briefing?.cues ?? []).filter(\.isContent).sorted(by: { $0.order < $1.order }) {
            if cue.source == nil || cue.provenance?.isEmpty != false {
                outcomes[cue.id] = .dropped(.unattributed)
            } else if screen.isSuspicious(cue.text) {
                outcomes[cue.id] = .dropped(.rejectedAsInstruction)
            } else {
                pending.append(cue)
            }
        }
        for cue in briefing?.cues ?? [] where !cue.isContent { outcomes[cue.id] = .dropped(.notPlacedByScheduler) }

        var breaks: [DJBreak] = []
        var lastBreak: Int?
        var order = 0
        for boundary in 0..<max(0, tracks.count - 1) {
            if let lastBreak, boundary - lastBreak <= cadence.minSongsBetweenBreaks { continue }
            let wantsBriefing = !pending.isEmpty
            let roll = Double(rng.next() % 10_000) / 10_000
            guard wantsBriefing || roll < cadence.eligibleBoundaryProbability else { continue }

            let prev = tracks[boundary], next = tracks[boundary + 1]
            // Each pool sees only one track's fields, so attribution is exact by construction.
            var attributions: [UUID: SpokenAttribution] = [:]
            var cues: [NarrationCue] = []
            func add(_ text: String, _ attribution: SpokenAttribution) -> NarrationCue {
                let cue = transitionCue(text, order: &order)
                attributions[cue.id] = attribution
                return cue
            }
            if !hasGreeted, let greeting = greetings[dayPart]?.next(filling: [:], using: &rng) {
                cues.append(add(greeting, .presenter))
                hasGreeted = true
            } else if !wantsBriefing, let colored = colorLine(prev: prev, dayPart: dayPart, station: station) {
                cues.append(add(colored.text, colored.attribution))
            } else if let line = backAnnounce.next(filling: ["title": prev.title, "artist": prev.artist], using: &rng) {
                cues.append(add(line, .trackMetadata(trackIDs: [prev.id])))
            }
            let introLine = intro.next(filling: ["nextTitle": next.title, "nextArtist": next.artist], using: &rng)

            if wantsBriefing {
                let limit = Double(cadence.maxBriefingBreakSeconds)
                var spent = cues.reduce(0) { $0 + $1.plannedSeconds } + estimate(introLine)
                if let lead = briefingLead.next(filling: [:], using: &rng) {
                    let leadCue = add(lead, .presenter)
                    spent += leadCue.plannedSeconds
                    var taken: [NarrationCue] = []
                    while let cue = pending.first, spent + cue.plannedSeconds <= limit {
                        taken.append(cue); spent += cue.plannedSeconds; pending.removeFirst()
                    }
                    if taken.isEmpty, let cue = pending.first, cue.plannedSeconds + leadCue.plannedSeconds > limit {
                        outcomes[cue.id] = .dropped(.overBudget)   // can never fit any break
                        pending.removeFirst()
                    }
                    if !taken.isEmpty {
                        cues.append(leadCue)
                        cues += taken
                        for cue in taken {
                            outcomes[cue.id] = .scheduled(.afterTrack(boundary))
                            attributions[cue.id] = .personalContext(itemID: cue.sourceItemID!, source: cue.source!, provenance: cue.provenance!)
                        }
                    } else {
                        attributions[leadCue.id] = nil
                    }
                }
            }
            if let introLine { cues.append(add(introLine, .trackMetadata(trackIDs: [next.id]))) }
            guard !cues.isEmpty else { continue }
            let isBriefing = cues.contains { $0.isContent }
            if !isBriefing, cues.reduce(0, { $0 + $1.plannedSeconds }) > Double(cadence.maxTransitionSeconds) { continue }
            breaks.append(DJBreak(afterTrack: boundary, cues: cues, attributions: attributions))
            lastBreak = boundary
        }
        for cue in pending {
            outcomes[cue.id] = Self.carriesToLaterShow(cue) ? .deferred(.noTrackBoundary) : .dropped(.notCarriedForward)
        }
        let entries = (briefing?.cues ?? []).map { cue in
            NarrationScheduleEntry(cue: cue, outcome: outcomes[cue.id] ?? Self.unplaced(cue))
        }
        return DJSessionPlan(breaks: breaks, briefingReport: NarrationScheduleReport(entries: entries))
    }

    /// Notes and follow-ups can air in a later show. Calendar events and due tasks cannot.
    static func carriesToLaterShow(_ cue: NarrationCue) -> Bool {
        guard cue.isContent, !EditorialCarryForward.isTimeSensitive(cue) else { return false }
        return cue.kind == .note || cue.kind == .followUp
    }

    static func unplaced(_ cue: NarrationCue) -> NarrationOutcome {
        guard cue.isContent else { return .dropped(.notPlacedByScheduler) }
        return carriesToLaterShow(cue) ? .deferred(.noTrackBoundary) : .dropped(.notCarriedForward)
    }

    private enum BreakColor { case plain, artist, station, atmosphere }

    /// About 55% plain transitions, 20% artist focus, 12% station IDs, 13% time-of-day.
    /// One shape per break, so ordinary talk stays a couple of short lines.
    private mutating func editorialColor() -> BreakColor {
        switch editorial.next() % 100 {
        case 0..<20: return .artist
        case 20..<32: return .station
        case 32..<45: return .atmosphere
        default: return .plain
        }
    }

    /// One connector line, or nil when this break should use the plain back-announce.
    /// A nil return does not draw from `rng` (the caller draws the back-announce instead).
    private mutating func colorLine(prev: DJTrack, dayPart: DayPart, station: String) -> (text: String, attribution: SpokenAttribution)? {
        switch editorialColor() {
        case .plain:
            return nil
        case .artist:
            guard let line = artistFocus.next(filling: ["title": prev.title, "artist": prev.artist], using: &rng) else { return nil }
            return (line, .trackMetadata(trackIDs: [prev.id]))
        case .station:
            guard let name = EditorialStationName.usable(station),
                  let line = stationIDs.next(filling: ["station": name], using: &rng) else { return nil }
            return (line, .presenter)
        case .atmosphere:
            guard let line = atmosphere[dayPart]?.next(filling: [:], using: &rng) else { return nil }
            return (line, .presenter)
        }
    }

    private func estimate(_ text: String?) -> Double {
        text.map { Double(DefaultBriefingPlanner.estimatedSpokenSeconds(for: $0)) } ?? 0
    }

    private func transitionCue(_ text: String, order: inout Int) -> NarrationCue {
        defer { order += 1 }
        let seconds = DefaultBriefingPlanner.estimatedSpokenSeconds(for: text)
        return NarrationCue(id: UUID(), order: order, group: -1, kind: .transition, text: text,
                            estimatedSeconds: seconds, maxSeconds: max(8, seconds * 2), sourceItemID: nil,
                            source: nil, provenance: nil)
    }
}
