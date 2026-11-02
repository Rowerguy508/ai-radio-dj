import Foundation

// Natural break shapes (lane 2, -Fry). `DJBreakSession` plans with `shapes: .natural`. A bare
// `DJScriptWriter` still defaults to `shapes: nil`, the classic planner, which keeps the pinned
// classic lines in the existing tests. Combined lines come from the tone (`EditorialTone.combined`).
//
// Rules, all enforced here and tested in `DJBreakShapesTests`:
//   - Shapes: back-announce only, coming-up only, combined ("that was X, here's Y"), a short
//     station ID, the classic shape, and a time check plus intro (offered only when the plan has
//     a clock and the time-check rules allow it; see `DJTimeCheck.swift`).
//   - Never the same shape twice in a row.
//   - Station ID never in two consecutive breaks, and never in the first two breaks after the
//     greeting.
//   - Cross-pool anti-repeat: a template used in the last `recentBreakWindow` breaks is not
//     picked again while another fits; an opener never starts with the previous break's opener
//     word; at most one line starting "Here's" in any `hereWindow` consecutive breaks.
//   - Every ordinary break fits `DJCadence.maxOrdinaryBreakSeconds` (12 s, closing line and the
//     0.3 s pause before it included; the station's cadence, as classic breaks) and the main
//     segment cap, at the word-rate estimate, with at most `maxCuesPerBreak` (4) cues, which is
//     the proxy's `MAX_CLOUD_RENDERS_PER_BREAK`.
//   - Templates add no facts: placeholders are filled only from track metadata or the station name.

/// The shape of one ordinary (non-briefing) break.
public enum DJBreakShape: String, CaseIterable, Sendable {
    /// Opener, optional color and continuation, closing line (the pre-lane-2 shape).
    case classic
    /// Names the song that just played; the next song starts with no intro.
    case backAnnounceOnly
    /// One quick forward-sell over the next intro.
    case comingUpOnly
    /// One breath: "That was {title}. Here's {nextTitle}."
    case combined
    /// A short time check, then the closing line. Needs a planning clock (`DJPlanClock`).
    case timeCheckIntro
    /// A short station ID, then the closing line.
    case stationID
}

/// Tuning for natural shapes. Values are the defaults reviewers check against.
public struct DJBreakShapeConfig: Equatable, Sendable {
    /// Relative weights. A zero or missing weight is never picked.
    public var weights: [DJBreakShape: Int]
    /// A template used in this many most recent breaks is avoided while another fits.
    public var recentBreakWindow: Int
    /// At most one line starting "Here's" in this many consecutive breaks.
    public var hereWindow: Int
    /// Not the planner's cap any more: natural breaks cap at the station cadence's
    /// `DJCadence.maxOrdinaryBreakSeconds`, one knob for classic and natural breaks (#339
    /// follow-up). Kept, defaulting to the same 12 s, so existing callers still build.
    public var maxBreakSeconds: Int
    /// Cues per ordinary break; matches the proxy's `MAX_CLOUD_RENDERS_PER_BREAK` (4).
    public var maxCuesPerBreak: Int
    /// Breaks after the greeting that may not carry a station ID.
    public var stationIDGraceBreaks: Int
    /// Combined back-announce plus forward-sell lines. `{title}`/`{artist}` name the song that
    /// just played, `{nextTitle}`/`{nextArtist}` the next one. Left at `defaultCombined`, the
    /// writer speaks its tone's own bank (`EditorialTone.combined`); any other list overrides it.
    public var combined: [String]
    /// Time checks (part 2): breaks after the greeting that may not carry one (1: never the
    /// first break after the greeting).
    public var timeCheckGraceBreaks: Int
    /// At most one time check per this much wall time (planning clock), planned or aired.
    public var timeCheckMinSpacingSeconds: Double
    /// A time check is skipped when the break's known air time is further than this from the
    /// planning clock (the spoken time would be off).
    public var timeCheckMaxDriftSeconds: Double
    /// Time-check copy. Lives here next to `combined` until Echo moves it into `EditorialTone`.
    public var timeChecks: DJTimeCheckPhrases

