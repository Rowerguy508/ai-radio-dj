import XCTest
@testable import AeroDJCore

// Add-station view model (-Atlas): search per kind through `StationSeedSearching` (fake here),
// pick rules, discovery level, and save through `studio.saveRecipe(named:from:applying:)`.

private func seed(_ kind: StationSeedKind, _ id: String, _ name: String? = nil,
                  _ source: StationSeedSource = .catalog) -> StationSeed {
    StationSeed(kind: kind, catalogID: id, name: name ?? "Name \(id)", source: source)
}

private struct Offline: Error {}

/// Records calls; returns canned rows. Applies the shared blank-term rule like the app adapter.
private actor FakeSeedSearch: StationSeedSearching {
    var catalog: [StationSeedSearchResult] = []
    var genres: [StationSeedSearchResult] = []
    var library: [StationSeedSearchResult] = []
    var fail: Error?
    private(set) var calls: [String] = []
    private(set) var kindsAsked: [Set<StationSeedKind>] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false

    func set(catalog: [StationSeedSearchResult] = [], genres: [StationSeedSearchResult] = [],
             library: [StationSeedSearchResult] = [], fail: Error? = nil) {
        self.catalog = catalog; self.genres = genres; self.library = library; self.fail = fail
    }
    func holdNextCall() { holdNext = true }
    func release() { gate?.resume(); gate = nil }

    private func maybeHold() async {
        guard holdNext else { return }
        holdNext = false
        await withCheckedContinuation { gate = $0 }
    }

    func searchSeeds(_ term: String, kinds: Set<StationSeedKind>, limit: Int) async throws -> [StationSeedSearchResult] {
        try await StationSeedSearch.run(term: term, limit: limit) { _, _ in
            calls.append("search"); kindsAsked.append(kinds)
            await maybeHold()
            if let fail { throw fail }
            return catalog.filter { kinds.contains($0.seed.kind) }
        }
    }
    func genreSeeds(matching query: String) async throws -> [StationSeedSearchResult] {
        calls.append("genres")
        if let fail { throw fail }
        guard let q = StationSeedSearch.normalizedTerm(query) else { return genres }
        return genres.filter { $0.seed.name.localizedCaseInsensitiveContains(q) }
    }
    func libraryPlaylistSeeds(limit: Int) async throws -> [StationSeedSearchResult] {
        calls.append("library")
        if let fail { throw fail }
        return Array(library.prefix(limit))
    }
}

@MainActor
final class StationCreationModelTests: XCTestCase {
    private func make(_ fake: FakeSeedSearch, active: StationConfiguration = .default) async -> (StudioPresentationModel, StationCreationModel) {
        let studio = await makeCreationStudio(active: active, seedSearch: fake)
        return (studio, try! XCTUnwrap(studio.makeStationCreation()))
    }

    func testNoSeedSearchNoFlow() async {
        let studio = await makeCreationStudio()
        XCTAssertNil(studio.makeStationCreation(), "previews and the Test Station have no seed search")
    }

    func testArtistSearchAsksForArtistsOnlyAndKeepsArtistRows() async {
        let fake = FakeSeedSearch()
        await fake.set(catalog: [.init(seed: seed(.artist, "1")), .init(seed: seed(.playlist, "p")),
                                 .init(seed: seed(.artist, "1")), .init(seed: seed(.artist, "2"))])
        let (_, model) = await make(fake)
        XCTAssertEqual(model.kind, .artists)
        XCTAssertEqual(model.phase, .idle)
        await model.search("  ")
        let blankCalls = await fake.calls
        XCTAssertEqual(blankCalls, [], "a blank term never reaches the network")
        await model.search("björk")
        let kinds = await fake.kindsAsked
        XCTAssertEqual(kinds, [[.artist]])
        XCTAssertEqual(model.results.map(\.seed.catalogID), ["1", "2"], "right kind only, de-duplicated")
        XCTAssertEqual(model.resultsSource, .catalogSearch)
        XCTAssertEqual(model.phase, .results)
    }

