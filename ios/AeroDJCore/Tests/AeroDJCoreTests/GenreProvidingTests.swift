import XCTest
@testable import AeroDJCore

// Genres from Apple Music through `GenreProviding` (-Nova): Tune > Genres chips
// (`TuneGenreSuggestions`, replaces `TuneVocabulary.genres`) and the add-station genre step.
// Fakes only; Atlas's MusicKit conformance plugs in behind the same protocol.

private struct GenresOffline: Error {}

actor FakeGenres: GenreProviding {
    private var outcomes: [Result<[CatalogGenre], Error>]
    private(set) var calls = 0
    init(_ outcomes: Result<[CatalogGenre], Error>...) { self.outcomes = outcomes }
    func genres() async throws -> [CatalogGenre] {
        calls += 1
        let next = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        return try next.get()
    }
}

private actor GatedGenres: GenreProviding {
    private var continuation: CheckedContinuation<[CatalogGenre], Never>?
    private(set) var calls = 0
    var waiting: Bool { continuation != nil }
    func genres() async throws -> [CatalogGenre] { calls += 1; return await withCheckedContinuation { continuation = $0 } }
    func release(_ genres: [CatalogGenre]) { continuation?.resume(returning: genres); continuation = nil }
}

/// Seed search with canned genre rows (for the default adapter).
private actor CannedSeedSearch: StationSeedSearching {
    let genres: [StationSeedSearchResult]
    init(genres: [StationSeedSearchResult]) { self.genres = genres }
    func searchSeeds(_ term: String, kinds: Set<StationSeedKind>, limit: Int) async throws -> [StationSeedSearchResult] { [] }
    func genreSeeds(matching query: String) async throws -> [StationSeedSearchResult] { genres }
    func libraryPlaylistSeeds(limit: Int) async throws -> [StationSeedSearchResult] { [] }
}

private func genreRow(_ id: String, _ name: String, kind: StationSeedKind = .genre) -> StationSeedSearchResult {
    StationSeedSearchResult(seed: StationSeed(kind: kind, catalogID: id, name: name))
}

@MainActor
final class TuneGenreSuggestionsTests: XCTestCase {
    func testLoadsCatalogGenresAsStationTagsOnce() async {
        let fake = FakeGenres(.success([
            .init(id: "34", name: "Music"), .init(id: "14", name: "Pop"), .init(id: "18", name: "Hip-Hop/Rap"),
            .init(id: "1153", name: "Indie  Pop"), .init(id: "x1", name: "Bad ID"), .init(id: "99", name: "pop"),
            .init(id: "50", name: String(repeating: "a", count: StationConfiguration.Limits.maxTagLength + 1)),
        ]))
        let model = TuneGenreSuggestions(provider: fake)
        XCTAssertEqual(model.phase, .idle)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.suggestions, ["pop", "hip-hop/rap", "indie pop"],
                       "root genre, bad IDs, duplicate tags and over-long names dropped; tags normalized like StationConfiguration")
        await model.load()
        let calls = await fake.calls
        XCTAssertEqual(calls, 1, "a success is cached")
    }

    func testSuggestionsAreValidStationTags() async {
        let model = TuneGenreSuggestions(provider: StaticGenreProvider.fixture)
        await model.load()
        XCTAssertFalse(model.suggestions.isEmpty)
        var config = StationConfiguration.default
        config.genres = Array(model.suggestions.prefix(StationConfiguration.Limits.maxTags))
        XCTAssertEqual(config.validated().genres, config.genres, "a chip is exactly the tag the station stores")
    }

    func testCapsTheChipCount() {
        let many = (1...60).map { CatalogGenre(id: "\($0 + 100)", name: "Genre \($0)") }
        XCTAssertEqual(TuneGenreSuggestions.tags(from: many).count, TuneGenreSuggestions.maxSuggestions)
    }

    func testErrorShowsFixedCopyAndRetryLoads() async {
        let fake = FakeGenres(.failure(GenresOffline()), .success([.init(id: "11", name: "Jazz")]))
        let model = TuneGenreSuggestions(provider: fake)
        await model.load()
        guard case .failed(let message) = model.phase else { return XCTFail("error state, got \(model.phase)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("GenresOffline"), "never the error's own text")
        XCTAssertEqual(model.suggestions, [])
        await model.load()                          // "Try again"
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.suggestions, ["jazz"])
    }

    func testEmptyStorefrontIsTheEmptyState() async {
        let model = TuneGenreSuggestions(provider: FakeGenres(.success([.init(id: "34", name: "Music")])))
        await model.load()
        XCTAssertEqual(model.phase, .empty)
    }

    func testNoProviderIsUnavailableAndNeverLoads() async {
        let model = TuneGenreSuggestions(provider: nil)
        await model.load()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertEqual(model.suggestions, [])
    }

    func testLoadingStateAndConcurrentLoadsShareOneFetch() async {
        let gate = GatedGenres()
        let model = TuneGenreSuggestions(provider: gate)
        let first = Task { await model.load() }
        while await !gate.waiting { await Task.yield() }
        XCTAssertEqual(model.phase, .loading)
        await model.load()                          // a second Tune appearance while loading
        await gate.release([.init(id: "14", name: "Pop")])
        await first.value
        XCTAssertEqual(model.phase, .loaded)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
    }

    func testStudioWiresTheInjectedProviderElseTheSeedSearchElseNothing() async {
        let injected = await makeStudio(seedSearch: nil, genres: StaticGenreProvider([.init(id: "11", name: "Jazz")]))
        await injected.tuneGenres.load()
        XCTAssertEqual(injected.tuneGenres.suggestions, ["jazz"])

        let viaSeedSearch = await makeStudio(seedSearch: CannedSeedSearch(genres: [genreRow("14", "Pop"), genreRow("1", "Artist", kind: .artist)]),
                                             genres: nil)
        await viaSeedSearch.tuneGenres.load()
        XCTAssertEqual(viaSeedSearch.tuneGenres.suggestions, ["pop"], "default adapter: MusicCatalogSeedSource.genreSeeds")

        let none = await makeStudio(seedSearch: nil, genres: nil)
        XCTAssertEqual(none.tuneGenres.phase, .unavailable)
    }

    private func makeStudio(seedSearch: (any StationSeedSearching)?, genres: (any GenreProviding)?) async -> StudioPresentationModel {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .default))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let recipes = StationRecipeLibrary(store: InMemoryStationRecipeStore())
        await recipes.load()
        let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(), providers: [],
                                           purger: NoopNarrationPurger())
        return StudioPresentationModel(station: station, recipes: recipes, connections: connections, dj: DJPresentationStore(),
                                       seedSearch: seedSearch, genreProvider: genres)
    }
}