    public init(weights: [DJBreakShape: Int] = DJBreakShapeConfig.defaultWeights, recentBreakWindow: Int = 6,
                hereWindow: Int = 3, maxBreakSeconds: Int = 12, maxCuesPerBreak: Int = 4,
                stationIDGraceBreaks: Int = 2, combined: [String] = DJBreakShapeConfig.defaultCombined,
                timeCheckGraceBreaks: Int = 1, timeCheckMinSpacingSeconds: Double = 30 * 60,
                timeCheckMaxDriftSeconds: Double = 2 * 60, timeChecks: DJTimeCheckPhrases = DJTimeCheckPhrases()) {
        self.timeCheckGraceBreaks = max(0, timeCheckGraceBreaks)
        self.timeCheckMinSpacingSeconds = max(0, timeCheckMinSpacingSeconds)
        self.timeCheckMaxDriftSeconds = max(0, timeCheckMaxDriftSeconds)
        self.timeChecks = timeChecks
        self.weights = weights
        self.recentBreakWindow = max(1, recentBreakWindow)
        self.hereWindow = max(1, hereWindow)
        self.maxBreakSeconds = max(1, maxBreakSeconds)
        self.maxCuesPerBreak = max(1, maxCuesPerBreak)
        self.stationIDGraceBreaks = max(0, stationIDGraceBreaks)
        self.combined = combined
    }

    public static let natural = DJBreakShapeConfig()

    /// Combined about 30% of eligible breaks, as in the plan.
    public static let defaultWeights: [DJBreakShape: Int] = [
        .combined: 30, .classic: 20, .comingUpOnly: 20, .backAnnounceOnly: 10, .stationID: 10, .timeCheckIntro: 10,
    ]

    /// The default marker: `warm`'s combined bank (lane 4 moved the copy into `EditorialTone`).
    public static let defaultCombined = EditorialTone.warm.combined

    /// The combined lines a writer with `tone` speaks: the tone's bank unless overridden.
    public func combinedLines(for tone: EditorialTone) -> [String] {
        combined == Self.defaultCombined ? tone.combined : combined
    }
}

/// What the picker may know about a boundary.
public struct DJBreakShapeContext: Equatable, Sendable {
    /// The song that just played has a title or artist to name.
    public var canBackAnnounce: Bool
    /// The next song has a title or artist to name.
    public var canForwardSell: Bool
    /// The station name is speakable (`EditorialStationName.usable`).
    public var stationIDUsable: Bool
    /// The plan has a clock and the drift and spacing rules allow a time check here.
    public var timeCheckAvailable: Bool

    public init(canBackAnnounce: Bool = true, canForwardSell: Bool = true, stationIDUsable: Bool = true,
                timeCheckAvailable: Bool = false) {
        self.canBackAnnounce = canBackAnnounce
        self.canForwardSell = canForwardSell
        self.stationIDUsable = stationIDUsable
        self.timeCheckAvailable = timeCheckAvailable
    }
}

/// Seeded, injectable shape picker. Holds only shape history.
public struct DJBreakShapePicker: Sendable {
    public let config: DJBreakShapeConfig
    private var rng: SeededGenerator
    public private(set) var lastShape: DJBreakShape?
    /// Ordinary breaks picked since the greeting.
    public private(set) var breaksSinceGreeting = 0

    public init(config: DJBreakShapeConfig = .natural, seed: UInt64) {
        self.config = config
        self.rng = SeededGenerator(seed: seed)
    }

    /// Shapes allowed at this boundary, before weighting.
    public func eligible(_ context: DJBreakShapeContext) -> [DJBreakShape] {
        DJBreakShape.allCases.filter { shape in
            guard (config.weights[shape] ?? 0) > 0 else { return false }
            switch shape {
            case .classic: return context.canBackAnnounce || context.canForwardSell
            case .backAnnounceOnly: return context.canBackAnnounce
            case .comingUpOnly: return context.canForwardSell
            case .combined: return context.canBackAnnounce && context.canForwardSell
            case .timeCheckIntro:
                return context.timeCheckAvailable && context.canForwardSell
                    && breaksSinceGreeting >= config.timeCheckGraceBreaks
            case .stationID:
                return context.stationIDUsable && context.canForwardSell
                    && lastShape != .stationID && breaksSinceGreeting >= config.stationIDGraceBreaks
            }
        }
    }

