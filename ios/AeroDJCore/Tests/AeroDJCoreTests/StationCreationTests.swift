import XCTest
@testable import AeroDJCore

// Station creation (-Atlas): artists / genre / playlist + discovery level -> a validated
// StationConfiguration, saved as an ordinary recipe through `studio.saveRecipe(named:from:applying:)`.

private func seed(_ kind: StationSeedKind, _ id: String, _ name: String? = nil,
                  _ source: StationSeedSource = .catalog) -> StationSeed {
    StationSeed(kind: kind, catalogID: id, name: name ?? "Name \(id)", source: source)
}

@MainActor
func makeCreationStudio(active: StationConfiguration = .default,
                        recipes: StationRecipeLibrarySnapshot? = nil,
                        seedSearch: (any StationSeedSearching)? = nil) async -> StudioPresentationModel {
    let station = StationConfigurationModel(
        store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: active))),
        consent: StaticIntegrationConsent([:]))
    await station.load()
    let library = StationRecipeLibrary(store: InMemoryStationRecipeStore(snapshot: recipes))
    await library.load()
    let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(), providers: [],
                                       purger: NoopNarrationPurger())
    return StudioPresentationModel(station: station, recipes: library, connections: connections,
                                   dj: DJPresentationStore(), seedSearch: seedSearch)
}

final class StationCreationRequestTests: XCTestCase {
    func testArtistsValidateDedupeAndCap() {
        let two = StationCreationRequest(source: .artists([seed(.artist, "1"), seed(.artist, " 1 "), seed(.artist, "2")]))
        XCTAssertEqual(try two.validatedSeeds().get().map(\.catalogID), ["1", "2"], "trimmed, de-duplicated, order kept")

        let max = (1...StationCreationRequest.maxArtists).map { seed(.artist, "\($0)") }
        XCTAssertEqual(try StationCreationRequest(source: .artists(max)).validatedSeeds().get().count, StationCreationRequest.maxArtists)
        let tooMany = max + [seed(.artist, "99")]
        XCTAssertEqual(StationCreationRequest(source: .artists(tooMany)).validatedSeeds(), .failure(.tooManySeeds),
                       "never cut a pick silently")
        XCTAssertLessThanOrEqual(StationCreationRequest.maxArtists, StationConfiguration.Limits.maxSeeds)
    }

    func testEmptyBlankAndWrongKindFail() {
        XCTAssertEqual(StationCreationRequest(source: .artists([])).validatedSeeds(), .failure(.noSeeds))
        XCTAssertEqual(StationCreationRequest(source: .artists([seed(.artist, "  ")])).validatedSeeds(), .failure(.noSeeds))
        XCTAssertEqual(StationCreationRequest(source: .playlist(seed(.playlist, "p", "   "))).validatedSeeds(), .failure(.noSeeds))
        XCTAssertEqual(StationCreationRequest(source: .artists([seed(.artist, "1"), seed(.song, "2")])).validatedSeeds(),
                       .failure(.wrongSeedKind))
        XCTAssertEqual(StationCreationRequest(source: .genre(seed(.artist, "21"))).validatedSeeds(), .failure(.wrongSeedKind))
        XCTAssertEqual(StationCreationRequest(source: .playlist(seed(.genre, "21"))).validatedSeeds(), .failure(.wrongSeedKind))
    }

    func testGenreMustBeANumericCatalogID() {
        XCTAssertEqual(try StationCreationRequest(source: .genre(seed(.genre, "21"))).validatedSeeds().get().first?.catalogID, "21")
        XCTAssertEqual(try StationCreationRequest(source: .genre(seed(.genre, " 21 "))).validatedSeeds().get().first?.catalogID, "21",
                       "trimmed before the check, as validated() does")
        for bad in ["21/../me", "-1", "2 1", "?x=1", "١٢", "abc"] {
            XCTAssertEqual(StationCreationRequest(source: .genre(seed(.genre, bad))).validatedSeeds(), .failure(.invalidGenreID), bad)
        }
        XCTAssertEqual(StationCreationRequest(source: .genre(seed(.genre, "21", nil, .library))).validatedSeeds(), .failure(.libraryGenre))
    }

