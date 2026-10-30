import Foundation

// Natural DJ talk between songs. Lines are built only from:
//   - real track metadata passed in from MusicKit (`DJTrack`),
//   - the station name, when it is usable, and
//   - approved briefing cues from `MorningBriefingEngine`.
// Templates add no facts of their own (no genres, years, chart claims, or weather).
// Phrasing pools live in `EditorialTone` (default `.warm`). A talk break is a MAIN segment
// (back-announce or artist focus, optional station ID or time-of-day color, optional fact-free
// continuation) and one short CLOSING line naming the next song. The closing line is the last
// cue and is budgeted on its own (`maxClosingSeconds`) so the player may let it land over the
// next song's intro. Each cue is filled from one source, so its attribution is exact.

/// Track metadata exactly as MusicKit reported it. Empty fields are never spoken.
public struct DJTrack: Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    /// Where the track entered the queue (Sentinel). Defaults to `.unknown`, which is treated as
    /// personal: only `.catalog` tracks may be named by an off-device voice.
    public let origin: TrackOrigin

    public init(id: String, title: String, artist: String, origin: TrackOrigin = .unknown) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.origin = origin
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
    /// Cap for the MAIN segment of a break with no briefing content (every cue except the
    /// talk-over closing line). A closing line that does not fit `maxClosingSeconds` is not
    /// talk-over and counts here instead.
    public var maxTransitionSeconds: Int
    /// Cap for the talk-over closing line, counted separately from the main segment.
    public var maxClosingSeconds: Int
    /// Cap for a break that carries briefing cues. Durable notes that do not fit
    /// may be offered next show; time-sensitive cues are dropped, not deferred.
    public var maxBriefingBreakSeconds: Int
    /// Cap for a whole ordinary break (no briefing content), the closing line included, at the
    /// word-rate estimate. Optional lines (continuation, then color) are dropped to fit; a break
    /// whose required lines (opener and closing) alone exceed it is not planned. Both are
    /// reported in `DJSessionPlan.ordinaryCapReport`. Briefing breaks keep `maxBriefingBreakSeconds`.
    public var maxOrdinaryBreakSeconds: Int

    public init(talkFraction: Double = 0.3, minSongsBetweenBreaks: Int = 2,
                maxTransitionSeconds: Int = 15, maxBriefingBreakSeconds: Int = 45,
                allowsBackToBack: Bool = false, maxClosingSeconds: Int = 4,
                maxOrdinaryBreakSeconds: Int = 12) {
        self.talkFraction = min(max(talkFraction, 0), 1)
        self.allowsBackToBack = allowsBackToBack
        self.minSongsBetweenBreaks = max(allowsBackToBack ? 0 : 1, minSongsBetweenBreaks)
        self.maxTransitionSeconds = maxTransitionSeconds
        self.maxClosingSeconds = max(0, maxClosingSeconds)
        self.maxBriefingBreakSeconds = maxBriefingBreakSeconds
        self.maxOrdinaryBreakSeconds = max(0, maxOrdinaryBreakSeconds)
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
    /// Built only from MusicKit title/artist of these track ids. `origin` is the most restrictive
    /// origin of those tracks (`resolvingTrackOrigins(in:)`); only `.catalog` may leave the device.
    case trackMetadata(trackIDs: [String], origin: TrackOrigin = .unknown)
    /// An approved, sanitized briefing item (its text also names the source aloud).
    case personalContext(itemID: UUID, source: ContextSourceKind, provenance: String)
    /// Fixed presenter phrasing with no facts (greeting, lead-in).
    case presenter
    /// A station ID that speaks a station name other than the built-in brand
    /// (`DJScriptWriter.builtInStationName`). A created station's name was typed by the listener,
    /// so it is personal and stays on-device (Sentinel, build 26 sweep). -Atlas
    case stationName
}

/// One planned break at a natural song boundary.
public struct DJBreak: Equatable, Sendable {
    /// Plays after this track (0-based) and before the next. Never mid-song.
    public let afterTrack: Int
    /// Spoken in order: optional back-announce/greeting, briefing cues, then the intro of the next song.
    public let cues: [NarrationCue]
    /// Attribution for every cue id in `cues`.
    public let attributions: [UUID: SpokenAttribution]
    /// The closing line (always the last cue) when it fits `maxClosingSeconds` and may land
    /// over the next song's intro. Nil: every cue plays in the gap, as before.
    public var talkOverCueID: UUID? = nil
    public var briefingCueIDs: [UUID] { cues.filter(\.isContent).map(\.id) }
    public var hasBriefing: Bool { cues.contains { $0.isContent } }
    public var estimatedSeconds: Double { cues.reduce(0) { $0 + $1.plannedSeconds } }
    /// Planned seconds of the talk-over closing line; 0 without one.
    public var closingSeconds: Double { cues.last.flatMap { $0.id == talkOverCueID ? $0.plannedSeconds : nil } ?? 0 }
    /// Planned seconds spoken in the gap (everything but the talk-over closing line).
    public var mainSeconds: Double { estimatedSeconds - closingSeconds }
}

