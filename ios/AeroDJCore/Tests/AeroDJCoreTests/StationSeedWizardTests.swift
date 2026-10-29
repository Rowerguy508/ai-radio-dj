import XCTest
@testable import AeroDJCore

// Station wizard helpers (-Atlas, Nova's and Fry's #157 review): the reach a seed set allows,
// the clamp everywhere, search results, and the blank-term and cancellation rules.

private func catalogArtist(_ id: String) -> StationSeed {
    StationSeed(kind: .artist, catalogID: id, name: "Artist \(id)", source: .catalog)
}

private func libraryArtist(_ id: String) -> StationSeed {
    StationSeed(kind: .artist, catalogID: id, name: "Private \(id)", source: .library)
}

private func candidate(_ id: String) -> StationCandidate {
    StationCandidate(track: TrackInfo(id: id, title: "Song \(id)", artistName: "x"), artistID: "a-x")
}

final class StationReachAllowedTests: XCTestCase {
    func testEmptyAndCatalogSeedSetsAllowEveryReach() {
        let all = Set(StationReach.allCases)
        XCTAssertEqual(StationReach.allowed(for: []), all)
        XCTAssertEqual(StationReach.allowed(for: [catalogArtist("1"), catalogArtist("2")]), all)
        XCTAssertNil(StationReach.restriction(for: []))
        XCTAssertNil(StationReach.restriction(for: [catalogArtist("1")]))
        XCTAssertEqual(StationReach.broad.effective(for: [catalogArtist("1")]), .broad)
    }

    func testAnyLibrarySeedAllowsOnlyOnlyWithAReason() {
        let libraryOnly = [libraryArtist("l1")]
        let mixed = [catalogArtist("1"), libraryArtist("l1")]
        for seeds in [libraryOnly, mixed] {
            XCTAssertEqual(StationReach.allowed(for: seeds), [.only])
            XCTAssertEqual(StationReach.restriction(for: seeds), .librarySeeds)
            for reach in StationReach.allCases { XCTAssertEqual(reach.effective(for: seeds), .only) }
        }
        XCTAssertFalse(StationReachRestriction.librarySeeds.message.isEmpty)
        XCTAssertFalse(StationReachRestriction.librarySeeds.message.contains("Private"))
    }

    func testInvalidLibrarySeedsAreIgnoredLikeValidatedDropsThem() {
        let blank = StationSeed(kind: .artist, catalogID: " ", name: "Gone", source: .library)
        XCTAssertEqual(StationReach.allowed(for: [catalogArtist("1"), blank]), Set(StationReach.allCases))
        XCTAssertNil(StationReach.restriction(for: [blank]))
    }

    func testValidatedClampsLibraryStationsToOnlyAndKeepsCatalogReach() throws {
        XCTAssertEqual(StationConfiguration(seeds: [catalogArtist("1")], reach: .broad).reach, .broad)
        XCTAssertEqual(StationConfiguration(seeds: [], reach: .broad).reach, .broad)
        let library = StationConfiguration(seeds: [catalogArtist("1"), libraryArtist("l1")], reach: .broad)
        XCTAssertEqual(library.reach, .only)
        XCTAssertEqual(library.validated(), library, "still idempotent")

        let json = #"{"seeds":[{"kind":"playlist","catalogID":"p.1","name":"Mine","source":"library"}],"reach":"broad"}"#
        let decoded = try JSONDecoder().decode(StationConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.reach, .only, "a file saved as Broad with a library seed still loads as Only")
        let again = try JSONDecoder().decode(StationConfiguration.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
        XCTAssertEqual(again.seeds.first?.source, .library)
    }

    @MainActor
    func testTheTunerCannotPutALibraryStationOnRelated() async {
        let model = StationConfigurationModel(store: InMemoryStationConfigurationStore(), consent: StaticIntegrationConsent([:]),
                                              initial: .init(active: StationConfiguration(seeds: [libraryArtist("l1")])))
        await model.setReach(.broad)
        XCTAssertEqual(model.displayed.reach, .only)
    }

    func testResolverUsesTheSameRuleForAMixedSet() async {
        let catalog = FakeCatalog(core: ["1": [candidate("a")], "l1": [candidate("b")]],
                                  related: ["1": [candidate("c")]], broad: ["1": [candidate("d")]])
        let pool = await CatalogStationSeedResolver(catalog: catalog)
            .resolve(seeds: [catalogArtist("1"), libraryArtist("l1")], reach: .broad)
        let calls = await catalog.calls
        XCTAssertEqual(calls, ["core:1", "core:l1"], "any library seed keeps the whole station on Only")
        XCTAssertEqual(pool.libraryReachLimited, 1)
        XCTAssertEqual(pool.songs(.seed).map(\.id), ["a", "b"])

        let open = await CatalogStationSeedResolver(catalog: FakeCatalog())
            .resolve(seeds: [catalogArtist("1")], reach: .broad)
        XCTAssertEqual(open.libraryReachLimited, 0)
    }
}

final class StarterSuggestionReachTests: XCTestCase {
    private struct Source: StarterStationSource {
        var top: [StationSeed]
        var recommended: [StationSeed]
        func libraryTopArtists(limit: Int) async throws -> [StationSeed] { top }
        func recentlyPlayed(limit: Int) async throws -> [StationSeed] { [] }
        func recommendations(limit: Int) async throws -> [StationSeed] { recommended }
    }

