import Foundation

// #200 (-Echo): writes DJ lines from provider facts. Every word is a template word or a fact field;
// nothing is looked up, guessed or rounded into a new claim. Lines never name the listener's place
// ("here"), so a line read aloud does not say where they are.
//
// Two outputs, both into existing paths (no new scheduler, renderer or presentation state):
// - `extraLine(...)`: one optional line for an ordinary break, through `DJBreakExtraLineSource`
//   (`FactExtraLineSource`). `DJScriptWriter` still fits the break to the 12 s cap and drops this line first.
// - `briefingLines(...)`: the weather and headlines for a briefing interlude, within 45 s, as script
//   inputs for the briefing cue path. Wiring them into `NarrationHandoff` is a follow-up (see PR).

/// One line written from one fact.
public struct FactLine: Equatable, Sendable {
    public let text: String
    public let factID: UUID
    public let kind: BroadcastFactKind
    public let provenance: String
    public let expiresAt: Date
    /// Estimate at `DefaultBriefingPlanner.wordsPerMinute` (150 wpm). Measured audio replaces it.
    public let estimatedSeconds: Int
    /// Which fields of the fact the line speaks, in order (#199-style source tagging; never spoken).
    public let fields: [BroadcastFactField]

    /// The ordinary-break seam's line. Attribution `.presenter` is the closest existing case that
    /// does not need a `DJBreakSession` change; the provenance keeps it on the device.
    public var extraLine: DJExtraLine {
        DJExtraLine(text: text, attribution: .presenter, provenance: provenance, expiresAt: expiresAt)
    }
}

public struct FactInterludeComposer: Sendable {
    /// One fact line inside an ordinary break leaves room for the opener and closing (12 s cap).
    public var maxExtraLineSeconds: Int
    /// Whole briefing interlude (`DJCadence.maxBriefingBreakSeconds`).
    public var maxBriefingSeconds: Int
    public var maxHeadlines: Int
    /// A headline longer than this is dropped, never cut (cutting can change its meaning).
    public var maxHeadlineWords: Int
    public static let rainChanceToMention = 40

    public init(cadence: DJCadence = DJCadence(), maxExtraLineSeconds: Int = 5, maxHeadlines: Int = 3,
                maxHeadlineWords: Int = 22) {
        self.maxExtraLineSeconds = maxExtraLineSeconds
        self.maxBriefingSeconds = cadence.maxBriefingBreakSeconds
        self.maxHeadlines = maxHeadlines
        self.maxHeadlineWords = maxHeadlineWords
    }

    /// One weather line for an ordinary break, if a weather fact is still true at `airBy`.
    /// `variant` picks the phrasing (the writer's anti-repeat window handles repeats).
    public func extraLine(from facts: [BroadcastFact], airBy: Date, variant: Int = 0,
                          counts: inout FactCueCounts) -> FactLine? {
        for fact in facts where fact.kind == .weather {
            guard fact.isLive(at: airBy) else { counts.expired += 1; continue }
            guard case .weather(let w) = fact.payload,
                  let (text, fields) = Self.shortWeather(w, credit: fact.attribution, variant: variant) else { continue }
            let line = Self.line(text, fact, fields: fields)
            guard line.estimatedSeconds <= maxExtraLineSeconds else { counts.overCap += 1; continue }
            counts.kept += 1
            return line
        }
        return nil
    }

