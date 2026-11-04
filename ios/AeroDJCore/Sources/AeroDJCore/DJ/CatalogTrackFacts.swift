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
    /// The year of `Song.releaseDate`, only for a known non-compilation album with no reissue,
    /// live or soundtrack marker in the song or album title (`CatalogTrackFacts.yearIsTheSongs`).
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
    ///   - songTitle: `Song.title`, only to recognise a reissue or live take (`yearIsTheSongs`).
    ///     Not stored.
    ///   - albumTitle: `Song.albumTitle`. " - Single" / " - EP" releases are left out (not an album).
    ///   - albumIsCompilation: `Album.isCompilation` of the song's album (MusicKit `.albums`).
    ///     Nil (unknown) or true leaves the year out (`yearIsTheSongs`).
    ///   - releaseDate: `Song.releaseDate`, the date of the release this catalog entry sits on,
    ///     not when the song first came out. Spoken only when `yearIsTheSongs`. Read in UTC.
    ///   - genreNames: `Song.genreNames`, in catalog order.
    ///   - songEditorialNote, artistEditorialNote: `editorialNotes.short` of the song and its artist.
    ///   - now: bounds a plausible year (no future release years).
    public init(catalogSongID: String, songTitle: String? = nil, albumTitle: String? = nil,
                albumIsCompilation: Bool? = nil, releaseDate: Date? = nil,
                genreNames: [String] = [], songEditorialNote: String? = nil, artistEditorialNote: String? = nil,
                now: Date = Date()) {
        self.catalogSongID = catalogSongID
        func fact(_ field: CatalogFactField, _ value: String?) -> CatalogFact? {
            value.map { CatalogFact(value: $0, provenance: CatalogFactProvenance(catalogSongID: catalogSongID, field: field)) }
        }
        self.albumTitle = fact(.albumTitle, Self.album(albumTitle))
        let yearIsTheSongs = Self.yearIsTheSongs(songTitle: songTitle, albumTitle: albumTitle,
                                                 albumIsCompilation: albumIsCompilation)
        self.releaseYear = yearIsTheSongs ? fact(.releaseYear, Self.year(releaseDate, now: now)) : nil
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

    /// Single words (whole words, case-insensitive) in a song or album title that mark a reissue,
    /// a compilation, a live recording or a soundtrack: the catalog date is that release's, not
    /// the song's, so the year is left out (Echo's #399 B1).
    static let reissueWords: Set<String> = [
        "remaster", "remastered", "remasters", "deluxe", "expanded", "anniversary", "edition", "editions",
        "hits", "collection", "collections", "anthology", "essential", "essentials", "gold", "live",
        "soundtrack", "soundtracks", "ost", "compilation", "compilations", "reissue", "reissued",
    ]
    /// Multi-word markers, matched as consecutive whole words ("greatest hits" is also `hits`).
    static let reissuePhrases: [[String]] = [["best", "of"], ["very", "best"], ["greatest", "hits"]]

    /// True when `title` carries a reissue, compilation, live or soundtrack marker
    /// (`reissueWords`, `reissuePhrases`).
    static func marksReissue(_ title: String?) -> Bool {
        guard let title else { return false }
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: reissueWords.contains) { return true }
        return reissuePhrases.contains { phrase in
            words.count >= phrase.count
                && (0...(words.count - phrase.count)).contains { Array(words[$0..<$0 + phrase.count]) == phrase }
        }
    }

    /// The release year may be spoken as the song's only when the album is known not to be a
    /// compilation and neither title marks a reissue, live take or soundtrack. Unknown is no:
    /// the year is dropped, never repaired.
    static func yearIsTheSongs(songTitle: String?, albumTitle: String?, albumIsCompilation: Bool?) -> Bool {
        albumIsCompilation == false && !marksReissue(albumTitle) && !marksReissue(songTitle)
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
    /// Wording per Echo's #399 N1 (a DJ talking, not metadata read out). The note lead-ins are
    /// short on purpose: a line must fit `maxLineSeconds` (12 words at 150 wpm), so "editors say:"
    /// keeps notes up to 8 words speakable; a longer note is left out, never cut.
    public static let templates: [String] = [
        "That's from the album {album}, released in {year}.",
        "That one's off the album {album}.",
        "That came out in {year}.",
        "A little {genre} for you there.",
        "From {album}, filed under {genre}.",
        "Apple Music's editors say: {songNote}",
        "Apple Music's take on the artist: {artistNote}",
    ]

    /// Cadence (Echo's #399 N2, Orion's spec): at most one fact line in any run of this many
    /// eligible breaks (a natural break whose song still has an unspoken, usable catalog fact).
    /// At 3: after a fact line the next two eligible breaks carry none, so never two in a row and
    /// it stays a radio station, not a fact feed. Breaks without usable facts do not count.
    public static let eligibleBreaksPerFactLine = 3

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
    ///
    /// The timeout is a hard deadline (Sentinel's #399 N1): the lookup runs in its own task and
    /// is raced against a sleep; when the sleep wins, the lookup is cancelled and NOT awaited, so
    /// a MusicKit request that ignores cancellation can never hold the queue past `timeout`.
    static func facts(for tracks: [DJTrack], from source: any CatalogTrackFactsSource,
                      timeout: Duration) async -> [String: CatalogTrackFacts] {
        var seen = Set<String>()
        let ids = tracks.filter { $0.origin == .catalog && !$0.id.isEmpty }.map(\.id).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return [:] }
        let race = FirstResult<[String: CatalogTrackFacts]>()
        let lookup = Task { race.resume(await source.facts(forCatalogSongIDs: ids)) }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            race.resume(nil)
        }
        let found = await withTaskCancellationHandler {
            await race.value()
        } onCancel: {
            race.resume(nil)
        }
        lookup.cancel()
        deadline.cancel()
        guard let found else { return [:] }
        let asked = Set(ids)
        return found.filter { asked.contains($0.key) && $0.value.catalogSongID == $0.key && !$0.value.isEmpty }
    }
}

/// The first of several racers to call `resume` wins; later calls are ignored. Nil: no result
/// (the deadline fired or the waiter was cancelled).
final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value??
    private var waiter: CheckedContinuation<Value?, Never>?

    func resume(_ value: Value?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .some(value)
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: value)
    }

    func value() async -> Value? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
