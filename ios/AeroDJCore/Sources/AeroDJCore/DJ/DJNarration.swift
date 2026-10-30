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

    public init(talkFraction: Double = 0.3, minSongsBetweenBreaks: Int = 2,
                maxTransitionSeconds: Int = 15, maxBriefingBreakSeconds: Int = 45,
                allowsBackToBack: Bool = false, maxClosingSeconds: Int = 4) {
        self.talkFraction = min(max(talkFraction, 0), 1)
        self.allowsBackToBack = allowsBackToBack
        self.minSongsBetweenBreaks = max(allowsBackToBack ? 0 : 1, minSongsBetweenBreaks)
        self.maxTransitionSeconds = maxTransitionSeconds
        self.maxClosingSeconds = max(0, maxClosingSeconds)
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
    /// The natural shape this break was planned in (lane 2). Nil: the classic planner.
    public var shape: DJBreakShape? = nil
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
    private var hasGreeted = false
    /// Natural break shapes (lane 2). Nil keeps the classic planner, line for line.
    public let shapes: DJBreakShapeConfig?
    /// Optional extra main-segment line per natural break (the weather seam). Nil: none.
    public var extraLineSource: (any DJBreakExtraLineSource)?
    private var shapePicker: DJBreakShapePicker?
    private var recentTemplates: RecentSpokenTemplates
    private var combined: TemplatePool

    public init(cadence: DJCadence = .init(), seed: UInt64 = UInt64.random(in: .min ... .max), stationName: String = DJScriptWriter.builtInStationName,
                tone: EditorialTone = .warm, shapes: DJBreakShapeConfig? = nil) {
        self.cadence = cadence
        self.stationName = stationName
        self.tone = tone
        self.shapes = shapes
        // Its own stream, so turning shapes on never moves where breaks fall (`rng`).
        self.shapePicker = shapes.map { DJBreakShapePicker(config: $0, seed: seed &+ 0x5851_F42D_4C95_7F2D) }
        self.recentTemplates = RecentSpokenTemplates(window: shapes?.recentBreakWindow ?? 1, hereWindow: shapes?.hereWindow ?? 1)
        self.combined = TemplatePool(shapes?.combined ?? [])
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
                while !extras.isEmpty, main() > Double(cadence.maxTransitionSeconds) {
                    attributions[extras.removeLast().id] = nil
                }
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
            if !isBriefing, planned.mainSeconds > Double(cadence.maxTransitionSeconds) { continue }
            breaks.append(planned)
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
                                          timeCheckAvailable: false)
        guard let shape = picker.pick(context) else { return .notApplicable }

        struct Line { var template: String; var text: String; var attribution: SpokenAttribution; var optional: Bool }
        var lines: [Line] = []
        let recent = recentTemplates
        func draw(_ pool: inout TemplatePool, _ values: [String: String], _ attribution: SpokenAttribution,
                  optional: Bool = false) -> Bool {
            let sameBreak = lines.map(\.template)
            let isOpener = lines.isEmpty
            // Full window and opener rules; then the rules over the last two breaks; then just
            // the last two breaks; then this break only.
            let tiers: [(String) -> Bool] = [
                { recent.rejects($0, sameBreak: sameBreak, isOpener: isOpener) },
                { recent.rejects($0, sameBreak: sameBreak, isOpener: isOpener, window: 2) },
                { recent.rejects($0, sameBreak: sameBreak, isOpener: isOpener, window: 2, strict: false) },
                { recent.rejects($0, sameBreak: sameBreak, isOpener: isOpener, window: 0, strict: false) },
            ]
            guard let picked = pool.next(filling: values, avoiding: tiers, using: &phrasing) else { return false }
            lines.append(Line(template: picked.template, text: picked.text, attribution: attribution, optional: optional))
            return true
        }
        let prevAttribution = SpokenAttribution.trackMetadata(trackIDs: [prev.id])
        let nextAttribution = SpokenAttribution.trackMetadata(trackIDs: [next.id])
        var closingIndex: Int?
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
            return .notApplicable   // no clock source in this slice
        case .stationID:
            if let stationName {
                let attribution: SpokenAttribution = stationName == Self.builtInStationName ? .presenter : .stationName
                _ = draw(&stationIDs, ["station": stationName], attribution)
            }
            if draw(&closing, nextValues, nextAttribution) { closingIndex = lines.count - 1 }
        }
        guard !lines.isEmpty else { return .notApplicable }

        // The extra-line seam: optional, before the closing line, dropped first.
        if let source = extraLineSource, let extra = source.extraLine(after: prev, before: next, shape: shape) {
            let text = extra.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !text.contains(where: { "{}\n\r".contains($0) }) {
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
        func total() -> Double { lines.reduce(0) { $0 + seconds($1) } }
        func main() -> Double { total() - (closingTalksOver() ? seconds(lines[lines.count - 1]) : 0) }
        func overCap() -> Bool {
            total() > Double(config.maxBreakSeconds) || main() > Double(cadence.maxTransitionSeconds)
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
        picker.record(shape)
        shapePicker = picker
        recentTemplates.record(lines.map(\.template))
        return .planned(planned)
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
