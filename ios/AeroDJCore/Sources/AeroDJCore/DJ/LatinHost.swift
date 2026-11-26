import Foundation

// #196 (-Fry): Latin host persona, host language and Spanglish controls. Core only: the model,
// the copy rules and the AI-path style fields. No UI here (#198 owns the controls) and no voice
// inventory (#197 supplies which Spanish voices the device really has). Nothing in this file is
// wired into `DJBreakSession` yet, so today's English breaks are unchanged.
//
// Spec rules this file encodes (#190 §2, Latin-station requirements):
// - Latin host is an explicit choice. It may be *suggested* from the station's own genre tags,
//   never inferred from the listener, a single artist, or any personal data.
// - Never promise a dialect the installed voices can't deliver: the resolver downgrades.
// - Spanglish is short, contextual code-switches, bounded by the listener's intensity.
// - No stereotyped catchphrases, no invented accents, no claim the voice is a real person.

/// The host's base language. Raw values are persisted: never rename one. Spanglish is not a
/// third language: it is `SpanglishIntensity`, an independent mixing level on top of either base
/// (Nova's #198 mock, #666). A "three languages" UI maps onto this; the reverse would not.
public enum DJHostLanguage: String, Codable, Sendable, CaseIterable {
    case english, spanish

    /// The language a Spanglish switch goes into.
    public var other: DJHostLanguage { self == .english ? .spanish : .english }
}

/// How much the host code-switches out of its base language, independent of that base.
/// Raw values are persisted: never rename one.
public enum SpanglishIntensity: String, Codable, Sendable, CaseIterable {
    case off, light, conversational

    /// Most switches between Spanish and English one spoken line may make.
    public var maxSwitchesPerLine: Int {
        switch self {
        case .off: 0
        case .light: 1
        case .conversational: 2
        }
    }

    /// Most words the other (non-base) language may take in one line.
    public var maxSecondaryWordsPerLine: Int {
        switch self {
        case .off: 0
        case .light: 4
        case .conversational: 8
        }
    }
}

/// The Spanish voice style the listener would like. A preference, not a promise: the resolver
/// only keeps it when the device has a voice for it. Raw values are persisted: never rename one.
public enum SpanishVoiceStyle: String, Codable, Sendable, CaseIterable {
    case neutralLatinAmerican, caribbean, mexican
}

/// The listener's host-language preference for a station. The three fields are independent.
public struct DJHostLanguagePreference: Codable, Equatable, Sendable {
    public var language: DJHostLanguage
    public var spanglish: SpanglishIntensity
    public var voiceStyle: SpanishVoiceStyle

    public init(language: DJHostLanguage = .english,
                spanglish: SpanglishIntensity = .off,
                voiceStyle: SpanishVoiceStyle = .neutralLatinAmerican) {
        self.language = language
        self.spanglish = spanglish
        self.voiceStyle = voiceStyle
    }

    /// English, no Spanglish: exactly today's host. Migration-safe default.
    public static let `default` = DJHostLanguagePreference()

    /// Whether any Spanish is spoken: a Spanish base, or any Spanglish on an English base.
    /// This is the host-language side of the Latin host; the persona preset itself stays an open
    /// owner question (#198), so no `DJPersonality` case is added here.
    public var speaksSpanish: Bool { language == .spanish || spanglish != .off }

    private enum CodingKeys: String, CodingKey { case language, spanglish, voiceStyle }

    /// Lossy: an unknown or missing value falls back to the default for that field only.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DJHostLanguagePreference.default
        language = (try? c.decodeIfPresent(String.self, forKey: .language)).flatMap(DJHostLanguage.init(rawValue:)) ?? d.language
        spanglish = (try? c.decodeIfPresent(String.self, forKey: .spanglish)).flatMap(SpanglishIntensity.init(rawValue:)) ?? d.spanglish
        voiceStyle = (try? c.decodeIfPresent(String.self, forKey: .voiceStyle)).flatMap(SpanishVoiceStyle.init(rawValue:)) ?? d.voiceStyle
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(language.rawValue, forKey: .language)
        try c.encode(spanglish.rawValue, forKey: .spanglish)
        try c.encode(voiceStyle.rawValue, forKey: .voiceStyle)
    }
}

