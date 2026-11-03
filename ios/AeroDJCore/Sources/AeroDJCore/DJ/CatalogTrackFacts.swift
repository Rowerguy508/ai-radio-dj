import Foundation

// #199 (-Fry): artist and song facts in DJ commentary, from the Apple Music catalog only.
//
// Owner decision (Nov 3, 2026): MusicKit catalog data is the only source. No outside enrichment
// provider, no new network service, no model. The DJ may say a fact only when it is a field of
// `CatalogTrackFacts`, and it says it through the fixed `CatalogFactLine.templates` allow-list,
// whose only placeholders are those fields. Nothing is generated, paraphrased or embellished:
// a missing or rejected field leaves every template that needs it unusable, and a track with no
// usable field gets no fact line at all.
//
// Privacy: facts are looked up and spoken only for `.catalog` tracks (`DJTrack.origin`); library
// and unknown tracks never get one, and their ids are never put in a catalog request. A fact line
// is attributed `.trackMetadata(trackIDs: [that track])`, so it routes exactly like the
// back-announce it follows (`VoiceRenderer.mayLeaveDevice`, the library-seed on-device gate).
//
// Length: a fact line is an optional line of an ordinary break. It is estimated at most
// `CatalogFactLine.maxLineSeconds`, and the planner's own fit (and the measured-audio trim in
// `DJBreakPreparer`) drop it rather than let the break exceed `maxOrdinaryBreakSeconds` (12 s).

/// Which catalog property a fact was read from. Provenance only: never spoken.
public enum CatalogFactField: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    /// `Song.albumTitle`.
    case albumTitle
    /// The year of `Song.releaseDate`.
    case releaseYear
    /// The first specific entry of `Song.genreNames` (the generic "Music" is skipped).
    case genreName
    /// `Song.editorialNotes.short`, trimmed to its first sentence.
    case songEditorialNote
    /// `Artist.editorialNotes.short` of the song's first artist, trimmed to its first sentence.
    case artistEditorialNote
}

/// Where one fact came from: the Apple Music catalog item and property. Never spoken.
public struct CatalogFactProvenance: Equatable, Hashable, Sendable {
    /// Always the Apple Music catalog (MusicKit). There is no other provider.
    public static let source = "Apple Music catalog (MusicKit)"
    /// Catalog id of the song the fact describes (the `DJTrack.id` of a `.catalog` track).
    public let catalogSongID: String
    public let field: CatalogFactField
    public var source: String { Self.source }
    public init(catalogSongID: String, field: CatalogFactField) {
        self.catalogSongID = catalogSongID
        self.field = field
    }
}

/// One catalog fact: the value as it may be spoken, and where it came from.
public struct CatalogFact: Equatable, Hashable, Sendable {
    public let value: String
    public let provenance: CatalogFactProvenance
    public var field: CatalogFactField { provenance.field }
}

/// The catalog facts of one song, validated on the way in. Raw MusicKit values go in; only values
/// that are safe to speak verbatim come out. Rejected values are simply absent (never repaired
/// into something the catalog did not say).
public struct CatalogTrackFacts: Equatable, Sendable {
    /// Notes longer than this (first sentence) are left out, never cut mid-sentence.
    public static let maxNoteWords = 9
    /// Album, genre: longer values are left out.
    public static let maxNameWords = 7
    /// The generic genre every Apple Music song carries; it says nothing.
    static let genericGenres: Set<String> = ["music"]

    public let catalogSongID: String
    public let albumTitle: CatalogFact?
    public let releaseYear: CatalogFact?
    public let genreName: CatalogFact?
    public let songEditorialNote: CatalogFact?
    public let artistEditorialNote: CatalogFact?

    /// - Parameters:
    ///   - catalogSongID: the song's catalog id (`Song.id.rawValue`).
    ///   - songTitle: `Song.title`, only to recognise a remaster (whose release date is the
    ///     reissue's, so the year is left out) and a title-named single. Not stored.
    ///   - albumTitle: `Song.albumTitle`. " - Single" / " - EP" releases are left out (not an album).
    ///   - releaseDate: `Song.releaseDate`. Read in UTC, so the year never shifts by time zone.
    ///   - genreNames: `Song.genreNames`, in catalog order.
    ///   - songEditorialNote, artistEditorialNote: `editorialNotes.short` of the song and its artist.
    ///   - now: bounds a plausible year (no future release years).
    public init(catalogSongID: String, songTitle: String? = nil, albumTitle: String? = nil, releaseDate: Date? = nil,
                genreNames: [String] = [], songEditorialNote: String? = nil, artistEditorialNote: String? = nil,
                now: Date = Date()) {
        self.catalogSongID = catalogSongID
        func fact(_ field: CatalogFactField, _ value: String?) -> CatalogFact? {
            value.map { CatalogFact(value: $0, provenance: CatalogFactProvenance(catalogSongID: catalogSongID, field: field)) }
        }
        let remaster = songTitle.map { $0.range(of: "remaster", options: .caseInsensitive) != nil } ?? false
            || albumTitle.map { $0.range(of: "remaster", options: .caseInsensitive) != nil } ?? false
        self.albumTitle = fact(.albumTitle, Self.album(albumTitle))
        self.releaseYear = remaster ? nil : fact(.releaseYear, Self.year(releaseDate, now: now))
        self.genreName = fact(.genreName, genreNames.lazy.compactMap(Self.genre).first)
        self.songEditorialNote = fact(.songEditorialNote, Self.note(songEditorialNote))
        self.artistEditorialNote = fact(.artistEditorialNote, Self.note(artistEditorialNote))
    }