    func testPlaylistsFromCatalogOrLibrary() throws {
        let catalog = StationCreationRequest(source: .playlist(seed(.playlist, "pl.abc")), level: .adventurous)
        XCTAssertEqual(try catalog.configuration().get().reach, .broad)
        XCTAssertNil(catalog.reachRestriction)

        let library = StationCreationRequest(source: .playlist(seed(.playlist, "p.private", "Mine", .library)), level: .adventurous)
        let config = try library.configuration().get()
        XCTAssertEqual(config.reach, .only, "a library playlist plays only itself")
        XCTAssertEqual(config.discovery, 0.7)
        XCTAssertEqual(config.seeds.first?.source, .library)
        XCTAssertEqual(library.reachRestriction, .librarySeeds)
    }

    func testConfigurationKeepsBaseTuningAndDropsConnections() throws {
        var base = StationConfiguration.sampleMorningMix
        base.requestedIntegrations = [.calendar]
        base.seeds = [seed(.song, "old")]
        let config = try StationCreationRequest(source: .artists([seed(.artist, "1")]), level: .familiar)
            .configuration(base: base).get()
        XCTAssertEqual(config.seeds.map(\.catalogID), ["1"], "seeds replaced")
        XCTAssertEqual(config.reach, .only)
        XCTAssertEqual(config.discovery, 0.1)
        XCTAssertEqual(config.requestedIntegrations, [])
        XCTAssertEqual(config.personality, base.personality)
        XCTAssertEqual(config.commentary, base.commentary)
        XCTAssertEqual(config.energy, base.energy)
        XCTAssertEqual(config.briefing, base.briefing)
        XCTAssertEqual(StationDiscoveryLevel.matching(config), .familiar)
    }

    func testSuggestedNames() {
        XCTAssertEqual(StationCreationRequest(source: .artists([seed(.artist, "1", "Ylvöra")])).suggestedName, "Ylvöra Radio")
        XCTAssertEqual(StationCreationRequest(source: .artists([seed(.artist, "1", "A"), seed(.artist, "2", "B")])).suggestedName,
                       "A & B Radio")
        XCTAssertEqual(StationCreationRequest(source: .artists([seed(.artist, "1", "A"), seed(.artist, "2", "B"),
                                                                seed(.artist, "3", "C")])).suggestedName, "A & Friends Radio")
        XCTAssertEqual(StationCreationRequest(source: .genre(seed(.genre, "21", "Rock"))).suggestedName, "Rock Radio")
        XCTAssertEqual(StationCreationRequest(source: .playlist(seed(.playlist, "p", "Kettle Hours"))).suggestedName, "Kettle Hours")
        XCTAssertNil(StationCreationRequest(source: .artists([])).suggestedName)
        let long = String(repeating: "x", count: 80)
        let fitted = StationCreationRequest(source: .artists([seed(.artist, "1", long)])).suggestedName
        XCTAssertEqual(fitted?.count, StationRecipe.maxNameLength)
        XCTAssertEqual(fitted?.hasSuffix(" Radio"), true)
    }

    func testErrorsCarryNoSeedData() {
        for error in StationCreationError.allCases {
            XCTAssertFalse(error.userMessage.isEmpty)
            XCTAssertEqual(StationRecipeError.invalidStation(error).userMessage, error.userMessage)
        }
        XCTAssertEqual(StationCreationKind.allCases.map(\.seedKind), [.artist, .genre, .playlist])
        XCTAssertEqual(StationCreationKind.genre.maxSeeds, 1)
        XCTAssertEqual(StationCreationKind.playlist.maxSeeds, 1)
    }
}

@MainActor
final class StudioSaveRecipeFromRequestTests: XCTestCase {
    func testSavesARecipeWithoutTouchingTheLiveStation() async throws {
        let studio = await makeCreationStudio(active: .sampleMorningMix)
        let before = studio.station.active
        let request = StationCreationRequest(source: .genre(seed(.genre, "21", "Rock")), level: .adventurous)
        let recipe = try await studio.saveRecipe(named: "Rock Radio", from: request).get()
        XCTAssertEqual(recipe.name, "Rock Radio")
        XCTAssertEqual(recipe.configuration.seeds.map(\.catalogID), ["21"])
        XCTAssertEqual(recipe.configuration.reach, .broad)
        XCTAssertEqual(recipe.configuration.discovery, 0.7)
        XCTAssertEqual(recipe.configuration.personality, StationConfiguration.sampleMorningMix.personality)
        XCTAssertEqual(studio.recipes.recipes.map(\.id), [recipe.id])
        XCTAssertEqual(studio.station.active, before)
        XCTAssertFalse(studio.station.hasPendingChanges)
    }