/// What the host will actually do, after checking the device's voices.
public struct ResolvedHostLanguage: Equatable, Sendable {
    public enum Downgrade: String, Equatable, Sendable {
        /// No installed voice speaks Spanish: the host stays English.
        case noSpanishVoice
        /// A Spanish voice exists, but not in the requested style: another style is used.
        case styleUnavailable
    }

    public let language: DJHostLanguage
    public let spanglish: SpanglishIntensity
    /// `nil` when the host speaks English only.
    public let voiceStyle: SpanishVoiceStyle?
    public let downgrade: Downgrade?

    public var speaksSpanish: Bool { language == .spanish || spanglish != .off }

    public init(language: DJHostLanguage, spanglish: SpanglishIntensity, voiceStyle: SpanishVoiceStyle?, downgrade: Downgrade?) {
        self.language = language
        self.spanglish = spanglish
        self.voiceStyle = voiceStyle
        self.downgrade = downgrade
    }
}

public enum DJHostLanguageResolver {
    /// Order used when the requested style is missing: neutral first, then the declared order.
    static let fallbackOrder: [SpanishVoiceStyle] = [.neutralLatinAmerican, .caribbean, .mexican]

    /// `availableStyles` comes from the device's voice inventory (#197). An empty set means no
    /// installed voice speaks Spanish, so Spanish and Spanglish fall back to English.
    public static func resolve(_ preference: DJHostLanguagePreference,
                               availableStyles: Set<SpanishVoiceStyle>) -> ResolvedHostLanguage {
        let p = preference
        guard p.speaksSpanish else {
            return ResolvedHostLanguage(language: .english, spanglish: .off, voiceStyle: nil, downgrade: nil)
        }
        if availableStyles.contains(p.voiceStyle) {
            return ResolvedHostLanguage(language: p.language, spanglish: p.spanglish, voiceStyle: p.voiceStyle, downgrade: nil)
        }
        if let other = fallbackOrder.first(where: availableStyles.contains) {
            return ResolvedHostLanguage(language: p.language, spanglish: p.spanglish, voiceStyle: other, downgrade: .styleUnavailable)
        }
        return ResolvedHostLanguage(language: .english, spanglish: .off, voiceStyle: nil, downgrade: .noSpanishVoice)
    }
}

/// Latin genres that get their own editorial treatment. Raw values are codes, never spoken.
public enum LatinGenre: String, Codable, Sendable, CaseIterable {
    case salsa, merengue, bachata, reggaeton, dembow, cumbia, bolero, regionalMexican, latinPop

    /// Matches one station genre tag (case-, accent- and spacing-insensitive). Station tags only:
    /// never called with an artist, a listener field, or personal data.
    public init?(tag: String) {
        let t = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch t {
        case "salsa", "salsa dura", "salsa romantica": self = .salsa
        case "merengue", "merengue tipico": self = .merengue
        case "bachata": self = .bachata
        case "reggaeton", "regueton", "urbano latino": self = .reggaeton
        case "dembow": self = .dembow
        case "cumbia": self = .cumbia
        case "bolero", "boleros": self = .bolero
        case "regional mexican", "regional mexicano", "musica mexicana", "mariachi", "banda", "norteno", "corridos":
            self = .regionalMexican
        case "latin pop", "pop latino", "latin": self = .latinPop
        default: return nil
        }
    }

    /// Exclamations ("¡Dale!") fit dance-floor genres only. Salsa is not a hype genre (§2).
    public var allowsExclamation: Bool {
        switch self {
        case .merengue, .reggaeton, .dembow, .cumbia: true
        case .salsa, .bachata, .bolero, .regionalMexican, .latinPop: false
        }
    }

    /// Fixed style note for the AI path, one per genre so they never sound alike (§2). A note sets
    /// the host's delivery only: it never names instruments, tempo or anything else about the song.
    public var styleNote: String {
        switch self {
        case .salsa: "Warm and musical; no hype."
        case .merengue: "Bright and quick; short lines that keep the dance moving."
        case .bachata: "Soft and romantic; speak gently."
        case .reggaeton: "Relaxed confidence over the beat; no shouting."
        case .dembow: "Short and punchy; let the rhythm do the work."
        case .cumbia: "Easygoing and festive; keep it simple."
        case .bolero: "Intimate and unhurried; low energy, no exclamations."
        case .regionalMexican: "Respectful and warm; name the style only when the facts say it."
        case .latinPop: "Friendly and light, like the English host."
        }
    }
}

