import Foundation

// Station configuration: what the listener asked the station to be.
// Pure value type: no view, player or MusicKit ownership, so it survives fold/unfold
// and relaunch unchanged. Requesting an integration here never grants access; the
// existing consent flow (`ConsentState`, item-level `isNarratable(at:)`) still decides.

/// The listener's station settings. Always construct or decode through `validated()`
/// (the initializer and decoder do this for you), so every stored value is in bounds.
public struct StationConfiguration: Codable, Equatable, Sendable {
    /// Free-form genre tags, normalized (trimmed, lowercased, de-duplicated, order kept).
    public var genres: [String]
    /// Free-form mood tags, normalized like `genres`.
    public var moods: [String]
    /// 0 = calm, 1 = high energy.
    public var energy: Double
    /// 0 = familiar favourites only, 1 = mostly new music.
    public var discovery: Double
    public var personality: DJPersonality
    public var commentary: CommentaryFrequency
    public var briefing: BriefingPreferences
    /// Integrations the listener wants used. A request, not a grant.
    public var requestedIntegrations: Set<StationIntegration>
    /// What the station is built from (artists, a genre, a playlist, a song). Empty means
    /// no seeds: the station is built from tags only, as before. Validated: at most
    /// `Limits.maxSeeds`, unique by kind plus `catalogID`, names trimmed and capped.
    public var seeds: [StationSeed]
    /// How far the station may go from `seeds`. `discovery` is the familiar-vs-new mix within it.
    public var reach: StationReach

    public init(
        genres: [String] = [],
        moods: [String] = [],
        energy: Double = 0.5,
        discovery: Double = 0.3,
        personality: DJPersonality = .warm,
        commentary: CommentaryFrequency = .occasional,
        briefing: BriefingPreferences = .init(),
        requestedIntegrations: Set<StationIntegration> = [],
        seeds: [StationSeed] = [],
        reach: StationReach = .default
    ) {
        self.genres = genres
        self.moods = moods
        self.energy = energy
        self.discovery = discovery
        self.personality = personality
        self.commentary = commentary
        self.briefing = briefing
        self.requestedIntegrations = requestedIntegrations
        self.seeds = seeds
        self.reach = reach
        self = validated()
    }

    /// Migration-safe defaults: balanced energy, mostly familiar music, occasional DJ,
    /// briefing on with the 5-minute flexible target, and no integrations requested.
    public static let `default` = StationConfiguration()

    public enum Limits {
        public static let maxTags = 8
        public static let maxTagLength = 32
        public static let unitRange: ClosedRange<Double> = 0...1
        public static let maxSeeds = 8
        public static let maxSeedNameLength = StationSeed.maxNameLength
    }

    /// Clamps and normalizes every field. Idempotent.
    public func validated() -> StationConfiguration {
        var copy = self
        copy.genres = Self.normalizedTags(genres)
        copy.moods = Self.normalizedTags(moods)
        copy.energy = Self.clampUnit(energy, fallback: 0.5)
        copy.discovery = Self.clampUnit(discovery, fallback: 0.3)
        copy.briefing = briefing.validated()
        copy.seeds = Self.normalizedSeeds(seeds)
        // Library seeds stay on the device and are never expanded (Fry's rule (d)), so a station
        // with any library seed is always `.only`, however it was built, saved or decoded.
        copy.reach = reach.effective(for: copy.seeds)
        return copy
    }

    /// Fry's rule (a): drops seeds with an empty ID or name, trims and caps names,
    /// keeps the first of each kind plus `catalogID` (order kept), and caps the list.
    static func normalizedSeeds(_ seeds: [StationSeed]) -> [StationSeed] {
        var seen = Set<StationSeed.Key>()
        var result: [StationSeed] = []
        for raw in seeds {
            guard let seed = raw.normalized(), seen.insert(seed.key).inserted else { continue }
            result.append(seed)
            if result.count == Limits.maxSeeds { break }
        }
        return result
    }