    func testApplyingMakesItTheStation() async throws {
        let studio = await makeCreationStudio()
        let request = StationCreationRequest(source: .artists([seed(.artist, "1"), seed(.artist, "2")]), level: .familiar)
        _ = try await studio.saveRecipe(named: "Two", from: request, applying: true).get()
        // Playback is idle in tests, so it applies now (the normal recipe boundary rules).
        XCTAssertEqual(studio.station.active.seeds.map(\.catalogID), ["1", "2"])
        XCTAssertEqual(StationDiscoveryLevel.matching(studio.station.active), .familiar)
    }

    // Fry #218: every recipe apply through the studio (created-station tap, Tune, create-and-apply)
    // records which recipe the live station has, so a created-station re-tap can't trust a stale id.
    func testLastAppliedRecipeIDFollowsEveryApply() async throws {
        let studio = await makeCreationStudio()
        XCTAssertNil(studio.lastAppliedRecipeID)
        let a = try await studio.saveRecipe(named: "A", from: StationCreationRequest(source: .artists([seed(.artist, "1")])), applying: true).get()
        XCTAssertEqual(studio.lastAppliedRecipeID, a.id, "create-and-apply")
        let b = try await studio.saveRecipe(named: "B", from: StationCreationRequest(source: .artists([seed(.artist, "2")]))).get()
        XCTAssertEqual(studio.lastAppliedRecipeID, a.id, "saving without applying changes nothing")
        _ = await studio.applyRecipe(b.id)                    // Tune > Recipes
        XCTAssertEqual(studio.lastAppliedRecipeID, b.id)
        _ = await studio.applyRecipe(UUID())                  // a failed apply: unknown state
        XCTAssertNil(studio.lastAppliedRecipeID)
    }

    func testInvalidRequestSavesNothing() async {
        let studio = await makeCreationStudio()
        let result = await studio.saveRecipe(named: "Bad", from: StationCreationRequest(source: .genre(seed(.genre, "../x"))))
        XCTAssertEqual(result, .failure(.invalidStation(.invalidGenreID)))
        XCTAssertEqual(studio.recipes.recipes, [])
    }

    func testSameNameRulesAsTheTuneFormSave() async throws {
        let studio = await makeCreationStudio()
        _ = try await studio.saveRecipe(named: "Mine").get()
        let request = StationCreationRequest(source: .artists([seed(.artist, "1")]))
        let duplicate = await studio.saveRecipe(named: "mine", from: request)
        XCTAssertEqual(duplicate, .failure(.duplicateName))
        let blank = await studio.saveRecipe(named: "  ", from: request)
        XCTAssertEqual(blank, .failure(.emptyName))
    }

    func testOldRecipeFilesStillLoadNextToCreatedStations() async throws {
        // A v1 recipe file saved before seeds existed.
        let old = #"{"version":1,"recipes":[{"id":"6F1C2D3E-0000-4000-8000-000000000001","name":"Morning","createdAt":"2026-01-01T07:00:00Z","configuration":{"genres":["jazz"],"energy":0.4,"discovery":0.3,"personality":"warm","commentary":"occasional"}}]}"#
        let snapshot = try StationRecipeLibrarySnapshot.decode(Data(old.utf8))
        let studio = await makeCreationStudio(recipes: snapshot)
        let loaded = try XCTUnwrap(studio.recipes.recipes.first)
        XCTAssertEqual(loaded.configuration.genres, ["jazz"])
        XCTAssertEqual(loaded.configuration.seeds, [])
        XCTAssertEqual(StationDiscoveryLevel.matching(loaded.configuration), .balanced)

        _ = try await studio.saveRecipe(named: "Rock", from: StationCreationRequest(source: .genre(seed(.genre, "21")))).get()
        let reread = try StationRecipeLibrarySnapshot.decode(StationRecipeLibrarySnapshot(recipes: studio.recipes.recipes).encoded())
        XCTAssertEqual(reread.recipes.map(\.name), ["Morning", "Rock"])
        XCTAssertEqual(reread.recipes.first { $0.name == "Morning" }, loaded, "the old recipe round-trips unchanged")
    }
}

