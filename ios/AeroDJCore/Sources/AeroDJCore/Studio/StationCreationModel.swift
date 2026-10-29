import Foundation
import Observation

// Station creation view model (-Atlas) for the add-station walkthrough (Nova's UI). It owns
// the pick-and-save flow only: search, pick, choose a discovery level, save. Saving goes
// through `StudioPresentationModel.saveRecipe(named:from:applying:)`, the same entry point
// the Tune form's "Save" uses. It never plays, queues or logs; search results and picks
// (including the listener's library playlists) stay in memory and are never written anywhere
// except into the saved recipe's seeds.

/// The app's seed search (app: `MusicCatalogSeedSource`). Every method follows
/// `StationSeedSearch.run`'s rules: a blank term searches nothing, and a cancelled search
/// throws `CancellationError` with no partial results.
public protocol StationSeedSearching: Sendable {
    /// Apple Music catalog search limited to `kinds` (`.artist`, `.playlist`, `.song`; `.genre`
    /// is ignored here, use `genreSeeds(matching:)`). Results are `.catalog` seeds.
    func searchSeeds(_ term: String, kinds: Set<StationSeedKind>, limit: Int) async throws -> [StationSeedSearchResult]
    /// The storefront's genres whose name contains `query`; a blank query lists them all.
    func genreSeeds(matching query: String) async throws -> [StationSeedSearchResult]
    /// The listener's own library playlists, as `.library` seeds. On-device only; private.
    func libraryPlaylistSeeds(limit: Int) async throws -> [StationSeedSearchResult]
}

@MainActor @Observable
public final class StationCreationModel {
    /// Where the result list is. Failure copy is fixed text from `SearchFailureCopy`, never an error's own text.
    public enum Phase: Equatable, Sendable {
        case idle
        case searching
        case results
        /// The search ran and found nothing.
        case empty
        /// `message` is nil when there is nothing to show (a newer search replaced this one).
        case failed(message: String?)
    }

    /// Which list `results` holds, so the UI can label it ("Your playlists" vs search results).
    public enum ResultsSource: Equatable, Sendable { case none, catalogSearch, genres, libraryPlaylists }

    public private(set) var kind: StationCreationKind
    /// Defaults to the level closest to the station the controls show.
    public var level: StationDiscoveryLevel
    /// Talk-level step. `nil` (the default) keeps the on-screen tuning.
    public var commentary: CommentaryFrequency?
    /// DJ presenter step. `nil` (the default) keeps the on-screen tuning.
    public var personality: DJPersonality?
    /// Picks in order. At most `kind.maxSeeds`.
    public private(set) var selected: [StationSeed] = []
    public private(set) var results: [StationSeedSearchResult] = []
    public private(set) var resultsSource: ResultsSource = .none
    public private(set) var phase: Phase = .idle
    public private(set) var isSaving = false
    /// The last save's failure, for a banner (`userMessage`). Cleared by the next save or pick.
    public private(set) var saveError: StationRecipeError?

    /// Search results per request. MusicKit caps catalog search at 25 per type.
    public nonisolated static let resultLimit = 25
    /// Library playlists listed at most (on-device read, no catalog cap).
    public nonisolated static let libraryPlaylistLimit = 200

    /// `limit` clamped to 1...`libraryPlaylistLimit`, for the app's library read.
    public nonisolated static func clampedLibraryLimit(_ limit: Int) -> Int { min(max(limit, 1), libraryPlaylistLimit) }

    @ObservationIgnored private let studio: StudioPresentationModel
    @ObservationIgnored private let search: any StationSeedSearching
    @ObservationIgnored private let classifyFailure: @MainActor (Error) -> SearchFailureKind
    @ObservationIgnored private var generation = 0
    /// Genre step source (`GenreProviding`); fetched once per flow, cached only on success.
    @ObservationIgnored private let genreProvider: any GenreProviding
    @ObservationIgnored private var cachedGenres: [CatalogGenre]?

    public init(studio: StudioPresentationModel, search: any StationSeedSearching,
                kind: StationCreationKind = .artists, level: StationDiscoveryLevel? = nil,
                genres: (any GenreProviding)? = nil,
                classifyFailure: @escaping @MainActor (Error) -> SearchFailureKind = { SearchFailureCopy.kind(for: $0) }) {
        self.studio = studio
        self.search = search
        self.genreProvider = genres ?? SeedSearchGenreProvider(search)
        self.kind = kind
        self.level = level ?? StationDiscoveryLevel.closest(to: studio.station.displayed)
        self.classifyFailure = classifyFailure
    }

    // MARK: Derived state (bind these)

    /// The request the current picks make, or nil with nothing picked.
    public var request: StationCreationRequest? {
        guard !selected.isEmpty else { return nil }
        let source: StationCreationSource = switch kind {
        case .artists: .artists(selected)
        case .genre: .genre(selected[0])
        case .playlist: .playlist(selected[0])
        }
        return StationCreationRequest(source: source, level: level, commentary: commentary, personality: personality)
    }

    /// Why the picks can't be saved yet (`.noSeeds` with nothing picked).
    public var validationError: StationCreationError? {
        guard let request else { return .noSeeds }
        if case .failure(let e) = request.validatedSeeds() { return e }
        return nil
    }

    public var canSave: Bool { validationError == nil && !isSaving }
    /// A name to prefill the name field with; nil until the picks are valid.
    public var suggestedName: String? { request?.suggestedName }
    /// Set when a library pick limits the station to what was picked (show `message`).
    public var reachRestriction: StationReachRestriction? { StationReach.restriction(for: selected) }
    /// True when another pick is allowed (artists: under `StationCreationRequest.maxArtists`).
    public var canPickMore: Bool { selected.count < kind.maxSeeds }