    /// Every usable fact, in field order.
    public var facts: [CatalogFact] {
        [albumTitle, releaseYear, genreName, songEditorialNote, artistEditorialNote].compactMap { $0 }
    }

    public var isEmpty: Bool { facts.isEmpty }

    // MARK: Validation (verbatim or nothing)

    /// Plain, speakable catalog text, or nil: HTML and markup removed, instruction-shaped text,
    /// template braces and line breaks rejected.
    static func plain(_ raw: String?) -> String? {
        // A raw line break, brace or pipe is rejected, never repaired (markup is stripped below).
        guard let raw, !raw.contains(where: { "{}\n\r|".contains($0) }) else { return nil }
        let screen = PromptInjectionSanitizer()
        guard !screen.isSuspicious(raw) else { return nil }
        let text = screen.sanitize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { "{}<>\n\r|".contains($0) }), !screen.isSuspicious(text) else { return nil }
        return text
    }

    static func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    static func album(_ raw: String?) -> String? {
        guard let text = plain(raw) else { return nil }
        let lower = text.lowercased()
        if lower.hasSuffix(" - single") || lower.hasSuffix(" - ep") { return nil }
        let spoken = SpokenTitle.clean(text)
        guard !spoken.isEmpty, words(spoken) <= maxNameWords else { return nil }
        return spoken
    }

    static func year(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let year = utc.component(.year, from: date)
        guard year >= 1900, year <= utc.component(.year, from: now) else { return nil }
        return String(year)
    }

    static func genre(_ raw: String) -> String? {
        guard let text = plain(raw), !genericGenres.contains(text.lowercased()), words(text) <= maxNameWords else { return nil }
        return text
    }

    /// The note's first sentence, verbatim, if it is short enough; nil otherwise. A long first
    /// sentence is left out, never shortened: a cut sentence can say something the note did not.
    static func note(_ raw: String?) -> String? {
        guard let text = plain(raw) else { return nil }
        var end = text.endIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next == text.endIndex || text[next] == " " { end = next; break }
            index = next
        }
        let sentence = String(text[..<end]).trimmingCharacters(in: .whitespaces)
        guard words(sentence) >= 2, words(sentence) <= maxNoteWords, let last = sentence.last, ".!?".contains(last)
        else { return nil }
        return sentence
    }
}

/// Supplies catalog facts for a queue. The app's implementation reads the Apple Music catalog
/// through MusicKit (`MusicKitCatalogFactsSource`); tests pass fixtures.
public protocol CatalogTrackFactsSource: Sendable {
    /// Facts for the given catalog song ids (only `.catalog` tracks are ever asked). Ids with no
    /// catalog data are absent. Never throws: offline, unauthorized or no subscription is `[:]`.
    func facts(forCatalogSongIDs ids: [String]) async -> [String: CatalogTrackFacts]
}

/// The fixed fact phrasing. Every placeholder is a `CatalogTrackFacts` field; there is no other
/// value a fact line can contain. A template is usable only when each of its fields is present.
public enum CatalogFactLine {
    /// A fact line longer than this (word-rate estimate) is not planned.
    public static let maxLineSeconds = 5

    /// Placeholder key for each field.
    static let keys: [CatalogFactField: String] = [
        .albumTitle: "album", .releaseYear: "year", .genreName: "genre",
        .songEditorialNote: "songNote", .artistEditorialNote: "artistNote",
    ]

    /// The allow-list. Only these sentences, with only these placeholders, are ever spoken.
    public static let templates: [String] = [
        "That's from the album {album}, released in {year}.",
        "That one's off the album {album}.",
        "That came out in {year}.",
        "Apple Music files that one under {genre}.",
        "From {album}, filed under {genre}.",
        "Apple Music's note: {songNote}",
        "Apple Music on the artist: {artistNote}",
    ]

    /// Placeholder values for `facts`, keyed for `templates`. Values that contain the title of a
    /// queue song other than `trackTitle` are left out, so a fact line never names another song
    /// (its attribution names only this track, #388).
    static func values(_ facts: CatalogTrackFacts, otherTitles: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for fact in facts.facts {
            guard let key = keys[fact.field] else { continue }
            let lower = fact.value.lowercased()
            if otherTitles.contains(where: { !$0.isEmpty && lower.contains($0.lowercased()) }) { continue }
            out[key] = fact.value
        }
        return out
    }

    /// The facts a rendered line used (template placeholders that were filled).
    static func usedFacts(template: String, facts: CatalogTrackFacts) -> [CatalogFact] {
        facts.facts.filter { fact in keys[fact.field].map { template.contains("{\($0)}") } ?? false }
    }
}

/// Bounded catalog-fact lookup for one queue (`DJBreakSession.queueStarted`).
enum CatalogFactsFetch {
    /// Facts for the `.catalog` tracks of `tracks`, keyed by track id. Only ids of `.catalog`
    /// tracks are passed to `source`, and only facts for those ids (whose `catalogSongID`
    /// matches) are kept. Past `timeout` the lookup is abandoned and `[:]` is returned.
    static func facts(for tracks: [DJTrack], from source: any CatalogTrackFactsSource,
                      timeout: Duration) async -> [String: CatalogTrackFacts] {
        var seen = Set<String>()
        let ids = tracks.filter { $0.origin == .catalog && !$0.id.isEmpty }.map(\.id).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return [:] }
        let found: [String: CatalogTrackFacts]? = await withTaskGroup(of: [String: CatalogTrackFacts]?.self) { group in
            group.addTask { await source.facts(forCatalogSongIDs: ids) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let found else { return [:] }
        let asked = Set(ids)
        return found.filter { asked.contains($0.key) && $0.value.catalogSongID == $0.key && !$0.value.isEmpty }
    }
}