// Walkthrough talk and DJ steps (-Atlas, for Nova): optional, nil keeps the on-screen tuning.
// No class-level @MainActor: Linux XCTest discovery (Swift 6.2) aborts casting a @MainActor sync test.
// Sync tests run on the main thread and assume isolation; async tests are @MainActor per test. -Atlas
final class StationCreationTuningStepTests: XCTestCase {
    private let rock = StationCreationSource.genre(StationSeed(kind: .genre, catalogID: "21", name: "Rock"))

    func testNilKeepsTheBaseTalkAndPersonality() throws {
        let rock = rock
        try MainActor.assumeIsolated {
            var base = StationConfiguration.default
            base.commentary = .rare
            base.personality = .laidBack
            let config = try StationCreationRequest(source: rock).configuration(base: base).get()
            XCTAssertEqual(config.commentary, .rare)
            XCTAssertEqual(config.personality, .laidBack)
            XCTAssertNil(StationCreationRequest(source: rock).commentary)
            XCTAssertNil(StationCreationRequest(source: rock).personality)
        }
    }

    func testSetValuesReplaceOnlyTheirOwnField() throws {
        let rock = rock
        try MainActor.assumeIsolated {
            var base = StationConfiguration.default
            base.commentary = .rare
            base.personality = .laidBack
            base.energy = 0.9
            let talkOnly = try StationCreationRequest(source: rock, commentary: .chatty).configuration(base: base).get()
            XCTAssertEqual(talkOnly.commentary, .chatty)
            XCTAssertEqual(talkOnly.personality, .laidBack)
            let both = try StationCreationRequest(source: rock, level: .familiar, commentary: .off, personality: .minimal)
                .configuration(base: base).get()
            XCTAssertEqual(both.commentary, .off)
            XCTAssertEqual(both.personality, .minimal)
            XCTAssertEqual(both.energy, 0.9, "other tuning is kept")
            XCTAssertEqual(both.reach, .only)
            XCTAssertEqual(both, both.validated(), "validated with the existing rules")
        }
    }

    func testInvalidPicksStillFailWhateverTheTuning() {
        MainActor.assumeIsolated {
            let request = StationCreationRequest(source: .artists([]), commentary: .chatty, personality: .upbeat)
            XCTAssertEqual(request.configuration(), .failure(.noSeeds))
        }
    }

    @MainActor func testSavedRecipeCarriesTheStepsWithTheSameKeys() async throws {
        let studio = await makeCreationStudio(active: .sampleMorningMix)
        let request = StationCreationRequest(source: rock, commentary: .frequent, personality: .upbeat)
        let recipe = try await studio.saveRecipe(named: "Rock Radio", from: request).get()
        XCTAssertEqual(recipe.configuration.commentary, .frequent)
        XCTAssertEqual(recipe.configuration.personality, .upbeat)
        let plain = try await studio.saveRecipe(named: "Rock Two", from: StationCreationRequest(source: rock)).get()
        XCTAssertEqual(plain.configuration.commentary, StationConfiguration.sampleMorningMix.commentary)
        let keys = { (c: StationConfiguration) throws -> Set<String> in
            let data = try JSONEncoder().encode(c)
            return Set((try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).keys)
        }
        XCTAssertEqual(try keys(recipe.configuration), try keys(plain.configuration), "no new saved keys")
    }

    @MainActor func testModelPassesTheStepsThrough() async throws {
        let studio = await makeCreationStudio(seedSearch: NoSeedResults())
        let model = try XCTUnwrap(studio.makeStationCreation(kind: .genre))
        XCTAssertNil(model.commentary)
        XCTAssertNil(model.personality)
        model.toggle(StationSeed(kind: .genre, catalogID: "21", name: "Rock"))
        XCTAssertEqual(model.request?.commentary, nil)
        model.commentary = .rare
        model.personality = .minimal
        XCTAssertEqual(model.request?.commentary, .rare)
        XCTAssertEqual(model.request?.personality, .minimal)
        let recipe = try await model.save().get()
        XCTAssertEqual(studio.station.active.commentary, recipe.configuration.commentary)
        XCTAssertEqual(recipe.configuration.personality, .minimal)
    }
}

private struct NoSeedResults: StationSeedSearching {
    func searchSeeds(_ term: String, kinds: Set<StationSeedKind>, limit: Int) async throws -> [StationSeedSearchResult] { [] }
    func genreSeeds(matching query: String) async throws -> [StationSeedSearchResult] { [] }
    func libraryPlaylistSeeds(limit: Int) async throws -> [StationSeedSearchResult] { [] }
}