    static func clampUnit(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, Limits.unitRange.lowerBound), Limits.unitRange.upperBound)
    }

    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            let tag = String(collapsed.prefix(Limits.maxTagLength))
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            result.append(tag)
            if result.count == Limits.maxTags { break }
        }
        return result
    }

    /// The talk cadence the DJ break planner should use, derived from `base`.
    /// Only `talkFraction` and the plain-transition cap change; briefing caps are kept.
    /// Chatty is the owner's explicit override: a break after every song (spacing 0).
    public func cadence(base: DJCadence = .init()) -> DJCadence {
        let everySong = commentary == .chatty
        return DJCadence(
            talkFraction: commentary.talkFraction,
            minSongsBetweenBreaks: everySong ? 0 : base.minSongsBetweenBreaks,
            maxTransitionSeconds: min(base.maxTransitionSeconds, personality.maxTransitionSeconds),
            maxBriefingBreakSeconds: base.maxBriefingBreakSeconds,
            allowsBackToBack: everySong,
            maxClosingSeconds: base.maxClosingSeconds,
            maxPersonalUpdatesPerBreak: base.maxPersonalUpdatesPerBreak
        )
    }

    /// Context sources the listener has asked to use. Callers must still check
    /// consent per source and `ContextItem.isNarratable(at:)` per item.
    public var requestedContextSources: Set<ContextSourceKind> {
        requestedIntegrations.reduce(into: []) { $0.formUnion($1.contextSources) }
    }

    // MARK: Codable (tolerant: missing keys use defaults, unknown values fall back, all values clamped)

    private enum CodingKeys: String, CodingKey {
        case genres, moods, energy, discovery, personality, commentary, briefing, requestedIntegrations
        case seeds, reach
    }

    /// Decodes one seed, or nothing: an unknown kind drops that seed, not the whole list.
    private struct LossySeed: Decodable {
        let seed: StationSeed?
        init(from decoder: Decoder) throws { seed = try? StationSeed(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StationConfiguration.default
        self.genres = (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? d.genres
        self.moods = (try? c.decodeIfPresent([String].self, forKey: .moods)) ?? d.moods
        self.energy = (try? c.decodeIfPresent(Double.self, forKey: .energy)) ?? d.energy
        self.discovery = (try? c.decodeIfPresent(Double.self, forKey: .discovery)) ?? d.discovery
        self.personality = (try? c.decodeIfPresent(String.self, forKey: .personality))
            .flatMap(DJPersonality.init(rawValue:)) ?? d.personality
        self.commentary = (try? c.decodeIfPresent(String.self, forKey: .commentary))
            .flatMap(CommentaryFrequency.init(rawValue:)) ?? d.commentary
        self.briefing = (try? c.decodeIfPresent(BriefingPreferences.self, forKey: .briefing)) ?? d.briefing
        let integrations = (try? c.decodeIfPresent([String].self, forKey: .requestedIntegrations)) ?? []
        self.requestedIntegrations = Set(integrations.compactMap(StationIntegration.init(rawValue:)))
        // Fry's rule (b): a recipe or config saved before seeds existed loads as no seeds, `.related`.
        let seeds = (try? c.decodeIfPresent([LossySeed].self, forKey: .seeds)) ?? nil
        self.seeds = seeds?.compactMap(\.seed) ?? d.seeds
        self.reach = (try? c.decodeIfPresent(String.self, forKey: .reach))
            .flatMap(StationReach.init(rawValue:)) ?? d.reach
        self = validated()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(genres, forKey: .genres)
        try c.encode(moods, forKey: .moods)
        try c.encode(energy, forKey: .energy)
        try c.encode(discovery, forKey: .discovery)
        try c.encode(personality.rawValue, forKey: .personality)
        try c.encode(commentary.rawValue, forKey: .commentary)
        try c.encode(briefing, forKey: .briefing)
        try c.encode(requestedIntegrations.map(\.rawValue).sorted(), forKey: .requestedIntegrations)
        try c.encode(seeds, forKey: .seeds)
        try c.encode(reach.rawValue, forKey: .reach)
    }
}

/// A small set of presenter presets. Today a preset affects only the plain-transition
/// length cap (see `maxTransitionSeconds`); line selection by preset is a follow-up and
/// the UI must not promise a different voice or script until that lands.
public enum DJPersonality: String, Codable, Sendable, CaseIterable {
    case warm, upbeat, laidBack, minimal

    /// Upper bound for a plain break's main segment (the talk-over closing line has its own
    /// `DJCadence.maxClosingSeconds`). `minimal` keeps it short.
    public var maxTransitionSeconds: Int {
        switch self {
        case .warm, .upbeat, .laidBack: 15
        case .minimal: 6
        }
    }
}

/// How often the DJ talks between songs. Raw values are persisted in recipes: never rename one.
/// What a preset actually delivers is bounded by `DJCadence`'s spacing rule (`expectedTalkShare`).
public enum CommentaryFrequency: String, Codable, Sendable, CaseIterable {
    case off, rare, occasional, frequent, chatty

    /// Upper bound for any preset's requested `talkFraction`. `chatty` asks for every boundary
    /// and is the only preset whose cadence allows back-to-back breaks.
    public static let maxTalkFraction = 1.0

    /// Maps onto `DJCadence.talkFraction`. Briefing content is governed by `BriefingPreferences`, not this.
    public var talkFraction: Double {
        switch self {
        case .off: 0
        case .rare: 0.15
        case .occasional: 0.3
        case .frequent: 0.45
        case .chatty: 1.0
        }
    }
}

/// Integrations the station may draw personal context from, once consent allows.
public enum StationIntegration: String, Codable, Sendable, CaseIterable, Hashable {
    case calendar
    case shareInbox
    case obsidian

    public var contextSources: Set<ContextSourceKind> {
        switch self {
        case .calendar: [.calendar]
        case .shareInbox: [.emailShared, .messagesShared, .userShared]
        case .obsidian: [.obsidian]
        }
    }

    public init(source: ContextSourceKind) {
        switch source {
        case .calendar: self = .calendar
        case .emailShared, .messagesShared, .userShared: self = .shareInbox
        case .obsidian: self = .obsidian
        }
    }
}

/// Sections a morning briefing may contain. Each needs its integration requested and consented.
public enum BriefingSection: String, Codable, Sendable, CaseIterable, Hashable {
    case calendar
    case sharedItems
    case notes

    public var requiredIntegration: StationIntegration {
        switch self {
        case .calendar: .calendar
        case .sharedItems: .shareInbox
        case .notes: .obsidian
        }
    }
}

/// A local time-of-day window, in minutes after midnight. May wrap past midnight.
/// Since #332 it does not gate personal updates (they may air all day); it is kept so saved
/// stations still decode and round-trip.
public struct BriefingWindow: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var durationMinutes: Int

    public static let durationRange = 15...240

    public init(startMinute: Int = 7 * 60, durationMinutes: Int = 120) {
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self = validated()
    }

    public func validated() -> BriefingWindow {
        var copy = self
        copy.startMinute = ((startMinute % 1440) + 1440) % 1440
        copy.durationMinutes = min(max(durationMinutes, Self.durationRange.lowerBound), Self.durationRange.upperBound)
        return copy
    }

    /// Whether `date` falls in the window in `calendar`'s time zone. End is exclusive.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let offset = ((minute - startMinute) % 1440 + 1440) % 1440
        return offset < durationMinutes
    }

    private enum CodingKeys: String, CodingKey { case startMinute, durationMinutes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.startMinute = (try? c.decodeIfPresent(Int.self, forKey: .startMinute)) ?? 7 * 60
        self.durationMinutes = (try? c.decodeIfPresent(Int.self, forKey: .durationMinutes)) ?? 120
        self = validated()
    }
}