    public func isSelected(_ seed: StationSeed) -> Bool { selected.contains { $0.key == seed.key } }

    // MARK: Actions

    /// Switches between artists, genre and playlist. Clears picks and results when it changes.
    public func setKind(_ newKind: StationCreationKind) {
        guard newKind != kind else { return }
        kind = newKind
        selected = []
        clearResults()
        saveError = nil
    }

    /// Picks or unpicks `seed`. Returns false (and changes nothing) for a seed of another kind or
    /// a blank one, or an extra artist past the cap. A genre or playlist pick replaces the previous one.
    @discardableResult
    public func toggle(_ seed: StationSeed) -> Bool {
        guard seed.kind == kind.seedKind, let clean = seed.normalized() else { return false }
        saveError = nil
        if let index = selected.firstIndex(where: { $0.key == clean.key }) {
            selected.remove(at: index)
            return true
        }
        if kind.maxSeeds == 1 { selected = [clean]; return true }
        guard canPickMore else { return false }
        selected.append(clean)
        return true
    }

    /// Searches for the current kind: catalog artists, catalog playlists, or genres by name
    /// (a blank genre query lists every genre; a blank artist or playlist term clears the list).
    /// A newer search, kind change or cancellation replaces this one's results.
    public func search(_ term: String) async {
        let kind = kind
        let source: ResultsSource = kind == .genre ? .genres : .catalogSearch
        if kind != .genre, StationSeedSearch.normalizedTerm(term) == nil {
            clearResults()
            return
        }
        await run(source) { search in
            switch kind {
            case .genre: GenrePicker.rows(try await self.catalogGenres(), matching: term)
            case .artists, .playlist: try await search.searchSeeds(term, kinds: [kind.seedKind], limit: Self.resultLimit)
            }
        }
    }

    /// Lists the listener's library playlists (playlist stations only). They stay on the device.
    public func loadLibraryPlaylists() async {
        guard kind == .playlist else { return }
        await run(.libraryPlaylists) { search in try await search.libraryPlaylistSeeds(limit: Self.libraryPlaylistLimit) }
    }

    /// Saves the picks as a recipe through `studio.saveRecipe(named:from:applying:)`. A nil or
    /// blank `name` uses `suggestedName`. With `applying` (the default) the new station also
    /// becomes the live one under the normal boundary rules. On success the picks are cleared.
    @discardableResult
    public func save(named name: String? = nil, applying: Bool = true) async -> Result<StationRecipe, StationRecipeError> {
        guard !isSaving else { return .failure(.saveFailed) }
        guard let request else { return finish(.failure(.invalidStation(.noSeeds))) }
        let typed = name.flatMap { StationSeedSearch.normalizedTerm($0) }
        let chosen = typed ?? request.suggestedName ?? ""
        isSaving = true
        let result = await studio.saveRecipe(named: chosen, from: request, applying: applying)
        isSaving = false
        if case .success = result {
            selected = []
            clearResults()
        }
        return finish(result)
    }

    /// True while the genre list has not loaded yet (the genre step's first fetch or a retry
    /// after an error). Lets the UI say "Loading genres" rather than "Searching".
    public var isLoadingGenres: Bool { kind == .genre && phase == .searching && cachedGenres == nil }

    // MARK: Internals

    /// The storefront's genres: the cached list, or one fetch (a failure isn't cached, so the
    /// next search retries).
    private func catalogGenres() async throws -> [CatalogGenre] {
        if let cachedGenres { return cachedGenres }
        let fetched = try await genreProvider.genres()
        try Task.checkCancellation()
        cachedGenres = fetched
        return fetched
    }


    private func finish(_ result: Result<StationRecipe, StationRecipeError>) -> Result<StationRecipe, StationRecipeError> {
        if case .failure(let e) = result { saveError = e } else { saveError = nil }
        return result
    }

    private func clearResults() {
        generation += 1
        results = []
        resultsSource = .none
        phase = .idle
    }

    private func run(_ source: ResultsSource,
                     _ perform: (any StationSeedSearching) async throws -> [StationSeedSearchResult]) async {
        generation += 1
        let mine = generation
        let kind = kind
        phase = .searching
        do {
            let found = try await perform(search)
            guard mine == generation, kind == self.kind, !Task.isCancelled else { return }
            // Only rows of the current kind, de-duplicated by seed key, order kept.
            var seen = Set<StationSeed.Key>()
            results = found.filter { $0.seed.kind == kind.seedKind && seen.insert($0.seed.key).inserted }
            resultsSource = source
            phase = results.isEmpty ? .empty : .results
        } catch {
            guard mine == generation else { return }
            if error is CancellationError || Task.isCancelled {
                phase = results.isEmpty ? .idle : .results
                return
            }
            results = []
            resultsSource = .none
            phase = .failed(message: SearchFailureCopy.message(for: classifyFailure(error)))
        }
    }
}

public extension StudioPresentationModel {
    /// A fresh add-station flow over this Studio, or nil when the app has no seed search
    /// (previews and the Test Station pass none). Create one per walkthrough presentation.
    func makeStationCreation(kind: StationCreationKind = .artists) -> StationCreationModel? {
        guard let seedSearch else { return nil }
        return StationCreationModel(studio: self, search: seedSearch, kind: kind, genres: genreProvider,
                                    classifyFailure: seedSearchFailureKind)
    }
}