    /// Picks a shape: weighted, never the last shape again while another is eligible.
    /// Nil when nothing is eligible (the caller falls back to the classic planner).
    public mutating func pick(_ context: DJBreakShapeContext) -> DJBreakShape? {
        var options = eligible(context)
        if options.count > 1, let lastShape { options.removeAll { $0 == lastShape } }
        guard !options.isEmpty else { return nil }
        let total = options.reduce(0) { $0 + (config.weights[$1] ?? 0) }
        var roll = Int(rng.next() % UInt64(total))
        var chosen = options[options.count - 1]
        for shape in options {
            let weight = config.weights[shape] ?? 0
            if roll < weight { chosen = shape; break }
            roll -= weight
        }
        return chosen
    }

    /// Records the shape that actually aired (it may differ from the pick after a fallback).
    public mutating func record(_ shape: DJBreakShape) {
        lastShape = shape
        breaksSinceGreeting += 1
    }

    /// Rolls shape history back after planned breaks are discarded (a replan): `lastShape` is
    /// the newest shape still kept, and the discarded breaks no longer count since the greeting.
    /// The random stream is not rewound.
    public mutating func restore(lastShape: DJBreakShape?, forgetting count: Int) {
        self.lastShape = lastShape
        breaksSinceGreeting = max(0, breaksSinceGreeting - count)
    }
}

/// Cross-pool memory of what the last few breaks said. Each aired line is kept by template
/// (so "Here's {nextTitle}." counts as a repeat even with a different song) and by spoken text
/// (so the same words from two different pools, or from a classic break, also count). This is
/// what stops a line shared by several pools ("Glad you're here.") from airing twice in a row.
/// Sentences of three or more words are compared on their own as well, so a phrase two pools
/// share inside different lines counts as a repeat.
public struct RecentSpokenTemplates: Sendable {
    public let window: Int
    public let hereWindow: Int
    /// Breaks kept (planned or aired). Larger than any plan, so forgetting a replanned suffix
    /// never leaves the aired breaks before it evicted.
    public static let historyLimit = 1024
    private struct Entry: Sendable { var key: String; var text: String; var phrases: Set<String> }
    private struct Aired: Sendable { var id: UUID?; var entries: [Entry] }
    /// Sentences this long or longer count as phrases: "Glad you're here." inside
    /// "{station}. Glad you're here." and "Still up? Glad you're here." is the same phrase.
    public static let minPhraseWords = 3
    private var history: [Aired] = []

    public init(window: Int, hereWindow: Int) {
        self.window = max(1, window)
        self.hereWindow = max(1, hereWindow)
    }

    static func key(_ template: String) -> String {
        template.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Spoken-text key: case, spacing and end punctuation do not make two lines different.
    static func textKey(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    /// Sentence-level keys of a spoken line, for sentences of at least `minPhraseWords` words.
    static func phrases(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { ".!?…".contains($0) }).map { textKey(String($0)) }
            .filter { $0.split(separator: " ").count >= minPhraseWords })
    }