@MainActor
final class AddStationGenreStepTests: XCTestCase {
    private func model(_ genres: any GenreProviding) async -> StationCreationModel {
        let search = CannedSeedSearch(genres: [])
        let studio = await makeCreationStudio(seedSearch: search)
        return StationCreationModel(studio: studio, search: search, kind: .genre, genres: genres)
    }

    func testFetchesOnceFiltersLocallyAndDropsInvalidIDs() async {
        let fake = FakeGenres(.success([
            .init(id: "14", name: "Pop"), .init(id: "21", name: "Rock"), .init(id: "../x", name: "Bad"),
            .init(id: "14", name: "Pop again"), .init(id: "11", name: "Jazz"), .init(id: "7", name: "  "),
            .init(id: "17", name: "Électronique"), .init(id: "34", name: "Music"),
        ]))
        let m = await model(fake)
        await m.search("")
        XCTAssertEqual(m.phase, .results)
        XCTAssertEqual(m.resultsSource, .genres)
        XCTAssertEqual(m.results.map(\.seed.catalogID), ["14", "21", "11", "17"])
        await m.search("ROCK")
        XCTAssertEqual(m.results.map(\.seed.name), ["Rock"])
        await m.search("electro")
        XCTAssertEqual(m.results.map(\.seed.name), ["Électronique"], "diacritic-insensitive")
        await m.search("polka")
        XCTAssertEqual(m.phase, .empty)
        let calls = await fake.calls
        XCTAssertEqual(calls, 1, "one fetch per flow; typing filters the cached list")
    }

    func testErrorIsShownNotCachedAndRetryLoads() async {
        let fake = FakeGenres(.failure(GenresOffline()), .success([.init(id: "14", name: "Pop")]))
        let m = await model(fake)
        await m.search("")
        guard case .failed(let message?) = m.phase else { return XCTFail("error state, got \(m.phase)") }
        XCTAssertFalse(message.isEmpty)
        await m.search("")
        XCTAssertEqual(m.results.map(\.seed.name), ["Pop"])
        let calls = await fake.calls
        XCTAssertEqual(calls, 2)
    }

    func testEmptyStorefrontIsTheEmptyState() async {
        let m = await model(FakeGenres(.success([])))
        await m.search("")
        XCTAssertEqual(m.phase, .empty)
    }

    func testLoadingState() async {
        let gate = GatedGenres()
        let m = await model(gate)
        let task = Task { await m.search("") }
        while await !gate.waiting { await Task.yield() }
        XCTAssertEqual(m.phase, .searching)
        XCTAssertTrue(m.isLoadingGenres)
        await gate.release([.init(id: "14", name: "Pop")])
        await task.value
        XCTAssertFalse(m.isLoadingGenres)
        XCTAssertEqual(m.phase, .results)
    }

    func testPickedGenreSavesAStationInTheList() async {
        let search = CannedSeedSearch(genres: [genreRow("11", "Jazz")])
        let studio = await makeCreationStudio(seedSearch: search)
        let m = try! XCTUnwrap(studio.makeStationCreation(kind: .genre))   // default adapter
        await m.search("ja")
        XCTAssertTrue(m.toggle(m.results[0].seed))
        guard case .success(let recipe) = await m.save(applying: false) else { return XCTFail("saved") }
        XCTAssertEqual(recipe.name, "Jazz Radio")
        XCTAssertEqual(CreatedStations.entries(from: studio.recipes.recipes).map(\.id), [recipe.id])
    }
}