/// Whether to *suggest* the Latin host for a station. Never switches it on by itself.
public enum LatinHostSuggestion {
    /// True when at least half of the station's genre tags are Latin genres. Uses the station's
    /// own tags only: seeds, artists and anything about the listener are not read.
    public static func suggests(genres: [String]) -> Bool {
        guard !genres.isEmpty else { return false }
        let latin = genres.filter { LatinGenre(tag: $0) != nil }.count
        return latin * 2 >= genres.count
    }

    /// The station's dominant Latin genre, by tag order. `nil` when no tag is a Latin genre.
    public static func dominantGenre(genres: [String]) -> LatinGenre? {
        genres.lazy.compactMap(LatinGenre.init(tag:)).first
    }
}

/// One spoken line, written as language segments so the Spanglish bounds are structural, not
/// guessed from words. `{nextTitle}` and `{nextArtist}` are slots, filled like `EditorialTone`'s.
public struct LatinHostLine: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case es(String)
        case en(String)

        var language: DJHostLanguage { if case .es = self { .spanish } else { .english } }
        var text: String { switch self { case .es(let s), .en(let s): s } }
    }

    public let segments: [Segment]
    /// `nil` means the line suits every Latin genre.
    public let genres: Set<LatinGenre>?

    public init(_ segments: [Segment], genres: Set<LatinGenre>? = nil) {
        self.segments = segments
        self.genres = genres
    }

    public var text: String { segments.map(\.text).joined(separator: " ") }

    /// Number of language changes inside the line.
    public var switches: Int {
        zip(segments, segments.dropFirst()).filter { $0.language != $1.language }.count
    }

    /// Words spoken in `language` (slots count as words of their segment).
    public func words(in language: DJHostLanguage) -> Int {
        segments.filter { $0.language == language }.map(\.text).map(SpokenDurationEstimate.wordCount).reduce(0, +)
    }

    public func isAll(_ language: DJHostLanguage) -> Bool { segments.allSatisfy { $0.language == language } }
}

/// The script rules every Latin host line meets, template or AI output.
public enum LatinHostScriptRules {
    /// Stereotyped catchphrases and caricature the host never says (§2). Lowercased, accent-folded.
    public static let forbiddenPhrases = [
        "ay caramba", "arriba arriba", "andale andale", "ole ole", "hola amigos",
        "muchachos y muchachas", "taco", "burrito", "chihuahua", "spicy", "caliente caliente",
        "fiesta time", "sombrero",
    ]

    /// The host is a voice style, not a person: no claims of identity, origin or nationality.
    public static let forbiddenIdentityClaims = [
        "soy latino", "soy latina", "soy dominicano", "soy dominicana", "soy mexicano", "soy mexicana",
        "soy puertorriqueño", "soy puertorriqueña", "soy boricua", "soy cubano", "soy cubana",
        "as a latino", "as a latina", "i'm latino", "i'm latina", "mi abuela", "mi pueblo", "where i'm from",
        "de donde yo soy", "en mi país", "in my country",
    ]

    public enum Problem: Equatable, Sendable {
        case wrongLanguage
        /// A Spanglish line that is mostly in the other language, not the base.
        case wrongBaseLanguage
        case tooManySwitches(Int)
        case tooMuchSecondaryLanguage(Int)
        case forbiddenPhrase(String)
        case identityClaim(String)
        case hype(String)
        case exclamationOffGenre
        case tooLong(Int)
    }

    /// Words a closing line may have. Matches `EditorialTone.warm.closing`'s seven, plus room for
    /// the Spanish articles and the one short switch.
    public static let maxClosingWords = 12

    /// Spanish hype and verdicts, checked after the English `EditorialPhrasing.forbiddenHype`.
    /// Matched case- and accent-insensitively, so "Que tema" and "qué tema" both count.
    public static let forbiddenSpanishHype = [
        "temazo", "joya", "increíble", "el mejor", "la mejor", "nunca falla", "bomba", "qué tema",
        "qué clase de tema", "tremendo tema", "brutal", "épico", "un palo", "candela",
    ]

    static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Folded text split into words (letters and digits only), so "bombardeo" is not "bomba".
    static func words(_ folded: String) -> [Substring] {
        folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
    }

