import XCTest
@testable import AeroDJCore

// P0 build 25 (-Atlas): "the whole walkthrough runs and no station is created". A saved
// station must be in the store the Stations list reads, right after Save, and after a relaunch.

private actor OneArtistSearch: StationSeedSearching {
    func searchSeeds(_ term: String, kinds: Set<StationSeedKind>, limit: Int) async throws -> [StationSeedSearchResult] {
        [.init(seed: StationSeed(kind: .artist, catalogID: "11", name: "Artist One")),
         .init(seed: StationSeed(kind: .artist, catalogID: "22", name: "Artist Two"))]
    }
    func genreSeeds(matching query: String) async throws -> [StationSeedSearchResult] {
        [.init(seed: StationSeed(kind: .genre, catalogID: "21", name: "Rock"))]
    }
    func libraryPlaylistSeeds(limit: Int) async throws -> [StationSeedSearchResult] {
        [.init(seed: StationSeed(kind: .playlist, catalogID: "p.lib", name: "Mine", source: .library))]
    }
}

@MainActor
final class CreatedStationsTests: XCTestCase {
    private func makeStudio(store: InMemoryStationRecipeStore) async -> StudioPresentationModel {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .default))),
            consent: StaticIntegrationConsent([:]))
        let library = StationRecipeLibrary(store: store)
        let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(), providers: [],
                                           purger: NoopNarrationPurger())
        let studio = StudioPresentationModel(station: station, recipes: library, connections: connections,
                                             dj: DJPresentationStore(), seedSearch: OneArtistSearch())
        await studio.start()   // the app's launch path: loads the station and the recipes
        return studio
    }

    /// The walkthrough's own sequence (kind → picks → level → name → Save, `applying: false`).
    private func runWalkthrough(_ studio: StudioPresentationModel, kind: StationCreationKind,
                                pick: (StationCreationModel) async -> Void, name: String) async throws -> StationRecipe {
        let creation = try XCTUnwrap(studio.makeStationCreation())
        creation.setKind(kind)
        await pick(creation)
        creation.level = .adventurous
        let progress = AddStationProgress(kind: kind, pickError: creation.validationError, level: creation.level,
                                          typedName: name, suggestedName: creation.suggestedName,
                                          existingNames: studio.recipes.recipes.map(\.name), isSaving: creation.isSaving)
        XCTAssertTrue(AddStationWalkthrough.canSave(on: .review, progress))
        let resolved = try AddStationWalkthrough.resolvedName(progress).get()
        return try await creation.save(named: resolved, applying: false).get()
    }

    func testEveryKindSavedByTheWalkthroughIsAStationInTheListAndSurvivesARelaunch() async throws {
        let store = InMemoryStationRecipeStore()
        let studio = await makeStudio(store: store)
        XCTAssertEqual(CreatedStations.entries(from: studio.recipes.recipes), [])

        let one = try await runWalkthrough(studio, kind: .artists, pick: { c in
            await c.search("artist"); c.toggle(c.results[0].seed)
        }, name: "")
        let several = try await runWalkthrough(studio, kind: .artists, pick: { c in
            await c.search("artist"); c.toggle(c.results[0].seed); c.toggle(c.results[1].seed)
        }, name: "Both")
        let genre = try await runWalkthrough(studio, kind: .genre, pick: { c in
            await c.search(""); c.toggle(c.results[0].seed)
        }, name: "Genre")
        let playlist = try await runWalkthrough(studio, kind: .playlist, pick: { c in
            await c.loadLibraryPlaylists(); c.toggle(c.results[0].seed)
        }, name: "Library")

        let ids = Set([one.id, several.id, genre.id, playlist.id])
        XCTAssertEqual(Set(CreatedStations.entries(from: studio.recipes.recipes).map(\.id)), ids,
                       "each save is a row in the Stations list at once")
        XCTAssertEqual(studio.station.active.seeds, [], "Save never applies or plays")

        // Relaunch: a fresh library over the same store still lists all four.
        let relaunched = await makeStudio(store: store)
        let entries = CreatedStations.entries(from: relaunched.recipes.recipes)
        XCTAssertEqual(Set(entries.map(\.id)), ids)
        XCTAssertEqual(entries.first { $0.id == several.id }?.summary, "Your station from 2 artists")
        XCTAssertFalse(entries.contains { $0.summary.contains("Artist") || $0.summary.contains("Mine") },
                       "summaries never carry a seed name")
    }

    func testTuningOnlyRecipesAreNotStationsAndADeletedStationLeavesTheList() async throws {
        let store = InMemoryStationRecipeStore()
        let studio = await makeStudio(store: store)
        _ = try await studio.saveRecipe(named: "Just tuning").get()
        XCTAssertEqual(CreatedStations.entries(from: studio.recipes.recipes), [])

        let made = try await runWalkthrough(studio, kind: .genre, pick: { c in
            await c.search(""); c.toggle(c.results[0].seed)
        }, name: "Rock Radio")
        XCTAssertEqual(CreatedStations.recipeID(for: made.id, in: studio.recipes.recipes), made.id)
        _ = try await studio.recipes.delete(made.id).get()
        XCTAssertNil(CreatedStations.recipeID(for: made.id, in: studio.recipes.recipes))
    }

    func testOpeningACreatedStationWhileIdleMakesItTheActiveStation() async throws {
        let studio = await makeStudio(store: InMemoryStationRecipeStore())
        let made = try await runWalkthrough(studio, kind: .genre, pick: { c in
            await c.search(""); c.toggle(c.results[0].seed)
        }, name: "Rock Radio")
        _ = try await studio.applyRecipe(made.id).get()   // what a row tap on it does
        XCTAssertEqual(studio.station.active.seeds.map(\.catalogID), ["21"])
    }
}