    /// Weather, then headlines, fitted to `maxBriefingSeconds` (estimate). Facts not true at
    /// `airBy` are dropped and counted, never moved to a later show.
    public func briefingLines(from facts: [BroadcastFact], airBy: Date, counts: inout FactCueCounts) -> [FactLine] {
        var lines: [FactLine] = []
        var budget = maxBriefingSeconds
        var headlines = 0
        let ordered = facts.filter { $0.kind == .weather } + facts.filter { $0.kind == .localNews }
            + facts.filter { $0.kind == .news } + facts.filter { [.personal, .artistInfo].contains($0.kind) }
        let sanitizer = PromptInjectionSanitizer()
        for fact in ordered {
            guard fact.isLive(at: airBy) else { counts.expired += 1; continue }
            let written: (String, [BroadcastFactField])?
            switch fact.payload {
            case .weather(let w): written = Self.longWeather(w, credit: fact.attribution)
            case .headline(let h):
                guard headlines < maxHeadlines else { counts.overCap += 1; continue }
                guard let spoken = Self.headline(h, maxWords: maxHeadlineWords), !sanitizer.isSuspicious(spoken.0)
                else { counts.overCap += 1; continue }
                written = spoken
            case .approvedSentence(let s):
                // Already written and approved by its owner (Nova's personal / Fry's catalog code).
                let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                written = clean.isEmpty || clean.contains(where: { "{}\n\r".contains($0) }) ? nil : (clean, [.sentence])
            }
            guard let (text, fields) = written else { continue }
            let line = Self.line(text, fact, fields: fields)
            guard line.estimatedSeconds <= budget else { counts.overCap += 1; continue }
            budget -= line.estimatedSeconds
            if case .headline = fact.payload { headlines += 1 }
            counts.kept += 1
            lines.append(line)
        }
        return lines
    }

    // MARK: - Phrasing: fixed templates, fact fields only

    static func line(_ text: String, _ fact: BroadcastFact, fields: [BroadcastFactField]) -> FactLine {
        FactLine(text: text, factID: fact.id, kind: fact.kind, provenance: fact.provenance, expiresAt: fact.expiresAt,
                 estimatedSeconds: DefaultBriefingPlanner.estimatedSpokenSeconds(for: text), fields: fields)
    }

    /// The validated, speakable value of each field of a weather fact. A field that fails is absent
    /// (dropped, never repaired), and every template that needs it becomes unusable.
    static func values(_ w: WeatherFact, credit: FactAttribution) -> [BroadcastFactField: String] {
        var v: [BroadcastFactField: String] = [:]
        let c = w.condition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !c.isEmpty, c.count <= 32, c.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" }) { v[.condition] = c }
        if (-80...140).contains(w.temperature) { v[.temperature] = String(w.temperature) }
        if let h = w.high, (-80...140).contains(h) { v[.high] = String(h) }
        if let l = w.low, (-80...140).contains(l) { v[.low] = String(l) }
        if let r = w.precipitationChancePercent, (rainChanceToMention...100).contains(r) { v[.precipitationChance] = String(r) }
        if let source = source(credit.spokenName) { v[.source] = source }
        return v
    }

    static func source(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.contains(where: { "{}<>\n\r|:".contains($0) }) else { return nil }
        return name
    }

    static func shortWeather(_ w: WeatherFact, credit: FactAttribution, variant: Int) -> (String, [BroadcastFactField])? {
        let pool = FactLineTemplates.weatherShort
        return FactLineTemplates.fill(pool[abs(variant) % pool.count], values(w, credit: credit))
    }

    /// Main sentence (the fullest template whose fields are all present), plus the rain sentence
    /// when its chance is worth saying.
    static func longWeather(_ w: WeatherFact, credit: FactAttribution) -> (String, [BroadcastFactField])? {
        let v = values(w, credit: credit)
        guard let main = FactLineTemplates.weatherLong.lazy.compactMap({ FactLineTemplates.fill($0, v) }).first else { return nil }
        guard let rain = FactLineTemplates.fill(FactLineTemplates.rain, v) else { return main }
        return (main.0 + " " + rain.0, main.1 + rain.1)
    }