    /// True when the folded phrase appears as whole words in `words`.
    static func containsWords(_ words: [Substring], _ phrase: String) -> Bool {
        let p = Self.words(folded(phrase))
        guard !p.isEmpty, words.count >= p.count else { return false }
        return (0...(words.count - p.count)).contains { i in words[i..<(i + p.count)].elementsEqual(p) }
    }

    /// Text-only checks, shared with AI output that has no segments.
    /// `names` are the song titles and artists in the line ("La Bomba", "Bomba Estéreo",
    /// "El Mejor Día"). They are removed before the Spanish hype check, so a real name is
    /// never mistaken for hype. Spanish hype is matched on whole words.
    public static func textProblems(_ text: String, genre: LatinGenre?, names: [String] = []) -> [Problem] {
        var out: [Problem] = []
        let f = folded(text)
        var hostWords = f
        for name in names.map(folded).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            hostWords = hostWords.replacingOccurrences(of: name, with: " ")
        }
        let w = words(hostWords)
        for p in forbiddenPhrases where f.contains(folded(p)) { out.append(.forbiddenPhrase(p)) }
        for p in forbiddenIdentityClaims where f.contains(folded(p)) { out.append(.identityClaim(p)) }
        for p in EditorialPhrasing.forbiddenHype where f.contains(p) { out.append(.hype(p)) }
        for p in forbiddenSpanishHype where containsWords(w, p) { out.append(.hype(p)) }
        if text.contains("¡") || text.contains("!") {
            if !(genre?.allowsExclamation ?? false) { out.append(.exclamationOffGenre) }
        }
        let words = SpokenDurationEstimate.wordCount(text)
        if words > maxClosingWords { out.append(.tooLong(words)) }
        return out
    }

    /// Every problem a template line has for this resolved host and genre. Empty means usable.
    public static func problems(_ line: LatinHostLine, host: ResolvedHostLanguage, genre: LatinGenre?) -> [Problem] {
        var out: [Problem] = []
        let base = host.language
        if !host.speaksSpanish {
            // An English-only host has no Latin copy: today's `EditorialTone` banks apply.
            out.append(.wrongLanguage)
        } else if host.spanglish == .off {
            if !line.isAll(base) { out.append(.wrongLanguage) }
        } else {
            let other = line.words(in: base.other)
            if line.switches == 0 { out.append(.wrongLanguage) }
            if line.words(in: base) < other { out.append(.wrongBaseLanguage) }
            if line.switches > host.spanglish.maxSwitchesPerLine { out.append(.tooManySwitches(line.switches)) }
            if other > host.spanglish.maxSecondaryWordsPerLine { out.append(.tooMuchSecondaryLanguage(other)) }
        }
        return out + textProblems(line.text, genre: genre)
    }
}

/// The Latin host's "up next" lines. Templates and tone references, not a playlist (§3).
/// Facts stay out: only the next title and artist slots. No instruments, tempo, genre claims
/// or verdicts on the song ("nunca falla", "un temazo"): the copy has no song data to back them.
public enum LatinHostCopy {
    public static let closing: [LatinHostLine] = [
        // Spanish only.
        .init([.es("Seguimos con {nextTitle}, de {nextArtist}.")]),
        .init([.es("Ahora viene {nextTitle}.")]),
        .init([.es("Vamos con {nextArtist}, {nextTitle}.")]),
        .init([.es("Aquí está {nextTitle}, de {nextArtist}.")]),
        .init([.es("Nos quedamos en esa vibra con {nextTitle}.")]),
        .init([.es("Sigue {nextArtist} con {nextTitle}.")]),
        .init([.es("¡Dale! Seguimos con {nextArtist}.")], genres: [.merengue, .dembow, .cumbia, .reggaeton]),
        .init([.es("Con calma, ahora {nextTitle}.")], genres: [.bolero, .bachata]),
        .init([.es("Seguimos con {nextArtist}, {nextTitle}.")], genres: [.regionalMexican]),
        // Spanglish, Spanish base: mostly Spanish, one short English switch.
        .init([.es("Seguimos con buena música."), .en("Up next, {nextTitle}.")]),
        .init([.es("Seguimos aquí con ustedes."), .en("Now, {nextTitle}.")]),
        .init([.es("Vamos con {nextArtist} ahora."), .en("Here we go.")]),
        .init([.es("Con calma, seguimos con {nextArtist}."), .en("Here's {nextTitle}.")], genres: [.bachata, .bolero]),
        // Spanglish, either base: as much English as Spanish, one switch.
        .init([.en("Here's {nextArtist},"), .es("con {nextTitle}.")]),
        // Spanglish, English base: mostly English, one short Spanish switch.
        .init([.es("Mi gente,"), .en("here comes {nextTitle}.")]),
        .init([.en("Okay, {nextTitle} is next,"), .es("mi gente.")]),
        .init([.es("Ahora sí."), .en("Here's {nextTitle} by {nextArtist}.")]),
        .init([.en("Let's get into {nextTitle},"), .es("dale.")], genres: [.reggaeton, .dembow]),
        // Conversational: up to two switches.
        .init([.es("Seguimos un rato."), .en("And next,"), .es("{nextTitle}.")]),
        .init([.es("Un poquito de contexto,"), .en("then {nextTitle}.")]),
        .init([.en("Up next,"), .es("una de {nextArtist}"), .en("you might know.")]),
        .init([.en("Coming up,"), .es("una más,"), .en("{nextTitle}.")]),
    ]