public struct BriefingPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var window: BriefingWindow
    /// Flexible spoken-length target. The planner may run shorter; music comes first.
    public var targetSeconds: Int
    public var sections: Set<BriefingSection>

    public static let targetRange = 60...600

    public init(
        enabled: Bool = true,
        window: BriefingWindow = .init(),
        targetSeconds: Int = 300,
        sections: Set<BriefingSection> = Set(BriefingSection.allCases)
    ) {
        self.enabled = enabled
        self.window = window
        self.targetSeconds = targetSeconds
        self.sections = sections
        self = validated()
    }

    public func validated() -> BriefingPreferences {
        var copy = self
        copy.window = window.validated()
        copy.targetSeconds = min(max(targetSeconds, Self.targetRange.lowerBound), Self.targetRange.upperBound)
        return copy
    }

    /// Sections that may actually be planned: enabled, requested and consented integrations only.
    public func plannableSections(grantedIntegrations: Set<StationIntegration>) -> Set<BriefingSection> {
        guard enabled else { return [] }
        return sections.filter { grantedIntegrations.contains($0.requiredIntegration) }
    }

    private enum CodingKeys: String, CodingKey { case enabled, window, targetSeconds, sections }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        self.window = (try? c.decodeIfPresent(BriefingWindow.self, forKey: .window)) ?? .init()
        self.targetSeconds = (try? c.decodeIfPresent(Int.self, forKey: .targetSeconds)) ?? 300
        if let raw = try? c.decodeIfPresent([String].self, forKey: .sections) {
            self.sections = Set(raw.compactMap(BriefingSection.init(rawValue:)))
        } else {
            self.sections = Set(BriefingSection.allCases)
        }
        self = validated()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(window, forKey: .window)
        try c.encode(targetSeconds, forKey: .targetSeconds)
        try c.encode(sections.map(\.rawValue).sorted(), forKey: .sections)
    }
}