public struct DJSessionPlan: Equatable, Sendable {
    public let breaks: [DJBreak]
    /// One outcome for every briefing cue: placed in a break, or explicitly deferred/dropped.
    public let briefingReport: NarrationScheduleReport
    /// What the ordinary-break caps left out. Fact-free presenter lines only: no briefing cue is
    /// ever counted here (those are in `briefingReport`).
    public var ordinaryCapReport = OrdinaryBreakCapReport()
}

/// Ordinary-break lines omitted by `DJCadence.maxTransitionSeconds` or
/// `DJCadence.maxOrdinaryBreakSeconds`, by boundary (the `afterTrack` the break would follow).
public struct OrdinaryBreakCapReport: Equatable, Sendable {
    /// Optional lines (continuation, station ID, time-of-day color) dropped so the break fits.
    public var trimmedOptionalLines: [Int: Int] = [:]
    /// Boundaries where the required lines alone (opener and closing) exceed a cap, so the
    /// boundary stays music-only. Never cut mid-line.
    public var skippedOverCap: [Int] = []
    public init() {}
}

/// Plans a session: where the DJ talks and what it says. State (template pools,
/// RNG) lives for the whole listening session so phrasing does not repeat.
public struct DJScriptWriter: Sendable {
    /// The app's own brand. The only station name a station ID may treat as fixed phrasing.
    public static let builtInStationName = "AeroDJ"
    public var cadence: DJCadence
    /// Spoken in station IDs. Unusable names (empty, braces, instruction-shaped) are skipped.
    public var stationName: String
    /// The phrase bank. Swapping it changes the words, never the engine.
    public let tone: EditorialTone
    /// Talk/silence rolls only, so phrasing changes never move where breaks fall.
    private var rng: SeededGenerator
    /// Chooses the break shape.
    private var editorial: SeededGenerator
    /// Picks lines from the pools.
    private var phrasing: SeededGenerator
    private var backAnnounce: TemplatePool
    private var closing: TemplatePool
    private var artistFocus: TemplatePool
    private var stationIDs: TemplatePool
    private var continuation: TemplatePool
    private var atmosphere: [DayPart: TemplatePool]
    private var briefingLead: TemplatePool
    private var briefingOutro: TemplatePool
    private var greetings: [DayPart: TemplatePool]
    private var hasGreeted = false

    public init(cadence: DJCadence = .init(), seed: UInt64 = UInt64.random(in: .min ... .max), stationName: String = DJScriptWriter.builtInStationName,
                tone: EditorialTone = .warm) {
        self.cadence = cadence
        self.stationName = stationName
        self.tone = tone
        self.rng = SeededGenerator(seed: seed)
        self.editorial = SeededGenerator(seed: seed &+ 0x9E37_79B9_7F4A_7C15)
        self.phrasing = SeededGenerator(seed: seed &+ 0x3C6E_F372_FE94_F82B)
        backAnnounce = TemplatePool(tone.backAnnounce)
        closing = TemplatePool(tone.closing)
        artistFocus = TemplatePool(tone.artistFocus)
        stationIDs = TemplatePool(tone.stationID)
        continuation = TemplatePool(tone.continuation)
        atmosphere = tone.atmosphere.mapValues { TemplatePool($0) }
        briefingLead = TemplatePool(tone.briefingLead)
        briefingOutro = TemplatePool(tone.briefingOutro)
        greetings = tone.greetings.mapValues { TemplatePool($0) }
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
        var capReport = OrdinaryBreakCapReport()
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
                attributions[cue.id] = attribution.resolvingTrackOrigins(in: tracks)
                return cue
            }
            let metadata = ["title": prev.title, "artist": prev.artist]
            // Opener: the greeting once per session, else artist focus or a back-announce.
            let shape = wantsBriefing ? BreakShape.plain : breakShape()
            if !hasGreeted, let greeting = greetings[dayPart]?.next(filling: [:], using: &phrasing) {
                cues.append(add(greeting, .presenter))
                hasGreeted = true
            } else if shape.artistOpener, let line = artistFocus.next(filling: metadata, using: &phrasing) {
                cues.append(add(line, .trackMetadata(trackIDs: [prev.id])))
            } else if let line = backAnnounce.next(filling: metadata, using: &phrasing) {
                cues.append(add(line, .trackMetadata(trackIDs: [prev.id])))
            }
            // Closing line: its own cue, attributed to the next track only, so it goes through
            // `VoiceRenderer.mayLeaveDevice` per cue exactly like the main segment.
            let closingLine = closing.next(filling: ["nextTitle": next.title, "nextArtist": next.artist], using: &phrasing)
            let closingFits = closingLine.map { estimate($0) <= Double(cadence.maxClosingSeconds) } ?? false

