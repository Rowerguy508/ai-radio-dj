import Foundation

// Natural break shapes (lane 2, -Fry). Opt-in: `DJScriptWriter.shapes` is nil by default, so the
// classic planner (and every pinned line in the existing tests) is unchanged until the default
// is flipped in a follow-up, after Echo's lane-1 pools land.
//
// Rules, all enforced here and tested in `DJBreakShapesTests`:
//   - Shapes: back-announce only, coming-up only, combined ("that was X, here's Y"), a short
//     station ID, the classic shape, and a time check plus intro (offered only when the caller
//     supplies a time-check line; the clock wiring is a follow-up slice).
//   - Never the same shape twice in a row.
//   - Station ID never in two consecutive breaks, and never in the first two breaks after the
//     greeting.
//   - Cross-pool anti-repeat: a template used in the last `recentBreakWindow` breaks is not
//     picked again while another fits; an opener never starts with the previous break's opener
//     word; at most one line starting "Here's" in any `hereWindow` consecutive breaks.
//   - Every ordinary break fits `maxBreakSeconds` (12 s, closing line included) and the main
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
    /// A short time check, then the closing line. Needs a time-check line from the caller.
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
    /// Whole-break cap at the word-rate estimate, closing line included (the 12 s cap, #320).
    public var maxBreakSeconds: Int
    /// Cues per ordinary break; matches the proxy's `MAX_CLOUD_RENDERS_PER_BREAK` (4).
    public var maxCuesPerBreak: Int
    /// Breaks after the greeting that may not carry a station ID.
    public var stationIDGraceBreaks: Int
    /// Combined back-announce plus forward-sell lines. `{title}`/`{artist}` name the song that
    /// just played, `{nextTitle}`/`{nextArtist}` the next one. Copy is Echo's to restyle.
    public var combined: [String]

    public init(weights: [DJBreakShape: Int] = DJBreakShapeConfig.defaultWeights, recentBreakWindow: Int = 6,
                hereWindow: Int = 3, maxBreakSeconds: Int = 12, maxCuesPerBreak: Int = 4,
                stationIDGraceBreaks: Int = 2, combined: [String] = DJBreakShapeConfig.defaultCombined) {
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

    public static let defaultCombined = [
        "That was {title}. Here's {nextTitle}.",
        "{artist} there. And here's {nextArtist}.",
        "That's {title}. Coming up, {nextTitle}.",
        "{title}, from {artist}. Now, {nextTitle}.",
        "That was {artist}. Next, {nextArtist}.",
        "{artist}, {title}. And this one's {nextArtist}.",
        "Out of {artist}, into {nextArtist}.",
        "{title} there. Up next, {nextArtist}.",
    ]
}

/// What the picker may know about a boundary.
public struct DJBreakShapeContext: Equatable, Sendable {
    /// The song that just played has a title or artist to name.
    public var canBackAnnounce: Bool
    /// The next song has a title or artist to name.
    public var canForwardSell: Bool
    /// The station name is speakable (`EditorialStationName.usable`).
    public var stationIDUsable: Bool
    /// The caller supplied a time-check line for this break.
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
            case .timeCheckIntro: return context.timeCheckAvailable && context.canForwardSell
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
}

/// Cross-pool memory of what the last few breaks said, by template (not filled text), so
/// "Here's {nextTitle}." counts as a repeat even with a different song.
public struct RecentSpokenTemplates: Sendable {
    public let window: Int
    public let hereWindow: Int
    private var history: [[String]] = []

    public init(window: Int, hereWindow: Int) {
        self.window = max(1, window)
        self.hereWindow = max(1, hereWindow)
    }

    static func key(_ template: String) -> String {
        template.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func firstWord(_ template: String) -> String {
        let word = template.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func startsWithHere(_ template: String) -> Bool {
        firstWord(template) == "here's" || firstWord(template) == "heres"
    }

    /// True when `template` should be avoided in the break being built. `sameBreak` holds the
    /// templates already chosen for it; `isOpener` adds the first-word rule.
    /// `window` narrows the lookback (nil: the full window); `strict` false keeps only the
    /// same-break and lookback checks.
    public func rejects(_ template: String, sameBreak: [String], isOpener: Bool, window: Int? = nil,
                        strict: Bool = true) -> Bool {
        let key = Self.key(template)
        if sameBreak.map(Self.key).contains(key) { return true }
        if history.suffix(window ?? self.window).contains(where: { $0.map(Self.key).contains(key) }) { return true }
        guard strict else { return false }
        if isOpener, let previous = history.last?.first, Self.firstWord(previous) == Self.firstWord(template) { return true }
        if Self.startsWithHere(template) {
            let recent = history.suffix(hereWindow - 1).flatMap { $0 } + sameBreak
            if recent.contains(where: Self.startsWithHere) { return true }
        }
        return false
    }

    /// Records one aired break's templates, opener first.
    public mutating func record(_ templates: [String]) {
        history.append(templates)
        if history.count > max(window, hereWindow) + 1 { history.removeFirst(history.count - max(window, hereWindow) - 1) }
    }

    public var lastBreak: [String] { history.last ?? [] }
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
