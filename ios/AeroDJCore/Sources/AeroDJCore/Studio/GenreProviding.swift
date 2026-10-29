import Foundation
import Observation

// Genres from Apple Music (-Nova). Two pickers read the storefront's catalog genres through
// `GenreProviding` instead of a hard-coded list:
//  - Tune > Sound > Genres: suggestion chips (`TuneGenreSuggestions`, replaces the old
//    `TuneVocabulary.genres` constant). Custom tags still work.
//  - The add-station walkthrough's genre step (`StationCreationModel`, kind .genre).
// Both fetch once, cache only a success, filter on the device, and expose loading / empty /
// error states with a retry.
//
// SEAM(Atlas): make the MusicKit fetch conform. `MusicCatalogSeedSource` already reads
// `/v1/catalog/{storefront}/genres`; conform it (or a small wrapper) to `GenreProviding`,
// mapping each `Genre` to `CatalogGenre(id: genre.id.rawValue, name: genre.name)`, and pass
// it as `StudioPresentationModel(…, genreProvider:)` in `AppDependencies` (live branch).
// Until then the default `SeedSearchGenreProvider` wraps `genreSeeds(matching: "")`, the same
// endpoint, so nothing is blocked on the seam.
//
// Contract for implementers:
// - Return the storefront's top-level genres, in display order. Leave out the root "Music"
//   genre (catalog ID 34); it is dropped here too.
// - IDs are Apple Music catalog genre IDs (ASCII digits). Others are dropped, never shown.
// - Throw on failure (no partial lists); `CancellationError` when cancelled. Errors map to
//   fixed copy through `seedSearchFailureKind`, never the error's own text.

/// One Apple Music catalog genre for the picker.
public struct CatalogGenre: Equatable, Hashable, Sendable, Identifiable {
    /// Apple Music catalog genre ID (digits, e.g. "14" for Pop).
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The genre list behind the add-station genre step.
public protocol GenreProviding: Sendable {
    /// The storefront's top-level catalog genres. Throws on failure; never a partial list.
    func genres() async throws -> [CatalogGenre]
}

/// Default provider: the app's existing seed search (`genreSeeds(matching: "")`, which in the
/// app is MusicKit catalog genres). Used when no dedicated `GenreProviding` is injected.
public struct SeedSearchGenreProvider: GenreProviding {
    let search: any StationSeedSearching
    public init(_ search: any StationSeedSearching) { self.search = search }

    public func genres() async throws -> [CatalogGenre] {
        try await search.genreSeeds(matching: "").compactMap { row in
            row.seed.kind == .genre ? CatalogGenre(id: row.seed.catalogID, name: row.seed.name) : nil
        }
    }
}

/// A fixed list. Previews and the Test Station only (no network, stable screenshots).
public struct StaticGenreProvider: GenreProviding {
    public let list: [CatalogGenre]
    public init(_ list: [CatalogGenre]) { self.list = list }
    public func genres() async throws -> [CatalogGenre] { list }

    /// Synthetic fixture with real catalog IDs, for previews and the Test Station.
    public static let fixture = StaticGenreProvider([
        .init(id: "14", name: "Pop"), .init(id: "21", name: "Rock"), .init(id: "18", name: "Hip-Hop/Rap"),
        .init(id: "15", name: "R&B/Soul"), .init(id: "11", name: "Jazz"), .init(id: "7", name: "Electronic"),
        .init(id: "1153", name: "Indie Pop"), .init(id: "2", name: "Blues"), .init(id: "5", name: "Classical"),
        .init(id: "10", name: "Singer/Songwriter"), .init(id: "12", name: "Latin"), .init(id: "6", name: "Country"),
    ])
}

public enum GenrePicker {
    /// Apple Music's root genre ("Music"), never a useful pick.
    public static let rootGenreID = "34"

    /// Genres to show for `query`: valid catalog IDs only, de-duplicated by ID, blank names
    /// dropped, order kept, then filtered by name (case- and diacritic-insensitive). A blank
    /// query lists them all.
    public static func rows(_ genres: [CatalogGenre], matching query: String) -> [StationSeedSearchResult] {
        let term = StationSeedSearch.normalizedTerm(query)
        var seen = Set<String>()
        return genres.compactMap { genre in
            let id = genre.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = genre.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard StationSeed.isValidCatalogGenreID(id), id != rootGenreID, !name.isEmpty,
                  seen.insert(id).inserted else { return nil }
            if let term, name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return nil }
            return StationSeedSearchResult(seed: StationSeed(kind: .genre, catalogID: id, name: name))
        }
    }
}

/// Tune > Genres suggestion chips from `GenreProviding` (-Nova). Replaces `TuneVocabulary.genres`.
/// Suggestions are station genre tags (`StationConfiguration` normalization: lowercased,
/// whitespace collapsed, at most `maxTagLength`), so a chip toggles the same tag a typed one would.
@MainActor @Observable
public final class TuneGenreSuggestions {
    public enum Phase: Equatable, Sendable {
        /// No provider (nothing to load). The tag field still takes custom genres.
        case unavailable
        case idle
        case loading
        case loaded
        /// The storefront returned no usable genres.
        case empty
        /// Fixed copy (`SearchFailureCopy`), never the error's own text.
        case failed(message: String)
    }

    /// Most chips shown. The catalog has ~20-30 top-level genres; this keeps the card short.
    public nonisolated static let maxSuggestions = 24

    public private(set) var phase: Phase
    public private(set) var suggestions: [String] = []

    @ObservationIgnored private let provider: (any GenreProviding)?
    @ObservationIgnored private let classifyFailure: @MainActor (Error) -> SearchFailureKind
    @ObservationIgnored private var inFlight = false

    public init(provider: (any GenreProviding)?,
                classifyFailure: @escaping @MainActor (Error) -> SearchFailureKind = { SearchFailureCopy.kind(for: $0) }) {
        self.provider = provider
        self.classifyFailure = classifyFailure
        self.phase = provider == nil ? .unavailable : .idle
    }

    /// Loads once. After a success it does nothing; after a failure it tries again (the
    /// "Try again" button calls this too). Concurrent calls share one fetch.
    public func load() async {
        guard let provider, !inFlight else { return }
        switch phase {
        case .loaded, .empty, .unavailable: return
        case .idle, .loading, .failed: break
        }
        inFlight = true
        defer { inFlight = false }
        phase = .loading
        do {
            let genres = try await provider.genres()
            try Task.checkCancellation()
            suggestions = Self.tags(from: genres)
            phase = suggestions.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            phase = .idle
        } catch {
            guard !Task.isCancelled else { phase = .idle; return }
            phase = .failed(message: SearchFailureCopy.message(for: classifyFailure(error)) ?? Self.fallbackFailure)
        }
    }

    public nonisolated static let fallbackFailure = "Couldn't load genres from Apple Music."

    /// Genre names as station tags: valid catalog genres only (`GenrePicker.rows`), names that
    /// fit `maxTagLength` (never cut mid-word), de-duplicated, order kept, capped.
    public nonisolated static func tags(from genres: [CatalogGenre]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for row in GenrePicker.rows(genres, matching: "") {
            let tag = row.seed.name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            guard tag.count <= StationConfiguration.Limits.maxTagLength, seen.insert(tag).inserted else { continue }
            out.append(tag)
            if out.count == maxSuggestions { break }
        }
        return out
    }
}