    func testGenresBrowseWithABlankQueryAndFilterByName() async {
        let fake = FakeSeedSearch()
        await fake.set(genres: [.init(seed: seed(.genre, "21", "Rock")), .init(seed: seed(.genre, "14", "Pop"))])
        let (_, model) = await make(fake)
        model.setKind(.genre)
        await model.search("")
        XCTAssertEqual(model.results.map(\.seed.name), ["Rock", "Pop"])
        XCTAssertEqual(model.resultsSource, .genres)
        await model.search("po")
        XCTAssertEqual(model.results.map(\.seed.name), ["Pop"])
        await model.search("zzz")
        XCTAssertEqual(model.phase, .empty)
    }

    func testLibraryPlaylistsOnlyForPlaylistStations() async {
        let fake = FakeSeedSearch()
        await fake.set(library: [.init(seed: seed(.playlist, "p.1", "Mine", .library))])
        let (_, model) = await make(fake)
        await model.loadLibraryPlaylists()
        let none = await fake.calls
        XCTAssertEqual(none, [], "an artists station never reads library playlists")
        model.setKind(.playlist)
        await model.loadLibraryPlaylists()
        XCTAssertEqual(model.resultsSource, .libraryPlaylists)
        XCTAssertTrue(model.toggle(model.results[0].seed))
        XCTAssertEqual(model.reachRestriction, .librarySeeds)
        XCTAssertFalse(String(describing: model.selected).contains("Mine"), "seeds stay redacted")
    }

    func testPickRules() async {
        let (_, model) = await make(FakeSeedSearch())
        XCTAssertFalse(model.toggle(seed(.genre, "21")), "wrong kind")
        XCTAssertFalse(model.toggle(seed(.artist, "  ")), "blank")
        for i in 1...StationCreationRequest.maxArtists { XCTAssertTrue(model.toggle(seed(.artist, "\(i)"))) }
        XCTAssertFalse(model.canPickMore)
        XCTAssertFalse(model.toggle(seed(.artist, "99")), "past the cap")
        XCTAssertTrue(model.toggle(seed(.artist, "1")), "tapping a pick again removes it")
        XCTAssertEqual(model.selected.count, StationCreationRequest.maxArtists - 1)
        XCTAssertTrue(model.isSelected(seed(.artist, "2")))

        model.setKind(.playlist)
        XCTAssertEqual(model.selected, [], "changing kind clears picks")
        XCTAssertTrue(model.toggle(seed(.playlist, "a")))
        XCTAssertTrue(model.toggle(seed(.playlist, "b")))
        XCTAssertEqual(model.selected.map(\.catalogID), ["b"], "one playlist: a new pick replaces it")
    }