            if wantsBriefing {
                let limit = Double(cadence.maxBriefingBreakSeconds)
                var spent = cues.reduce(0) { $0 + $1.plannedSeconds } + estimate(closingLine)
                if let lead = briefingLead.next(filling: [:], using: &phrasing) {
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
                        // A short sign-off, only when it still fits the briefing cap.
                        if let outro = briefingOutro.next(filling: [:], using: &phrasing), spent + estimate(outro) <= limit {
                            cues.append(add(outro, .presenter))
                        }
                    } else {
                        attributions[leadCue.id] = nil
                    }
                }
            } else {
                // Main-segment color, then a continuation; dropped (continuation first) to fit.
                var extras: [NarrationCue] = []
                if let colored = colorLine(shape.color, dayPart: dayPart, station: station) {
                    extras.append(add(colored.text, colored.attribution))
                }
                if shape.continues, let line = continuation.next(filling: [:], using: &phrasing) {
                    extras.append(add(line, .presenter))
                }
                let closingInMain = closingFits ? 0 : estimate(closingLine)
                func main() -> Double { (cues + extras).reduce(0) { $0 + $1.plannedSeconds } + closingInMain }
                // The whole break, closing line included, counts toward the ordinary cap.
                func total() -> Double { (cues + extras).reduce(0) { $0 + $1.plannedSeconds } + estimate(closingLine) }
                var trimmed = 0
                while !extras.isEmpty, main() > Double(cadence.maxTransitionSeconds)
                        || total() > Double(cadence.maxOrdinaryBreakSeconds) {
                    attributions[extras.removeLast().id] = nil
                    trimmed += 1
                }
                if trimmed > 0 { capReport.trimmedOptionalLines[boundary] = trimmed }
                cues += extras
            }
            var talkOverCueID: UUID?
            if let closingLine {
                let cue = add(closingLine, .trackMetadata(trackIDs: [next.id]))
                cues.append(cue)
                if closingFits { talkOverCueID = cue.id }
            }
            guard !cues.isEmpty else { continue }
            let isBriefing = cues.contains { $0.isContent }
            var planned = DJBreak(afterTrack: boundary, cues: cues, attributions: attributions)
            planned.talkOverCueID = talkOverCueID
            if !isBriefing, planned.mainSeconds > Double(cadence.maxTransitionSeconds)
                || planned.estimatedSeconds > Double(cadence.maxOrdinaryBreakSeconds) {
                capReport.trimmedOptionalLines[boundary] = nil
                capReport.skippedOverCap.append(boundary)
                continue
            }
            breaks.append(planned)
            lastBreak = boundary
        }
        for cue in pending {
            outcomes[cue.id] = Self.carriesToLaterShow(cue) ? .deferred(.noTrackBoundary) : .dropped(.notCarriedForward)
        }
        let entries = (briefing?.cues ?? []).map { cue in
            NarrationScheduleEntry(cue: cue, outcome: outcomes[cue.id] ?? Self.unplaced(cue))
        }
        var sessionPlan = DJSessionPlan(breaks: breaks, briefingReport: NarrationScheduleReport(entries: entries))
        sessionPlan.ordinaryCapReport = capReport
        return sessionPlan
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

    private enum BreakColor { case none, station, atmosphere }

    private struct BreakShape {
        var artistOpener: Bool
        var color: BreakColor
        var continues: Bool
        static let plain = BreakShape(artistOpener: false, color: .none, continues: false)
    }

    /// About 20% artist-focus openers; color: 20% station ID, 25% time of day, else none;
    /// a continuation about two times in three. Whatever does not fit the main cap is dropped.
    private mutating func breakShape() -> BreakShape {
        let artist = editorial.next() % 100 < 20
        let color: BreakColor
        switch editorial.next() % 100 {
        case 0..<20: color = .station
        case 20..<45: color = .atmosphere
        default: color = .none
        }
        return BreakShape(artistOpener: artist, color: color, continues: editorial.next() % 100 < 65)
    }

    /// One color line with no track facts, or nil.
    private mutating func colorLine(_ color: BreakColor, dayPart: DayPart, station: String) -> (text: String, attribution: SpokenAttribution)? {
        switch color {
        case .none:
            return nil
        case .station:
            guard let name = EditorialStationName.usable(station),
                  let line = stationIDs.next(filling: ["station": name], using: &phrasing) else { return nil }
            // Only the built-in brand is fixed phrasing; any other name is the listener's own words.
            return (line, name == Self.builtInStationName ? .presenter : .stationName)
        case .atmosphere:
            guard let line = atmosphere[dayPart]?.next(filling: [:], using: &phrasing) else { return nil }
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