    static func firstWord(_ template: String) -> String {
        let word = template.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func startsWithHere(_ template: String) -> Bool {
        firstWord(template) == "here's" || firstWord(template) == "heres"
    }

    /// True when the same line (by template or by spoken text) aired in the last `window` breaks
    /// (nil: the full window) or already sits in `sameBreak` (templates chosen for this break).
    /// A sentence of `minPhraseWords`+ words shared with such a line counts as the same line too.
    public func repeats(_ template: String, text: String? = nil, sameBreak: [String], window: Int? = nil) -> Bool {
        let key = Self.key(template)
        let spoken = text.map(Self.textKey)
        let phrases = text.map(Self.phrases) ?? []
        if sameBreak.map(Self.key).contains(key) { return true }
        if let spoken, sameBreak.map(Self.textKey).contains(spoken) { return true }
        if !phrases.isEmpty, sameBreak.contains(where: { !Self.phrases($0).isDisjoint(with: phrases) }) { return true }
        return history.suffix(window ?? self.window).contains { aired in
            aired.entries.contains { $0.key == key || (spoken != nil && $0.text == spoken) || !$0.phrases.isDisjoint(with: phrases) }
        }
    }

    /// True when `template` should be avoided in the break being built. `sameBreak` holds the
    /// templates already chosen for it; `isOpener` adds the first-word rule.
    /// `window` narrows the lookback (nil: the full window); `strict` false keeps only the
    /// same-break and lookback checks.
    /// `firstWordRule` false relaxes only the opener first-word rule.
    public func rejects(_ template: String, text: String? = nil, sameBreak: [String], isOpener: Bool,
                        window: Int? = nil, strict: Bool = true, firstWordRule: Bool = true,
                        hereWindow: Int? = nil) -> Bool {
        if repeats(template, text: text, sameBreak: sameBreak, window: window) { return true }
        guard strict else { return false }
        if firstWordRule, isOpener, let previous = history.last?.entries.first, previous.key.isEmpty == false,
           Self.firstWord(previous.key) == Self.firstWord(template) { return true }
        if Self.startsWithHere(template) {
            let recent = history.suffix((hereWindow ?? self.hereWindow) - 1).flatMap { $0.entries.map(\.key) } + sameBreak
            if recent.contains(where: Self.startsWithHere) { return true }
        }
        return false
    }

    /// Records one aired break, opener first. `texts` (same order) are the spoken lines; when
    /// omitted the templates stand in for them. Classic and briefing breaks are recorded with
    /// their spoken text as both, so natural breaks never echo them.
    /// `id` names the break (its first cue), so a replan can `forget` it.
    public mutating func record(_ templates: [String], texts: [String]? = nil, id: UUID? = nil) {
        let spoken = texts ?? templates
        history.append(Aired(id: id, entries: zip(templates, spoken).map {
            Entry(key: Self.key($0), text: Self.textKey($1), phrases: Self.phrases($1))
        }))
        // Headroom past the window, so forgetting a replan's discarded breaks leaves a full window.
        // Plans record every break ahead of airing and a replan forgets the planned-away ones,
        // so the history must hold a whole plan plus what aired before it, not just the window.
        let keep = Self.historyLimit
        if history.count > keep { history.removeFirst(history.count - keep) }
    }

    /// Drops planned breaks that will never air (a replan discarded them).
    public mutating func forget(ids: Set<UUID>) {
        history.removeAll { $0.id.map(ids.contains) ?? false }
    }

    public var lastBreak: [String] { history.last?.entries.map(\.key) ?? [] }
    /// Breaks remembered, newest last (test hook).
    var count: Int { history.count }
}

/// One extra line a future source (Atlas's weather) may offer for a break. It is optional
/// main-segment talk: dropped first to fit the caps, and never placed after the closing line.
public struct DJExtraLine: Equatable, Sendable {
    public var text: String
    public var attribution: SpokenAttribution
    public init(text: String, attribution: SpokenAttribution) {
        self.text = text
        self.attribution = attribution
    }
}

/// Seam for an optional extra line (weather is the planned first user). Not implemented here.
public protocol DJBreakExtraLineSource: Sendable {
    func extraLine(after previous: DJTrack, before next: DJTrack, shape: DJBreakShape) -> DJExtraLine?
}

extension TemplatePool {
    /// Like `next(filling:using:)`, but tries `tiers` strictest first: the first tier that leaves
    /// any usable template is the candidate set; if every tier rejects everything it relaxes to
    /// the plain pick rather than go silent. Returns the template too, for cross-pool memory.
    public mutating func next(filling values: [String: String], avoiding tiers: [(String) -> Bool],
                              using rng: inout SeededGenerator) -> (template: String, text: String)? {
        let usable = templates.indices.filter { Self.fill(templates[$0], values) != nil }
        guard !usable.isEmpty else { return nil }
        var candidates = usable
        for avoid in tiers {
            let preferred = usable.filter { !avoid(templates[$0]) }
            if !preferred.isEmpty { candidates = preferred; break }
        }
        guard let pick = pickIndex(from: candidates, usable: usable, using: &rng),
              let text = Self.fill(templates[pick], values) else { return nil }
        return (templates[pick], text)
    }
}