    func testValidationAndSuggestedName() async {
        let (_, model) = await make(FakeSeedSearch())
        XCTAssertEqual(model.validationError, .noSeeds)
        XCTAssertFalse(model.canSave)
        XCTAssertNil(model.suggestedName)
        model.setKind(.genre)
        model.toggle(seed(.genre, "x/../1", "Bad"))
        XCTAssertEqual(model.validationError, .invalidGenreID)
        XCTAssertFalse(model.canSave)
        model.toggle(seed(.genre, "21", "Rock"))
        XCTAssertNil(model.validationError)
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.suggestedName, "Rock Radio")
    }

    func testLevelDefaultsToTheClosestOfTheCurrentStation() async {
        let (_, balanced) = await make(FakeSeedSearch())
        XCTAssertEqual(balanced.level, .balanced)
        let (_, adventurous) = await make(FakeSeedSearch(), active: StationConfiguration(discovery: 0.8, reach: .broad))
        XCTAssertEqual(adventurous.level, .adventurous)
    }

    func testSaveUsesTheSuggestedNameAppliesAndClears() async throws {
        let (studio, model) = await make(FakeSeedSearch())
        model.toggle(seed(.artist, "1", "A"))
        model.toggle(seed(.artist, "2", "B"))
        model.level = .adventurous
        let recipe = try await model.save().get()
        XCTAssertEqual(recipe.name, "A & B Radio")
        XCTAssertEqual(recipe.configuration.reach, .broad)
        XCTAssertEqual(studio.recipes.recipes.map(\.id), [recipe.id])
        XCTAssertEqual(studio.station.active.seeds.map(\.catalogID), ["1", "2"], "applied by default")
        XCTAssertEqual(model.selected, [])
        XCTAssertNil(model.saveError)
    }

    func testSaveWithATypedNameAndWithoutApplying() async throws {
        let (studio, model) = await make(FakeSeedSearch())
        model.setKind(.playlist)
        model.toggle(seed(.playlist, "pl.1", "Chill"))
        let recipe = try await model.save(named: "  Sunday  ", applying: false).get()
        XCTAssertEqual(recipe.name, "Sunday")
        XCTAssertEqual(studio.station.active.seeds, [])
    }

    func testSaveFailuresAreReportedAndKeepPicks() async throws {
        let (studio, model) = await make(FakeSeedSearch())
        let empty = await model.save()
        XCTAssertEqual(empty, .failure(.invalidStation(.noSeeds)))
        _ = try await studio.saveRecipe(named: "Taken").get()
        model.toggle(seed(.artist, "1"))
        let duplicate = await model.save(named: "taken")
        XCTAssertEqual(duplicate, .failure(.duplicateName))
        XCTAssertEqual(model.saveError, .duplicateName)
        XCTAssertEqual(model.selected.count, 1, "picks survive a failed save")
        model.toggle(seed(.artist, "2"))
        XCTAssertNil(model.saveError, "a new pick clears the banner")
    }

    func testFailedSearchShowsFixedCopyOnly() async {
        let fake = FakeSeedSearch()
        await fake.set(fail: URLError(.notConnectedToInternet))
        let (_, model) = await make(fake)
        await model.search("secret term")
        guard case .failed(let message) = model.phase else { return XCTFail("expected failure") }
        XCTAssertEqual(message, SearchFailureCopy.message(for: .offline))
        XCTAssertFalse(message?.contains("secret") ?? true)
        XCTAssertEqual(model.results, [])
    }

    func testInjectedFailureMapperIsUsed() async {
        let fake = FakeSeedSearch()
        await fake.set(fail: Offline())
        let station = await makeCreationStudio(seedSearch: fake)
        let model = StationCreationModel(studio: station, search: fake, classifyFailure: { _ in .noSubscription })
        await model.search("x")
        XCTAssertEqual(model.phase, .failed(message: SearchFailureCopy.message(for: .noSubscription)))
    }

    func testAStaleSearchNeverOverwritesANewerOne() async {
        let fake = FakeSeedSearch()
        await fake.set(catalog: [.init(seed: seed(.artist, "1"))])
        let (_, model) = await make(fake)
        await fake.holdNextCall()
        let slow = Task { await model.search("slow") }
        while await fake.calls.isEmpty { await Task.yield() }
        model.setKind(.genre)            // supersedes the held search
        await fake.release()
        await slow.value
        XCTAssertEqual(model.results, [], "the artists search finished after the kind changed")
        XCTAssertEqual(model.phase, .idle)
    }

    func testACancelledSearchShowsNoError() async {
        let fake = FakeSeedSearch()
        await fake.set(catalog: [.init(seed: seed(.artist, "1"))])
        let (_, model) = await make(fake)
        await fake.holdNextCall()
        let task = Task { await model.search("x") }
        while await fake.calls.isEmpty { await Task.yield() }
        task.cancel()
        await fake.release()
        await task.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.results, [])
    }
}