    /// Lines that pass every rule for this host and genre, in bank order. Genre-tagged lines
    /// only play on their genre; untagged lines play anywhere. Empty for an English host.
    public static func closingPool(host: ResolvedHostLanguage, genre: LatinGenre?) -> [LatinHostLine] {
        closing.filter { line in
            if let g = line.genres, !(genre.map(g.contains) ?? false) { return false }
            return LatinHostScriptRules.problems(line, host: host, genre: genre).isEmpty
        }
    }
}

/// The AI path's style fields (docs/dj-persona.md lane 5): codes and fixed rule text only.
/// Never the station name, the listener's tags as typed, artist names, or personal items.
public enum LatinHostPromptRules {
    /// Fixed rules sent with every Latin host request. The server prompt quotes them verbatim.
    public static let rules: [String] = [
        "Speak as a warm Latin radio host. You are a voice style, not a real person: never claim an identity, origin or nationality.",
        "Use only the facts provided. Do not invent facts, accents or slang.",
        "Mention instruments, tempo or a song's history only if the provided facts mention them.",
        "Pronounce artist names, Spanish titles and place names correctly.",
        "No stereotyped catchphrases, caricature, or food and costume clichés.",
        "Do not assume everyone in Latin America speaks alike.",
        "Keep the closing line to twelve words or fewer, and land before the vocal.",
    ]

    /// Fixed instruction for each language mode and intensity.
    public static func languageRule(_ host: ResolvedHostLanguage) -> String {
        let base = host.language == .english ? "English" : "Spanish"
        let other = host.language == .english ? "Spanish" : "English"
        switch host.spanglish {
        case .off: return "Speak \(base) only."
        case .light:
            return "Speak mostly \(base), with one short \(other) phrase per line, four words or fewer."
        case .conversational:
            return "Speak mostly \(base), with natural \(other) phrases: at most two switches and eight \(other) words per line."
        }
    }

    /// Codes for the request body. Values come only from closed enums.
    public static func requestFields(host: ResolvedHostLanguage, genre: LatinGenre?) -> [String: String] {
        var f = ["hostLanguage": host.language.rawValue, "spanglish": host.spanglish.rawValue]
        if let style = host.voiceStyle { f["voiceStyle"] = style.rawValue }
        if host.speaksSpanish, let genre { f["latinGenre"] = genre.rawValue }
        return f
    }

    /// Full rule list for one request: the fixed rules, the language rule, and the genre note.
    /// Empty for an English host, so today's requests are unchanged.
    public static func instructions(host: ResolvedHostLanguage, genre: LatinGenre?) -> [String] {
        guard host.speaksSpanish else { return [] }
        return rules + [languageRule(host)] + (genre.map { [$0.styleNote] } ?? [])
    }

    /// AI output check: the same text rules as the templates. A line with any problem is
    /// dropped and the template pool is used instead. Pass the line's song titles and
    /// artists as `names` so a name like "La Bomba" is not read as hype.
    /// `names` is required (no default) so a caller on the AI output path cannot forget it;
    /// pass `[]` only when the line names no song.
    public static func acceptsOutput(_ text: String, genre: LatinGenre?, names: [String]) -> Bool {
        LatinHostScriptRules.textProblems(text, genre: genre, names: names).isEmpty
    }
}