    /// Fry (#157): a library-seeded suggestion is never saved as Related or Broad.
    @MainActor
    func testLibrarySeededSuggestionsAreNeverSavedAsRelatedOrBroad() async throws {
        let source = Source(top: [libraryArtist("l1"), libraryArtist("l2")], recommended: [catalogArtist("9")])
        let suggestions = await StarterStationSuggester(source: source).suggestions()
        XCTAssertEqual(suggestions.map(\.origin), [.libraryMix, .libraryArtist, .libraryArtist, .recommended])

        let store = InMemoryStationRecipeStore()
        let lib = StationRecipeLibrary(store: store)
        await lib.load()
        for s in suggestions {
            let config = s.draft.configuration
            let saved = try await lib.save(name: s.draft.name, configuration: config).get()
            if config.seeds.contains(where: { $0.source == .library }) {
                XCTAssertEqual(config.reach, .only, s.draft.name)
                XCTAssertEqual(saved.configuration.reach, .only, s.draft.name)
            }
        }
        XCTAssertEqual(lib.recipes.first { $0.name == "Artist 9 Radio" }?.configuration.reach, .broad,
                       "catalog recommendations keep Broad")

        let reloaded = StationRecipeLibrary(store: store)
        await reloaded.load()
        XCTAssertEqual(reloaded.recipes.count, 4)
        for r in reloaded.recipes where r.configuration.seeds.contains(where: { $0.source == .library }) {
            XCTAssertEqual(r.configuration.reach, .only)
        }
    }
}

final class StationSeedSearchTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func add(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return log }
    }

    func testBlankTermsReturnEmptyWithoutCallingTheSearch() async throws {
        let calls = Calls()
        for term in ["", " ", "\n\t  ", "\u{00A0}\u{2003}"] {
            let results = try await StationSeedSearch.run(term: term, limit: 10) { q, _ -> [String] in
                calls.add(q); return ["x"]
            }
            XCTAssertEqual(results, [])
            XCTAssertNil(StationSeedSearch.normalizedTerm(term))
        }
        XCTAssertEqual(calls.all, [], "a blank term never reaches the network")
    }

    func testTermIsTrimmedCollapsedAndCappedAndLimitClamped() async throws {
        XCTAssertEqual(StationSeedSearch.normalizedTerm("  daft \n  punk\t"), "daft punk")
        let long = String(repeating: "a", count: 150)
        XCTAssertEqual(StationSeedSearch.normalizedTerm(long)?.count, StationSeedSearch.maxTermLength)
        XCTAssertEqual(StationSeedSearch.normalizedLimit(0), 1)
        XCTAssertEqual(StationSeedSearch.normalizedLimit(99), StationSeedSearch.maxLimit)
        XCTAssertEqual(StationSeedSearch.normalizedLimit(10), 10)

        let calls = Calls()
        let results = try await StationSeedSearch.run(term: " robyn  ", limit: 500) { q, limit -> [String] in
            calls.add("\(q)|\(limit)"); return ["r1", "r2"]
        }
        XCTAssertEqual(results, ["r1", "r2"])
        XCTAssertEqual(calls.all, ["robyn|25"])
    }

    func testCancelledBeforeTheRequestThrowsWithoutCallingTheSearch() async {
        let calls = Calls()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StationSeedSearch.run(term: "robyn", limit: 10) { q, _ -> [String] in
                calls.add(q); return ["r1"]
            }
        }
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls.all, [])
    }

    func testCancelledDuringTheRequestThrowsAndDropsPartialResults() async {
        let calls = Calls()
        let task = Task {
            try await StationSeedSearch.run(term: "robyn", limit: 10) { q, _ -> [String] in
                calls.add(q)
                withUnsafeCurrentTask { $0?.cancel() }   // the user typed again mid-request
                return ["partial"]
            }
        }
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls.all, ["robyn"])
    }

    func testACancelledRequestThatFailsDifferentlyStillThrowsCancellationError() async {
        struct URLCancelled: Error {}
        let task = Task {
            try await StationSeedSearch.run(term: "robyn", limit: 10) { _, _ -> [String] in
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLCancelled()
            }
        }
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testSearchErrorsPropagateUnchanged() async {
        struct Offline: Error {}
        do {
            _ = try await StationSeedSearch.run(term: "robyn", limit: 10) { _, _ -> [String] in throw Offline() }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is Offline)
        }
    }

    func testSearchResultIsKeyedBySeedAndRedacted() {
        let seed = StationSeed(kind: .song, catalogID: "s.SECRET", name: "Private Song", source: .catalog)
        let r = StationSeedSearchResult(seed: seed, subtitle: "Secret Artist",
                                        artworkURL: URL(string: "https://example.invalid/SECRETART.jpg"))
        XCTAssertEqual(r.id, seed.key)
        XCTAssertEqual(r, StationSeedSearchResult(seed: seed, subtitle: "Secret Artist",
                                                  artworkURL: URL(string: "https://example.invalid/SECRETART.jpg")))
        XCTAssertNotEqual(r, StationSeedSearchResult(seed: seed))
        var dumped = ""
        dump(r, to: &dumped)
        for text in ["\(r)", String(reflecting: r), dumped] {
            for leak in ["SECRET", "Private", "Secret Artist", "SECRETART"] {
                XCTAssertFalse(text.contains(leak), "\(leak) leaked in \(text)")
            }
        }
        XCTAssertEqual("\(r)", "StationSeedSearchResult(song, catalog, subtitle=true, artwork=true)")
    }
}
