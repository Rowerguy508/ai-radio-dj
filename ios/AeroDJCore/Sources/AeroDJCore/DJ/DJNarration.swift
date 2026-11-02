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
    /// Personal updates (approved briefing content cues) one break may carry (#332). Updates
    /// past the first wait for the next break; at the end of the queue the usual outcomes apply
    /// (a durable note is deferred, a calendar event or due task is dropped, never carried).
    /// At least 1. The 45 s briefing cap still bounds the break.
    public var maxPersonalUpdatesPerBreak: Int
    /// Cap for the show opener (`DJBreakShape.showOpener`), the first break of a session with no
    /// briefing content: the whole break, closing line and talk-over gap included, and its main
    /// segment. Optional lines (setup, then the time check) are dropped to fit. Held at or below
    /// `maxBriefingBreakSeconds`; ordinary breaks keep `maxOrdinaryBreakSeconds`.
    public var maxOpenerBreakSeconds: Int

    /// Build 34 default: the longest estimated opener is 16.3 s (warm, three-line greeting,
    /// station line, setup, time check, closing), so 22 s leaves headroom for slower voices.
    public static let defaultMaxOpenerBreakSeconds = 22
    /// #332 default: one personal update per break.
    public static let defaultMaxPersonalUpdatesPerBreak = 1
    /// #332 default: each personal update airs at most once per local calendar day
    /// (`PersonalUpdateLedger`, keyed by source item id).
    public static let defaultPersonalUpdatePlaysPerDay = 1

    public init(talkFraction: Double = 0.3, minSongsBetweenBreaks: Int = 2,
                maxTransitionSeconds: Int = 15, maxBriefingBreakSeconds: Int = 45,
                allowsBackToBack: Bool = false, maxClosingSeconds: Int = 4,
                maxOrdinaryBreakSeconds: Int = 12,
                maxPersonalUpdatesPerBreak: Int = DJCadence.defaultMaxPersonalUpdatesPerBreak,
                maxOpenerBreakSeconds: Int = DJCadence.defaultMaxOpenerBreakSeconds) {
        self.talkFraction = min(max(talkFraction, 0), 1)
        self.allowsBackToBack = allowsBackToBack
        self.minSongsBetweenBreaks = max(allowsBackToBack ? 0 : 1, minSongsBetweenBreaks)
        self.maxTransitionSeconds = maxTransitionSeconds
        self.maxClosingSeconds = max(0, maxClosingSeconds)
        self.maxBriefingBreakSeconds = maxBriefingBreakSeconds
        self.maxOrdinaryBreakSeconds = max(0, maxOrdinaryBreakSeconds)
        self.maxPersonalUpdatesPerBreak = max(1, maxPersonalUpdatesPerBreak)
        self.maxOpenerBreakSeconds = min(max(0, maxOpenerBreakSeconds), max(0, maxBriefingBreakSeconds))
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
        guard let pick = pickIndex(from: usable, usable: usable, using: &rng) else { return nil }
        return Self.fill(templates[pick], values)
    }

    /// Cycles `candidates` (a subset of `usable`) without repeats, never repeating the last pick
    /// across a reset. With `candidates == usable` this is the original selection, draw for draw.
    mutating func pickIndex(from candidates: [Int], usable: [Int], using rng: inout SeededGenerator) -> Int? {
        guard !candidates.isEmpty else { return nil }
        var fresh = candidates.filter { !used.contains($0) }
        if fresh.isEmpty {
            used.subtract(usable)
            fresh = candidates.count > 1 ? candidates.filter { $0 != last } : candidates
        }
        let pick = fresh[Int(rng.next() % UInt64(fresh.count))]
        used.insert(pick)
        last = pick
        return pick
    }

    /// Replaces `{key}` placeholders; nil if any is missing or empty. Track titles and artists
    /// go through `SpokenTitle` first, so catalog suffixes ("(Remastered 2011)", "[Explicit]")
    /// are never read aloud and "(feat. X)" is spoken as "featuring X".
    static func fill(_ template: String, _ values: [String: String]) -> String? {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            out += rest[..<open]
            let key = String(rest[rest.index(after: open)..<close])
            guard let value = values[key].map({ Self.spoken($0, key: key) }), !value.isEmpty else { return nil }
            out += value
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// Spoken form of one placeholder value. Only track fields are cleaned; the station name
    /// is already screened by `EditorialStationName`.
    static func spoken(_ value: String, key: String) -> String {
        switch key {
        case "title", "nextTitle": return SpokenTitle.clean(value)
        case "artist", "nextArtist": return SpokenTitle.cleanArtist(value)
        default: return value
        }
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
    /// Ordinary breaks: the optional lines (continuation, then station ID or time-of-day color),
    /// in the order the planner drops them. `DJBreakPreparer` drops them in this order when the
    /// measured audio runs over `DJCadence.maxOrdinaryBreakSeconds`. Never the opener or closing.
    /// Natural-shape breaks (lane 2) list theirs last-placed first: the extra (weather) line,
    /// then continuation, then color, matching the planner's own drop order.
    public var optionalCueIDs: [UUID] = []
    /// The natural shape this break was planned in (lane 2). Nil: the classic planner.
    public var shape: DJBreakShape? = nil
    /// The time check (lane 2 part 2), if this break has one. Presenter text only. Its words are
    /// written at render time (`DJBreakPreparer`), never from the plan-time reading.
    public var timeCheck: DJPlannedTimeCheck? = nil
    /// The time-check cue's id (`timeCheck?.cueID`).
    public var timeCheckCueID: UUID? { timeCheck?.cueID }
    /// When the time check was planned (`DJPlanClock.now` at planning; spacing only).
    public var timeCheckPlannedAt: Date? { timeCheck?.plannedAt }
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
    /// #347: time-check lines that did not air, by boundary (cue ID and reason code only).
    /// Not counted in `trimmedOptionalLines`: a time check is never trimmed to fit, only dropped.
    public var droppedTimeChecks: [Int: DJTimeCheckDrop] = [:]
    /// Build 34: show openers planned without a time check, by boundary, and why (reason code
    /// only). Never silent: an opener that cannot say the time truthfully says so here.
    public var omittedOpenerTimeChecks: [Int: DJOpenerTimeCheckOmission] = [:]
    public init() {}
}

/// Plans a session: where the DJ talks and what it says. State (template pools,
/// RNG) lives for the whole listening session so phrasing does not repeat.
public struct DJScriptWriter: Sendable {
    /// The app's own brand (`AppName.display`, OnAirly). The only station name a station ID may
    /// treat as fixed phrasing.
    public static let builtInStationName = AppName.display
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
    private var openerStation: TemplatePool
    private var openerSetup: [DayPart: TemplatePool]
    private var hasGreeted = false
    /// Natural break shapes (lane 2). Nil keeps the classic planner, line for line.
    public let shapes: DJBreakShapeConfig?
    /// Optional extra main-segment line per natural break (the weather seam). Nil: none.
    public var extraLineSource: (any DJBreakExtraLineSource)?
    private var shapePicker: DJBreakShapePicker?
    private var recentTemplates: RecentSpokenTemplates
    /// Natural breaks planned so far (id: first cue), newest last, for `forgetPlannedBreaks`.
    private var shapeLog: [(id: UUID, shape: DJBreakShape)] = []
    private var combined: TemplatePool
    /// Time-check pools by relation (`DJBreakShapeConfig.timeChecks`).
    private var timeCheckPools: [DJTimeCheckRelation: TemplatePool]
    /// Planned time checks (id: the break's first cue; at: the clock reading spoken), newest
    /// last, for the wall-time spacing rule. Forgotten with their break on a replan.
    private var timeCheckLog: [(id: UUID, at: Date)] = []
    /// The clock of the plan in progress. Nil: no time checks (the caller gave no clock).
    private var planClock: DJPlanClock?

    public init(cadence: DJCadence = .init(), seed: UInt64 = UInt64.random(in: .min ... .max), stationName: String = DJScriptWriter.builtInStationName,
                tone: EditorialTone = .warm, shapes: DJBreakShapeConfig? = nil) {
        self.cadence = cadence
        self.stationName = stationName
        self.tone = tone
        self.shapes = shapes
        // Its own stream, so turning shapes on never moves where breaks fall (`rng`).
        self.shapePicker = shapes.map { DJBreakShapePicker(config: $0, seed: seed &+ 0x5851_F42D_4C95_7F2D) }
        self.recentTemplates = RecentSpokenTemplates(window: shapes?.recentBreakWindow ?? 1, hereWindow: shapes?.hereWindow ?? 1)
        self.combined = TemplatePool(shapes?.combinedLines(for: tone) ?? [])
        let phrases = shapes?.timeChecks ?? DJTimeCheckPhrases(on: [], comingUp: [], justAfter: [])
        self.timeCheckPools = Dictionary(uniqueKeysWithValues: DJTimeCheckRelation.allCases.map {
            ($0, TemplatePool(phrases.templates(for: $0)))
        })
        self.openerStation = TemplatePool(tone.opener.station)
        self.openerSetup = tone.opener.setup.mapValues { TemplatePool($0) }
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
    ///   - clock: the planning clock (lane 2 time checks). Nil: no time checks in this plan. The
    ///     spoken time is `clock.now`, read once here; nothing in the writer reads the system clock.
    public mutating func plan(tracks: [DJTrack], briefing: NarrationHandoff?, hour: Int, stationName: String? = nil,
                              clock: DJPlanClock? = nil) -> DJSessionPlan {
        planClock = clock
        defer { planClock = nil }
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
            // Natural shapes (opt-in): ordinary breaks after the greeting.
            if !wantsBriefing, hasGreeted, shapePicker != nil {
                switch naturalBreak(boundary: boundary, prev: prev, next: next, station: station, dayPart: dayPart,
                                    tracks: tracks, order: &order) {
                case .planned(let planned):
                    breaks.append(planned)
                    lastBreak = boundary
                    continue
                case .musicOnly:
                    continue
                case .notApplicable:
                    break
                }
            }
            let metadata = ["title": prev.title, "artist": prev.artist]
            // Opener: the greeting once per session, else artist focus or a back-announce.
            let shape = wantsBriefing ? BreakShape.plain : breakShape()
            // Build 34: with natural shapes on, the session's first break is a show opener. A
            // briefing first break keeps the short greeting (the 45 s cap is the briefing's).
            if !hasGreeted, !wantsBriefing, shapes?.showOpener == true,
               let opener = showOpener(boundary: boundary, next: next, station: station, dayPart: dayPart,
                                       tracks: tracks, report: &capReport, order: &order) {
                breaks.append(opener)
                lastBreak = boundary
                hasGreeted = true
                continue
            }
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

            var optionalCueIDs: [UUID] = []
            if wantsBriefing {
                let limit = Double(cadence.maxBriefingBreakSeconds)
                var spent = cues.reduce(0) { $0 + $1.plannedSeconds } + estimate(closingLine)
                if let lead = briefingLead.next(filling: [:], using: &phrasing) {
                    let leadCue = add(lead, .presenter)
                    spent += leadCue.plannedSeconds
                    var taken: [NarrationCue] = []
                    while let cue = pending.first, taken.count < cadence.maxPersonalUpdatesPerBreak,
                          spent + cue.plannedSeconds <= limit {
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
                // The whole break, closing line included, counts toward the ordinary cap, plus the
                // `talkOverGapSeconds` pause before a talk-over closing line that follows other talk,
                // exactly as the rendered cap counts it (#320) and #344's natural planner does.
                let gapBeforeClosing = closingLine != nil && closingFits ? PreparedDJBreak.talkOverGapSeconds : 0
                func total() -> Double {
                    let spoken = cues + extras
                    return spoken.reduce(0) { $0 + $1.plannedSeconds } + estimate(closingLine) + (spoken.isEmpty ? 0 : gapBeforeClosing)
                }
                var trimmed = 0
                while !extras.isEmpty, main() > Double(cadence.maxTransitionSeconds)
                        || total() > Double(cadence.maxOrdinaryBreakSeconds) {
                    attributions[extras.removeLast().id] = nil
                    trimmed += 1
                }
                if trimmed > 0 { capReport.trimmedOptionalLines[boundary] = trimmed }
                optionalCueIDs = extras.reversed().map(\.id)   // drop order: continuation, then color
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
            if !isBriefing { planned.optionalCueIDs = optionalCueIDs }
            if !isBriefing, planned.mainSeconds > Double(cadence.maxTransitionSeconds)
                || Self.wholeSeconds(planned) > Double(cadence.maxOrdinaryBreakSeconds) {
                capReport.trimmedOptionalLines[boundary] = nil
                capReport.skippedOverCap.append(boundary)
                continue
            }
            breaks.append(planned)
            lastBreak = boundary
            if shapes != nil {
                // Natural shapes on: the classic and briefing breaks' own lines (never personal
                // text) count toward the cross-pool window too, so a later break never echoes them.
                let spoken = cues.filter { !$0.isContent }.map(\.text)
                recentTemplates.record(spoken, texts: spoken, id: cues.first?.id)
            }
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
    /// A planned ordinary break's whole length for the ordinary cap, on the same rule as the
    /// rendered cap (`DJBreakPreparer.BreakCap.spokenSeconds`): every line plus the
    /// `talkOverGapSeconds` pause before a talk-over closing line that follows other talk.
    static func wholeSeconds(_ djBreak: DJBreak) -> Double {
        let gap = djBreak.cues.count > 1 && djBreak.talkOverCueID != nil && djBreak.cues.last?.id == djBreak.talkOverCueID
            ? PreparedDJBreak.talkOverGapSeconds : 0
        return djBreak.estimatedSeconds + gap
    }

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

    /// A replan discarded these planned breaks before they aired: they leave the cross-pool
    /// memory and the shape history, so the next plan follows what actually aired (or is kept).
    /// No-op with natural shapes off. Pool cycling (`TemplatePool`) is not rewound.
    /// A discarded show opener never aired, so the next plan opens the show again.
    public mutating func forgetPlannedBreaks(_ discarded: [DJBreak]) {
        guard shapes != nil, var picker = shapePicker else { return }
        if discarded.contains(where: { $0.shape == .showOpener }) { hasGreeted = false }
        let ids = Set(discarded.compactMap { $0.cues.first?.id })
        guard !ids.isEmpty else { return }
        recentTemplates.forget(ids: ids)
        timeCheckLog.removeAll { ids.contains($0.id) }
        let before = shapeLog.count
        shapeLog.removeAll { ids.contains($0.id) }
        picker.restore(lastShape: shapeLog.last?.shape, forgetting: before - shapeLog.count)
        shapePicker = picker
    }

    /// The next break opens the show again (greeting, or the show opener with natural shapes on).
    /// For a new station: `DJBreakSession` calls this when `queueStarted` changes station (Fry).
    /// Anti-repeat memory is kept, so the new opener does not echo the last one.
    public mutating func greetAgain() {
        hasGreeted = false
    }

    /// Test hook: the next plan greets (or opens the show).
    var testHasGreeted: Bool { hasGreeted }
    /// Test hook: breaks in the cross-pool memory.
    var testRememberedBreaks: Int { recentTemplates.count }
    /// Test hook: planned time checks still counted for spacing.
    var testTimeCheckCount: Int { timeCheckLog.count }
    /// Test hook: the shape the next pick avoids.
    var testLastShape: DJBreakShape? { shapePicker?.lastShape }

    enum NaturalOutcome {
        case planned(DJBreak)
        /// Over a cap even with every optional line dropped: the boundary stays music-only.
        case musicOnly
        /// No natural shape fits this boundary; the classic planner takes it.
        case notApplicable
    }

    /// One ordinary break in a natural shape (`DJBreakShapes.swift`). Each cue is filled from
    /// one source, so attribution stays exact; the combined line names both tracks.
    private mutating func naturalBreak(boundary: Int, prev: DJTrack, next: DJTrack, station: String, dayPart: DayPart,
                                       tracks: [DJTrack], order: inout Int) -> NaturalOutcome {
        guard var picker = shapePicker, let config = shapes else { return .notApplicable }
        let metadata = ["title": prev.title, "artist": prev.artist]
        let nextValues = ["nextTitle": next.title, "nextArtist": next.artist]
        let bothValues = metadata.merging(nextValues) { a, _ in a }
        let stationName = EditorialStationName.usable(station)
        func fits(_ pool: TemplatePool, _ values: [String: String]) -> Bool {
            pool.templates.contains { TemplatePool.fill($0, values) != nil }
        }
        let context = DJBreakShapeContext(canBackAnnounce: fits(backAnnounce, metadata),
                                          canForwardSell: fits(closing, nextValues),
                                          stationIDUsable: stationName.map { fits(stationIDs, ["station": $0]) } ?? false,
                                          timeCheckAvailable: timeCheckReading(boundary: boundary, config: config) != nil)
        guard let shape = picker.pick(context) else { return .notApplicable }

        struct Line { var template: String; var text: String; var attribution: SpokenAttribution; var optional: Bool }
        var lines: [Line] = []
        let recent = recentTemplates
        func draw(_ pool: inout TemplatePool, _ values: [String: String], _ attribution: SpokenAttribution,
                  optional: Bool = false) -> Bool {
            let sameBreak = lines.map(\.template) + lines.map(\.text)
            let isOpener = lines.isEmpty
            func text(_ template: String) -> String? { TemplatePool.fill(template, values) }
            // 1: no identical line (template or spoken text) in the last `recentBreakWindow`
            //    breaks, plus the opener first-word and "Here's" rules.
            // 2: the same, with the first-word rule relaxed (the "Here's" rule kept).
            // 3: no identical line in the window (soft rules relaxed).
            // Optional lines stop there: if every candidate repeats, the line is left out.
            // Required lines (opener, closing, station ID) relax further rather than go silent:
            // 4: no identical line in the last two breaks; 5: not twice in this break.
            var tiers: [(String) -> Bool] = [
                { recent.rejects($0, text: text($0), sameBreak: sameBreak, isOpener: isOpener) },
                { recent.rejects($0, text: text($0), sameBreak: sameBreak, isOpener: isOpener, firstWordRule: false) },
                { recent.rejects($0, text: text($0), sameBreak: sameBreak, isOpener: isOpener, firstWordRule: false, hereWindow: 2) },
                { recent.repeats($0, text: text($0), sameBreak: sameBreak) },
            ]
            if !optional {
                tiers += [
                    { recent.repeats($0, text: text($0), sameBreak: sameBreak, window: 2) },
                    { recent.repeats($0, text: text($0), sameBreak: sameBreak, window: 0) },
                ]
            }
            if optional {
                // No fallback for optional lines: a pick must clear tier 3.
                guard pool.templates.contains(where: { text($0) != nil && !tiers[3]($0) }) else { return false }
            }
            guard let picked = pool.next(filling: values, avoiding: tiers, using: &phrasing) else { return false }
            lines.append(Line(template: picked.template, text: picked.text, attribution: attribution, optional: optional))
            return true
        }
        let prevAttribution = SpokenAttribution.trackMetadata(trackIDs: [prev.id])
        let nextAttribution = SpokenAttribution.trackMetadata(trackIDs: [next.id])
        var closingIndex: Int?
        var timeCheckLine: (template: String, relation: DJTimeCheckRelation, at: Date)?
        switch shape {
        case .classic:
            if phrasing.next() % 100 >= 20 || !draw(&artistFocus, metadata, prevAttribution) {
                _ = draw(&backAnnounce, metadata, prevAttribution)
            }
            if phrasing.next() % 100 < 40, var pool = atmosphere[dayPart] {
                _ = draw(&pool, [:], .presenter, optional: true)
                atmosphere[dayPart] = pool
            }
            if phrasing.next() % 100 < 50 { _ = draw(&continuation, [:], .presenter, optional: true) }
            if draw(&closing, nextValues, nextAttribution) { closingIndex = lines.count - 1 }
        case .backAnnounceOnly:
            _ = draw(&backAnnounce, metadata, prevAttribution)
        case .comingUpOnly:
            if draw(&closing, nextValues, nextAttribution) { closingIndex = lines.count - 1 }
        case .combined:
            if draw(&combined, bothValues, .trackMetadata(trackIDs: [prev.id, next.id])) {
                closingIndex = lines.count - 1
            } else if draw(&closing, nextValues, nextAttribution) {
                closingIndex = lines.count - 1
            }
        case .timeCheckIntro:
            // The time check is optional (dropped first-but-one to fit the cap, never after the
            // closing line). Presenter text only: no station name, no personal text.
            if let reading = timeCheckReading(boundary: boundary, config: config),
               var pool = timeCheckPools[reading.relation] {
                if draw(&pool, ["time": reading.time], .presenter, optional: true) {
                    timeCheckLine = (lines[lines.count - 1].template, reading.relation, reading.at)
                }
                timeCheckPools[reading.relation] = pool
            }
            if draw(&closing, nextValues, nextAttribution) { closingIndex = lines.count - 1 }
            // A time check never airs alone: without a closing line it is not spoken.
            else if timeCheckLine != nil { lines.removeAll { $0.template == timeCheckLine?.template }; timeCheckLine = nil }
        case .stationID:
            if let stationName {
                let attribution: SpokenAttribution = stationName == Self.builtInStationName ? .presenter : .stationName
                _ = draw(&stationIDs, ["station": stationName], attribution)
            }
            if draw(&closing, nextValues, nextAttribution) { closingIndex = lines.count - 1 }
        case .showOpener:
            break   // never picked (`DJBreakShapePicker.eligible`); `showOpener(...)` plans it
        }
        guard !lines.isEmpty else { return .notApplicable }

        // The extra-line seam: optional, before the closing line, dropped first.
        if let source = extraLineSource, let extra = source.extraLine(after: prev, before: next, shape: shape) {
            let text = extra.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never inside the anti-repeat window either: the same extra every break is dropped.
            if !text.isEmpty, !text.contains(where: { "{}\n\r".contains($0) }),
               !recent.repeats(text, text: text, sameBreak: lines.map(\.template) + lines.map(\.text)) {
                let line = Line(template: text, text: text, attribution: extra.attribution, optional: true)
                if let index = closingIndex { lines.insert(line, at: index); closingIndex = index + 1 }
                else { lines.append(line) }
            }
        }

        // Fit: drop optional lines, last added first (extra, then continuation, then color).
        func seconds(_ line: Line) -> Double { estimate(line.text) }
        func closingTalksOver() -> Bool {
            guard let closingIndex, closingIndex == lines.count - 1 else { return false }
            return seconds(lines[closingIndex]) <= Double(cadence.maxClosingSeconds)
        }
        // #320 counts the `talkOverGapSeconds` (0.3 s) pause before the closing line whenever
        // something plays before it, so the planner does too.
        func gap() -> Double {
            guard let closingIndex, closingIndex == lines.count - 1, lines.count > 1 else { return 0 }
            return PreparedDJBreak.talkOverGapSeconds
        }
        func spoken() -> Double { lines.reduce(0) { $0 + seconds($1) } }
        func total() -> Double { spoken() + gap() }
        func main() -> Double { spoken() - (closingTalksOver() ? seconds(lines[lines.count - 1]) : 0) }
        func overCap() -> Bool {
            total() > Double(cadence.maxOrdinaryBreakSeconds) || main() > Double(cadence.maxTransitionSeconds)
                || lines.count > config.maxCuesPerBreak
        }
        while overCap(), let drop = lines.indices.reversed().first(where: { lines[$0].optional }) {
            lines.remove(at: drop)
            if let index = closingIndex, drop < index { closingIndex = index - 1 }
        }
        if overCap() { return .musicOnly }

        var attributions: [UUID: SpokenAttribution] = [:]
        var cues: [NarrationCue] = []
        for line in lines {
            let cue = transitionCue(line.text, order: &order)
            attributions[cue.id] = line.attribution.resolvingTrackOrigins(in: tracks)
            cues.append(cue)
        }
        var planned = DJBreak(afterTrack: boundary, cues: cues, attributions: attributions)
        if closingTalksOver() { planned.talkOverCueID = cues.last?.id }
        planned.shape = shape
        if let timeCheckLine, let index = lines.firstIndex(where: { $0.optional && $0.template == timeCheckLine.template }),
           let id = cues.first?.id {
            planned.timeCheck = DJPlannedTimeCheck(
                cueID: cues[index].id, plannedAt: timeCheckLine.at,
                templates: timeCheckTemplates(drawn: timeCheckLine.template, relation: timeCheckLine.relation),
                calendar: planClock?.calendar ?? .autoupdatingCurrent, style: planClock?.style ?? .twelveHour)
            timeCheckLog.append((id, timeCheckLine.at))
            if timeCheckLog.count > RecentSpokenTemplates.historyLimit { timeCheckLog.removeFirst() }
        }
        // #320's measured-audio trim drops these in order, the same order as the fit above: the
        // last optional line first, so the extra (weather) line before the closing line goes first,
        // then continuation, then color. Never the opener, a required line or the closing line.
        planned.optionalCueIDs = zip(lines, cues).filter { $0.0.optional }.map { $0.1.id }.reversed()
        picker.record(shape)
        shapePicker = picker
        recentTemplates.record(lines.map(\.template), texts: lines.map(\.text), id: cues.first?.id)
        if let id = cues.first?.id {
            shapeLog.append((id, shape))
            if shapeLog.count > RecentSpokenTemplates.historyLimit { shapeLog.removeFirst(shapeLog.count - RecentSpokenTemplates.historyLimit) }
        }
        return .planned(planned)
    }

    /// The time check this boundary may speak, or nil when a rule rules it out:
    ///   - no planning clock (the caller gave none),
    ///   - the boundary's known air time is more than `timeCheckMaxDriftSeconds` from `clock.now`
    ///     (the spoken time would be wrong on air),
    ///   - another planned or aired time check is within `timeCheckMinSpacingSeconds` of wall time.
    /// The first-break-after-the-greeting and not-twice-in-a-row rules live in the picker.
    private func timeCheckReading(boundary: Int, config: DJBreakShapeConfig)
        -> (time: String, relation: DJTimeCheckRelation, at: Date)? {
        if case .success(let reading) = timeCheckAvailability(boundary: boundary, config: config) { return reading }
        return nil
    }

    struct TimeCheckUnavailable: Error { let reason: DJOpenerTimeCheckOmission }

    /// `timeCheckReading`, with the rule that ruled it out (the opener reports it).
    private func timeCheckAvailability(boundary: Int, config: DJBreakShapeConfig)
        -> Result<(time: String, relation: DJTimeCheckRelation, at: Date), TimeCheckUnavailable> {
        guard let clock = planClock else { return .failure(.init(reason: .noClock)) }
        if let air = clock.airTimes[boundary],
           abs(air.timeIntervalSince(clock.now)) > config.timeCheckMaxDriftSeconds {
            return .failure(.init(reason: .airTimeDrift))
        }
        guard !timeCheckLog.contains(where: { abs(clock.now.timeIntervalSince($0.at)) < config.timeCheckMinSpacingSeconds })
        else { return .failure(.init(reason: .spacing)) }
        let reading = DJTimeCheck.reading(clock.now, calendar: clock.calendar, style: clock.style)
        return .success((reading.time, reading.relation, clock.now))
    }

    /// The show opener (build 34; `DJShowOpener.swift`): greeting and station name in one cue,
    /// a mood line, the time check when the rules allow, then the first closing line. At most
    /// `maxCuesPerBreak` cues, all within `DJCadence.maxOpenerBreakSeconds` at the word-rate
    /// estimate (main segment and whole break). The mood line, then the time check, drop to fit.
    /// Nil when no greeting exists for the day part or the required lines alone do not fit: the
    /// classic short greeting takes the boundary instead, under the ordinary caps.
    private mutating func showOpener(boundary: Int, next: DJTrack, station: String, dayPart: DayPart,
                                     tracks: [DJTrack], report: inout OrdinaryBreakCapReport,
                                     order: inout Int) -> DJBreak? {
        guard let config = shapes, var greetingPool = greetings[dayPart] else { return nil }
        struct Line {
            /// One entry per pool line drawn (the welcome cue joins two), with its spoken text.
            var templates: [String]; var texts: [String]; var attribution: SpokenAttribution
            var kind: Kind
            var text: String { texts.joined(separator: " ") }
            enum Kind { case welcome, setup, timeCheck, closing }
        }
        var lines: [Line] = []
        let recent = recentTemplates
        // The same anti-repeat tiers as `naturalBreak`. Optional lines must clear tier 3 or are
        // left out; required lines relax rather than go silent.
        func draw(_ pool: inout TemplatePool, _ values: [String: String], optional: Bool,
                  extra: [String] = []) -> (template: String, text: String)? {
            let sameBreak = lines.flatMap(\.templates) + lines.flatMap(\.texts) + extra
            let isOpener = lines.isEmpty && extra.isEmpty
            func text(_ template: String) -> String? { TemplatePool.fill(template, values) }
            var tiers: [(String) -> Bool] = [
                { recent.rejects($0, text: text($0), sameBreak: sameBreak, isOpener: isOpener) },
                { recent.rejects($0, text: text($0), sameBreak: sameBreak, isOpener: isOpener, firstWordRule: false) },
                { recent.rejects($0, text: text($0), sameBreak: sameBreak, isOpener: isOpener, firstWordRule: false, hereWindow: 2) },
                { recent.repeats($0, text: text($0), sameBreak: sameBreak) },
            ]
            if optional {
                guard pool.templates.contains(where: { text($0) != nil && !tiers[3]($0) }) else { return nil }
            } else {
                tiers += [
                    { recent.repeats($0, text: text($0), sameBreak: sameBreak, window: 2) },
                    { recent.repeats($0, text: text($0), sameBreak: sameBreak, window: 0) },
                ]
            }
            return pool.next(filling: values, avoiding: tiers, using: &phrasing)
        }

        // 1. Welcome: the day-part greeting, then the real station name, as one cue. The typed
        //    name is the listener's own words (`.stationName`, on-device only); the built-in
        //    brand is fixed phrasing. No usable name: the greeting airs alone.
        guard let greeting = draw(&greetingPool, [:], optional: false) else { return nil }
        greetings[dayPart] = greetingPool
        var welcome = Line(templates: [greeting.template], texts: [greeting.text], attribution: .presenter, kind: .welcome)
        if let name = EditorialStationName.usable(station),
           let named = draw(&openerStation, ["station": name], optional: false, extra: [greeting.template, greeting.text]) {
            welcome.templates.append(named.template)
            welcome.texts.append(named.text)
            if name != Self.builtInStationName { welcome.attribution = .stationName }
        }
        lines.append(welcome)
        // 2. Mood (optional).
        if var pool = openerSetup[dayPart] {
            if let setup = draw(&pool, [:], optional: true) {
                lines.append(Line(templates: [setup.template], texts: [setup.text], attribution: .presenter, kind: .setup))
            }
            openerSetup[dayPart] = pool
        }
        // 3. The time (optional), from the time-check machinery only. Never invented: no
        //    truthful reading, no time, and the reason is reported.
        var timeCheck: (template: String, relation: DJTimeCheckRelation, at: Date)?
        switch timeCheckAvailability(boundary: boundary, config: config) {
        case .failure(let unavailable):
            report.omittedOpenerTimeChecks[boundary] = unavailable.reason
        case .success(let reading):
            if var pool = timeCheckPools[reading.relation], !pool.templates.isEmpty,
               let line = draw(&pool, ["time": reading.time], optional: true) {
                lines.append(Line(templates: [line.template], texts: [line.text], attribution: .presenter, kind: .timeCheck))
                timeCheck = (line.template, reading.relation, reading.at)
                timeCheckPools[reading.relation] = pool
            } else {
                report.omittedOpenerTimeChecks[boundary] = .noPhrasing
            }
        }
        // 4. The first song's intro, talk-over when it fits the closing cap.
        if let line = draw(&closing, ["nextTitle": next.title, "nextArtist": next.artist], optional: false) {
            lines.append(Line(templates: [line.template], texts: [line.text],
                              attribution: .trackMetadata(trackIDs: [next.id]), kind: .closing))
        }

        // Fit the opener cap: drop the mood line, then the time check. Same arithmetic as the
        // ordinary cap (#320): the 0.3 s gap before a talk-over closing line that follows talk.
        let cap = Double(cadence.maxOpenerBreakSeconds)
        func seconds(_ line: Line) -> Double { estimate(line.text) }
        func closingTalksOver() -> Bool {
            guard let last = lines.last, last.kind == .closing else { return false }
            return seconds(last) <= Double(cadence.maxClosingSeconds)
        }
        func spoken() -> Double { lines.reduce(0) { $0 + seconds($1) } }
        func total() -> Double { spoken() + (closingTalksOver() && lines.count > 1 ? PreparedDJBreak.talkOverGapSeconds : 0) }
        func main() -> Double { spoken() - (closingTalksOver() ? seconds(lines[lines.count - 1]) : 0) }
        func overCap() -> Bool { total() > cap || main() > cap || lines.count > config.maxCuesPerBreak }
        for kind in [Line.Kind.setup, .timeCheck] where overCap() {
            guard let index = lines.firstIndex(where: { $0.kind == kind }) else { continue }
            lines.remove(at: index)
            if kind == .timeCheck {
                timeCheck = nil
                report.omittedOpenerTimeChecks[boundary] = .overCap
            } else {
                report.trimmedOptionalLines[boundary, default: 0] += 1
            }
        }
        guard !overCap() else {
            report.trimmedOptionalLines[boundary] = nil
            report.omittedOpenerTimeChecks[boundary] = nil
            return nil
        }

        var attributions: [UUID: SpokenAttribution] = [:]
        var cues: [NarrationCue] = []
        for line in lines {
            let cue = transitionCue(line.text, order: &order)
            attributions[cue.id] = line.attribution.resolvingTrackOrigins(in: tracks)
            cues.append(cue)
        }
        var planned = DJBreak(afterTrack: boundary, cues: cues, attributions: attributions)
        if closingTalksOver() { planned.talkOverCueID = cues.last?.id }
        planned.shape = .showOpener
        if let timeCheck, let index = lines.firstIndex(where: { $0.kind == .timeCheck }), let id = cues.first?.id {
            planned.timeCheck = DJPlannedTimeCheck(
                cueID: cues[index].id, plannedAt: timeCheck.at,
                templates: timeCheckTemplates(drawn: timeCheck.template, relation: timeCheck.relation),
                calendar: planClock?.calendar ?? .autoupdatingCurrent, style: planClock?.style ?? .twelveHour)
            timeCheckLog.append((id, timeCheck.at))
            if timeCheckLog.count > RecentSpokenTemplates.historyLimit { timeCheckLog.removeFirst() }
        }
        // #320's measured trim drops these, last first: the time check (the preparer renders it
        // late and drops it on its own, #347), then the mood line. Never the welcome or closing.
        planned.optionalCueIDs = zip(lines, cues).filter { $0.0.kind == .setup || $0.0.kind == .timeCheck }
            .map { $0.1.id }.reversed()
        recentTemplates.record(lines.flatMap(\.templates), texts: lines.flatMap(\.texts), id: cues.first?.id)
        return planned
    }

    /// The drawn phrasing's slot in its relation's pool, applied to every relation's pool, so the
    /// render-time reading keeps the plan's pick whichever way the clock then rounds.
    private func timeCheckTemplates(drawn: String, relation: DJTimeCheckRelation) -> [DJTimeCheckRelation: String] {
        let slot = timeCheckPools[relation]?.templates.firstIndex(of: drawn) ?? 0
        var out: [DJTimeCheckRelation: String] = [:]
        for r in DJTimeCheckRelation.allCases {
            guard let list = timeCheckPools[r]?.templates, !list.isEmpty else { continue }
            out[r] = r == relation ? drawn : list[slot % list.count]
        }
        return out
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