    /// "From <outlet>: <headline>." The outlet is always named. A headline over `maxWords`, or with
    /// markup or braces, is dropped, never cut. The one edit: a feed's trailing " - <same outlet>"
    /// byline (Google News / GDELT title style) is removed, since the outlet is credited anyway.
    static func headline(_ h: HeadlineFact, maxWords: Int) -> (String, [BroadcastFactField])? {
        guard let outlet = source(h.outlet) else { return nil }
        var text = h.headline.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for suffix in [" - \(outlet)", " | \(outlet)", " — \(outlet)"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        if let last = text.last, ".!?".contains(last) { text.removeLast() }
        guard !text.isEmpty, text.split(separator: " ").count <= maxWords,
              !text.contains(where: { "{}<>|".contains($0) }) else { return nil }
        return FactLineTemplates.fill(FactLineTemplates.headline, [.outlet: outlet, .headline: text])
    }
}

/// #200: the allow-list of fact phrasings (same pattern as #199's `CatalogFactLine.templates`).
/// The only placeholders are `BroadcastFactField`s; a template with any field missing is unusable.
/// Every line credits its source aloud.
public enum FactLineTemplates {
    public static let weatherShort = [
        "It's {temperature} degrees and {condition} here, says {source}.",
        "{Condition} and {temperature} degrees right now, says {source}.",
    ]
    /// Fullest first.
    public static let weatherLong = [
        "From {source}: it's {temperature} degrees and {condition} here, with a high of {high} and a low of {low} today.",
        "From {source}: it's {temperature} degrees and {condition} here, with a high of {high} today.",
        "From {source}: it's {temperature} degrees and {condition} here.",
    ]
    public static let rain = "{precipitationChance} percent chance of rain."
    public static let headline = "From {outlet}: {headline}."
    public static var all: [String] { weatherShort + weatherLong + [rain, headline] }

    /// Fills every placeholder from `values`, or nil when one is missing. `{Field}` capitalizes the
    /// value's first letter. Returns the fields used, in order (the line's provenance).
    public static func fill(_ template: String, _ values: [BroadcastFactField: String]) -> (String, [BroadcastFactField])? {
        var out = "", used: [BroadcastFactField] = [], rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            out += rest[..<open]
            let name = String(rest[rest.index(after: open)..<close])
            let capital = name.first?.isUppercase == true
            let key = capital ? name.prefix(1).lowercased() + name.dropFirst() : name
            guard let field = BroadcastFactField(rawValue: key), let value = values[field], !value.isEmpty else { return nil }
            out += capital ? value.prefix(1).uppercased() + value.dropFirst() : value
            used.append(field)
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return (out, used)
    }
}

/// `DJBreakExtraLineSource` over the latest gathered facts. Not wired by default: the app sets
/// `DJScriptWriter.extraLineSource` once a provider is enabled. Thread-safe snapshot.
public final class FactExtraLineSource: DJBreakExtraLineSource, @unchecked Sendable {
    private let lock = NSLock()
    private var facts: [BroadcastFact] = []
    private var variant = 0
    private var counts = FactCueCounts()
    private let composer: FactInterludeComposer
    private let now: @Sendable () -> Date
    /// How far ahead a planned line may air. A fact that ends sooner is not offered.
    private let airLead: TimeInterval

    public init(composer: FactInterludeComposer = FactInterludeComposer(), airLead: TimeInterval = 5 * 60,
                now: @escaping @Sendable () -> Date = DJBreakPreparer.systemNow) {
        self.composer = composer
        self.airLead = airLead
        self.now = now
    }

    public func update(_ facts: [BroadcastFact]) { lock.withLock { self.facts = facts } }
    /// Withdrawal or purge: offer nothing until the next update.
    public func clear() { lock.withLock { facts = [] } }
    /// Count-only diagnostics since the last read.
    public func takeCounts() -> FactCueCounts { lock.withLock { defer { counts = FactCueCounts() }; return counts } }

    public func extraLine(after previous: DJTrack, before next: DJTrack, shape: DJBreakShape) -> DJExtraLine? {
        lock.withLock {
            let airBy = now().addingTimeInterval(airLead)
            facts.removeAll { !$0.isLive(at: now()) }
            defer { variant += 1 }
            return composer.extraLine(from: facts, airBy: airBy, variant: variant, counts: &counts)?.extraLine
        }
    }
}
