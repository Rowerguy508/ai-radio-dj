import XCTest
@testable import AeroDJCore

// Station seeds and reach (-Atlas). Fry's conditions (a)-(d) each have a test here, marked.

private func artist(_ id: String, _ name: String = "", source: StationSeedSource = .catalog) -> StationSeed {
    StationSeed(kind: .artist, catalogID: id, name: name.isEmpty ? "Artist \(id)" : name, source: source)
}

private func song(_ id: String, by artist: String, familiar: Bool = true) -> StationCandidate {
    StationCandidate(track: TrackInfo(id: id, title: "Song \(id)", artistName: artist), artistID: "a-" + artist,
                     isFamiliar: familiar)
}

// MARK: - Model

final class StationSeedModelTests: XCTestCase {
    /// Fry (a): cap 8, dedupe kind+catalogID keeping the first (order kept), trim and cap names at 64,
    /// drop empty IDs or names.
    func testValidatedCapsDedupesTrimsAndDropsEmptySeeds() {
        let long = String(repeating: "n", count: 100)
        let seeds: [StationSeed] = [
            artist("1", "  First  "),
            StationSeed(kind: .artist, catalogID: " 1 ", name: "Duplicate of 1"),
            StationSeed(kind: .genre, catalogID: "1", name: "Same ID, other kind"),
            StationSeed(kind: .song, catalogID: "", name: "No ID"),
            StationSeed(kind: .song, catalogID: "s", name: "   "),
            StationSeed(kind: .playlist, catalogID: "p", name: long),
        ] + (2...20).map { artist("\($0)") }
        let c = StationConfiguration(seeds: seeds)
        XCTAssertEqual(c.seeds.count, StationConfiguration.Limits.maxSeeds)
        XCTAssertEqual(c.seeds[0], artist("1", "First"))
        XCTAssertEqual(c.seeds[1].kind, .genre, "same catalogID with another kind is a different seed")
        XCTAssertEqual(c.seeds[2].kind, .playlist)
        XCTAssertEqual(c.seeds[2].name.count, 64)
        XCTAssertEqual(c.seeds.dropFirst(3).map(\.catalogID), ["2", "3", "4", "5", "6"], "order kept")
        XCTAssertEqual(Set(c.seeds.map(\.key)).count, c.seeds.count)
        XCTAssertEqual(c.validated(), c, "idempotent")
    }

    func testDefaultsAreNoSeedsAndRelated() {
        XCTAssertEqual(StationConfiguration.default.seeds, [])
        XCTAssertEqual(StationConfiguration.default.reach, .related)
        XCTAssertEqual(StationReach.default, .related)
    }

    /// Fry (b): JSON saved before seeds existed loads as seeds [] and reach .related, other fields intact.
    func testOldConfigurationAndSnapshotJSONDecodeWithoutSeeds() throws {
        let old = #"{"genres":["jazz"],"moods":[],"energy":0.7,"discovery":0.4,"personality":"upbeat","commentary":"rare","requestedIntegrations":["calendar"]}"#
        let c = try JSONDecoder().decode(StationConfiguration.self, from: Data(old.utf8))
        XCTAssertEqual(c.seeds, [])
        XCTAssertEqual(c.reach, .related)
        XCTAssertEqual(c.genres, ["jazz"])
        XCTAssertEqual(c.energy, 0.7)
        XCTAssertEqual(c.personality, .upbeat)

        let snapshot = #"{"version":1,"active":\#(old)}"#
        let s = try StationConfigurationSnapshot.decode(Data(snapshot.utf8))
        XCTAssertEqual(s.state.active.seeds, [])
        XCTAssertEqual(s.state.active.reach, .related)
    }

    /// Fry (b), recipes: a recipe library saved before seeds existed loads with seeds [] and .related.
    func testOldRecipeJSONDecodesWithoutSeeds() throws {
        let json = #"{"version":1,"recipes":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","configuration":{"energy":0.2}}]}"#
        let lib = try JSONDecoder().decode(StationRecipeLibrarySnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(lib.recipes.first?.configuration.seeds, [])
        XCTAssertEqual(lib.recipes.first?.configuration.reach, .related)
        XCTAssertEqual(lib.recipes.first?.configuration.energy, 0.2)
    }

    func testUnknownSeedKindDropsOnlyThatSeedAndUnknownReachFallsBack() throws {
        let json = #"{"seeds":[{"kind":"podcast","catalogID":"x","name":"X","source":"catalog"},{"kind":"genre","catalogID":"21","name":"Rock","source":"catalog"},{"kind":"song","catalogID":"9","name":"No source"}],"reach":"galaxy"}"#
        let c = try JSONDecoder().decode(StationConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(c.seeds.map(\.catalogID), ["21", "9"])
        XCTAssertEqual(c.seeds[1].source, .library, "a missing source is treated as private library data")
        XCTAssertEqual(c.reach, .only, "an unknown reach falls back to .related, then a library seed clamps it to .only")
    }

    func testSeedsAndReachRoundTripThroughConfigurationSnapshotAndRecipe() throws {
        let config = StationConfiguration(requestedIntegrations: [.calendar],
                                          seeds: [artist("1"), StationSeed(kind: .playlist, catalogID: "p.1", name: "Mine", source: .catalog)],
                                          reach: .broad)
        let decoded = try JSONDecoder().decode(StationConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
        let snap = try StationConfigurationSnapshot.decode(StationConfigurationSnapshot(state: .init(active: config)).encoded())
        XCTAssertEqual(snap.state.active, config)

        let recipe = StationRecipe(name: "R", configuration: config)
        XCTAssertEqual(recipe.configuration.seeds, config.seeds)
        XCTAssertEqual(recipe.configuration.reach, .broad)
        XCTAssertEqual(recipe.configuration.requestedIntegrations, [], "recipes still never carry connections")
        let again = try JSONDecoder().decode(StationRecipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(again, recipe)
    }

    @MainActor
    func testRecipeLibrarySaveAndReloadKeepsSeedsAndReach() async throws {
        let store = InMemoryStationRecipeStore()
        let lib = StationRecipeLibrary(store: store)
        await lib.load()
        let config = StationConfiguration(seeds: [artist("1"), artist("2")], reach: .only)
        _ = try await lib.save(name: "Two artists", configuration: config).get()
        let reloaded = StationRecipeLibrary(store: store)
        await reloaded.load()
        XCTAssertEqual(reloaded.recipes.first?.configuration.seeds, config.seeds)
        XCTAssertEqual(reloaded.recipes.first?.configuration.reach, .only)
    }
}

// MARK: - Settings and boundaries

final class StationSeedSettingTests: XCTestCase {
    /// Fry (c): own cases, in `all` and `tuning`, applied at the next song boundary.
    func testSeedsAndReachAreOwnSettingsAppliedAtSongBoundary() {
        XCTAssertTrue(StationSetting.all.contains(.seeds) && StationSetting.all.contains(.reach))
        XCTAssertTrue(StationSetting.tuning.contains(.seeds) && StationSetting.tuning.contains(.reach))
        XCTAssertEqual(Set(StationSetting.all).count, StationSetting.all.count)

        var s = StationConfigurationState(active: .sampleMorningMix)
        s.edit { $0.seeds = [artist("1")]; $0.reach = .broad }
        XCTAssertEqual(s.pendingSettings, [.seeds: .nextSongBoundary, .reach: .nextSongBoundary])
        XCTAssertNil(s.apply(.djBreakWillPrepare(afterTrack: 0)), "mid-song events never apply seeds or reach")
        XCTAssertNil(s.apply(.briefingWillPlan))
        XCTAssertEqual(s.active.seeds, [])
        let change = s.apply(.songBoundary(afterTrack: 0))
        XCTAssertEqual(change?.applied, [.seeds, .reach])
        XCTAssertEqual(s.active.seeds, [artist("1")])
        XCTAssertEqual(s.active.reach, .broad)
        XCTAssertNil(s.pending)
        XCTAssertFalse(change?.invalidatesPreparedBreaks ?? true, "seeds are not a privacy reduction")
    }

    func testSeedsEditDiffersAndCopiesOnlyItself() {
        let a = StationConfiguration.sampleMorningMix
        var b = a
        b.seeds = [artist("1")]
        XCTAssertTrue(StationSetting.seeds.differs(a, b))
        XCTAssertFalse(StationSetting.reach.differs(a, b))
        var target = a
        StationSetting.seeds.copy(from: b, into: &target)
        XCTAssertEqual(target, b)
    }

    @MainActor
    func testModelSetSeedsAndReachWaitForTheBoundaryWhileASongHolds() async {
        let model = StationConfigurationModel(store: InMemoryStationConfigurationStore(), consent: StaticIntegrationConsent([:]))
        await model.load()
        await model.setPlaybackActivity(.holdingSong)
        await model.setSeeds([artist("1", "Robyn")])
        await model.setReach(.only)
        await model.saveChanges()
        XCTAssertEqual(model.active.seeds, [])
        XCTAssertEqual(model.displayed.seeds.map(\.name), ["Robyn"])
        XCTAssertEqual(model.tunerRow(for: .seeds).appliesCopy, "Applies after this song")
        XCTAssertEqual(model.tunerRow(for: .reach).displayedSummary, "Only this")
        await model.handle(.songBoundary(afterTrack: 0))
        XCTAssertEqual(model.active.seeds.map(\.name), ["Robyn"])
        XCTAssertEqual(model.active.reach, .only)
    }

    @MainActor
    func testModelSeedsSaveAppliesNowWhenIdle() async {
        let model = StationConfigurationModel(store: InMemoryStationConfigurationStore(), consent: StaticIntegrationConsent([:]))
        await model.load()
        await model.setSeeds([StationSeed(kind: .genre, catalogID: "21", name: "Rock")])
        await model.saveChanges()
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["21"])
    }

    func testTunerCopyForSeedsAndReachIsHonest() {
        XCTAssertEqual(StationSetting.seeds.title, "Built from")
        XCTAssertEqual(StationSetting.reach.title, "Reach")
        XCTAssertEqual(StationConfiguration().summary(of: .seeds), "Any")
        let c = StationConfiguration(seeds: (1...5).map { artist("\($0)", "A\($0)") }, reach: .broad)
        XCTAssertEqual(c.summary(of: .seeds), "A1, A2, A3 +2")
        XCTAssertEqual(c.summary(of: .reach), "Broad")
        XCTAssertEqual(StationReach.allCases.map(\.title), ["Only this", "Related", "Broad"])
        // Nothing plays from seeds until the queue hook lands, so the indicator says Saved, not Active.
        XCTAssertFalse(StationSetting.seeds.isReadToday)
        XCTAssertFalse(StationSetting.reach.isReadToday)
        XCTAssertEqual(TunerIndicator(status: .idle, setting: .seeds), .saved)
        XCTAssertTrue(StationSetting.reach.usageCopy.contains("Not used for song picking yet"))
    }
}

// MARK: - Privacy (Fry (d))

final class StationSeedPrivacyTests: XCTestCase {
    private let secret = StationSeed(kind: .playlist, catalogID: "p.SECRETLIBID", name: "Private Breakup Mix", source: .library)

    func testSeedDescriptionAndDumpNeverCarryNameOrID() {
        var dumped = ""
        dump(secret, to: &dumped)
        for text in ["\(secret)", String(reflecting: secret), dumped, "\([secret])"] {
            XCTAssertFalse(text.contains("SECRETLIBID"), text)
            XCTAssertFalse(text.contains("Breakup"), text)
        }
        XCTAssertEqual("\(secret)", "StationSeed(playlist, library)")
    }

    func testDiagnosticsCarryOnlyEnumsBoolsAndCounts() {
        let config = StationConfiguration(seeds: [secret, artist("123", "Robyn")], reach: .broad)
        let d = StationSeedDiagnostics(config)
        XCTAssertEqual(d.seedCount, 2)
        XCTAssertEqual(d.librarySeedCount, 1)
        XCTAssertTrue(d.hasLibrarySeeds)
        XCTAssertEqual(d.countsByKind, [.playlist: 1, .artist: 1])
        XCTAssertEqual(d.description, "seeds=2 library=1 reach=only artist=1 genre=0 playlist=1 song=0")
        for leak in ["SECRETLIBID", "Breakup", "123", "Robyn"] { XCTAssertFalse(d.description.contains(leak)) }
    }

    func testResolverNeverExpandsALibrarySeedThroughTheCatalog() async {
        let catalog = FakeCatalog(core: ["p.SECRETLIBID": [song("1", by: "x")]])
        let pool = await CatalogStationSeedResolver(catalog: catalog).resolve(seeds: [secret], reach: .broad)
        let calls = await catalog.calls
        XCTAssertEqual(calls, ["core:p.SECRETLIBID"], "related and broad never see a library seed")
        XCTAssertEqual(pool.libraryReachLimited, 1)
        XCTAssertEqual(pool.songs(.seed).map(\.id), ["1"])
        XCTAssertFalse(pool.diagnostics.contains("SECRETLIBID"))
        XCTAssertEqual(pool.diagnostics, "seed=1 related=0 broad=0 failed=0 libraryLimited=1")
    }
}

// MARK: - Resolver

actor FakeCatalog: StationSeedCatalog {
    struct Failure: Error {}
    private(set) var calls: [String] = []
    let core: [String: [StationCandidate]]
    let related: [String: [StationCandidate]]
    let broad: [String: [StationCandidate]]
    let failing: Set<String>

    init(core: [String: [StationCandidate]] = [:], related: [String: [StationCandidate]] = [:],
         broad: [String: [StationCandidate]] = [:], failing: Set<String> = []) {
        self.core = core; self.related = related; self.broad = broad; self.failing = failing
    }

    private func answer(_ tier: String, _ seed: StationSeed, _ table: [String: [StationCandidate]], _ limit: Int) throws -> [StationCandidate] {
        calls.append("\(tier):\(seed.catalogID)")
        if failing.contains("\(tier):\(seed.catalogID)") { throw Failure() }
        return Array((table[seed.catalogID] ?? []).prefix(limit))
    }

    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { try answer("core", seed, core, limit) }
    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { try answer("related", seed, related, limit) }
    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { try answer("broad", seed, broad, limit) }
}

final class StationSeedResolverTests: XCTestCase {
    private let catalog = FakeCatalog(
        core: ["A": [song("a1", by: "A"), song("a2", by: "A")], "B": [song("b1", by: "B")]],
        related: ["A": [song("r1", by: "R")], "B": [song("r2", by: "S")]],
        broad: ["A": [song("g1", by: "G")]])

    func testOnlyAsksForCoreSongsOnly() async {
        let pool = await CatalogStationSeedResolver(catalog: catalog).resolve(seeds: [artist("A")], reach: .only)
        let calls = await catalog.calls
        XCTAssertEqual(calls, ["core:A"])
        XCTAssertEqual(pool.songs(.seed).map(\.id), ["a1", "a2"])
        XCTAssertTrue(pool.songs(.related).isEmpty)
    }

    func testRelatedAddsSimilarArtistsAndBroadAddsTheNeighbourhood() async {
        let related = await CatalogStationSeedResolver(catalog: catalog).resolve(seeds: [artist("A")], reach: .related)
        XCTAssertEqual(related.songs(.related).map(\.id), ["r1"])
        XCTAssertEqual(related.songs(.related).first?.tier, .related)
        XCTAssertTrue(related.songs(.broad).isEmpty)

        let fresh = FakeCatalog(core: ["A": [song("a1", by: "A")]], related: ["A": [song("r1", by: "R")]], broad: ["A": [song("g1", by: "G")]])
        let broad = await CatalogStationSeedResolver(catalog: fresh).resolve(seeds: [artist("A")], reach: .broad)
        let calls = await fresh.calls
        XCTAssertEqual(calls, ["core:A", "related:A", "broad:A"])
        XCTAssertEqual(broad.songs(.broad).map(\.id), ["g1"])
    }

    func testSeveralSeedsInterleaveAndAFailingSeedIsSkipped() async {
        let c = FakeCatalog(core: ["A": [song("a1", by: "A"), song("a2", by: "A")], "B": [song("b1", by: "B"), song("b2", by: "B")]],
                            failing: ["core:C"])
        let pool = await CatalogStationSeedResolver(catalog: c).resolve(seeds: [artist("A"), artist("C"), artist("B")], reach: .only)
        XCTAssertEqual(pool.songs(.seed).map(\.id), ["a1", "b1", "a2", "b2"])
        XCTAssertEqual(pool.failedLookups, 1)
    }

    func testFamiliarityIsTheHeadOfEachListAndSeedsAreValidatedFirst() async {
        let c = FakeCatalog(core: ["A": (1...4).map { song("a\($0)", by: "A", familiar: false) }])
        let resolver = CatalogStationSeedResolver(catalog: c, limits: .init(familiarHead: 2))
        let pool = await resolver.resolve(seeds: [artist("A"), artist(" A "), StationSeed(kind: .song, catalogID: "", name: "x")], reach: .only)
        XCTAssertEqual(pool.songs(.seed).map(\.isFamiliar), [true, true, false, false])
        let calls = await c.calls
        XCTAssertEqual(calls, ["core:A"], "duplicate and empty seeds are dropped before any lookup")
    }
}

// MARK: - Pool builder

final class StationPoolBuilderTests: XCTestCase {
    private func ids(_ list: [StationCandidate]) -> [String] { list.map(\.id) }

    func testOnlyReachUsesTheSeedTierOnly() {
        let pool = StationCandidatePool(byTier: [.seed: [song("a", by: "A")], .related: [song("r", by: "R")], .broad: [song("g", by: "G")]])
        XCTAssertEqual(ids(StationPoolBuilder.build(pool, reach: .only, discovery: 0.5)), ["a"])
        XCTAssertEqual(Set(ids(StationPoolBuilder.build(pool, reach: .related, discovery: 0.5))), ["a", "r"])
        XCTAssertEqual(Set(ids(StationPoolBuilder.build(pool, reach: .broad, discovery: 0.5))), ["a", "r", "g"])
    }

    func testDedupesByIDAndTitleKeepingTheClosestTierAndHonoursExclusions() {
        let dupTitle = StationCandidate(track: TrackInfo(id: "other-id", title: "Song a", artistName: "A"))
        let pool = StationCandidatePool(byTier: [.seed: [song("a", by: "A"), song("x", by: "X")],
                                                 .related: [song("a", by: "A"), dupTitle, song("r", by: "R")]])
        let built = StationPoolBuilder.build(pool, reach: .related, discovery: 0, options: .init(excludedSongIDs: ["x"]))
        XCTAssertEqual(Set(ids(built)), ["a", "r"])
        XCTAssertEqual(built.first { $0.id == "a" }?.tier, .seed)
    }

    func testDiscoveryMixesFamiliarAndNewWithinTheReach() {
        let familiar = (1...4).map { song("f\($0)", by: "F\($0)") }
        let fresh = (1...4).map { song("n\($0)", by: "N\($0)", familiar: false) }
        let pool = StationCandidatePool(byTier: [.seed: familiar + fresh])
        let opts = StationPoolBuilder.Options(artistGap: 0)
        XCTAssertEqual(ids(StationPoolBuilder.build(pool, reach: .only, discovery: 0, options: opts)),
                       ["f1", "f2", "f3", "f4", "n1", "n2", "n3", "n4"], "0 = familiar first; new only once familiar runs out")
        XCTAssertEqual(ids(StationPoolBuilder.build(pool, reach: .only, discovery: 1, options: opts)),
                       ["n1", "n2", "n3", "n4", "f1", "f2", "f3", "f4"])
        XCTAssertEqual(ids(StationPoolBuilder.build(pool, reach: .only, discovery: 0.5, options: opts)),
                       ["f1", "n1", "f2", "n2", "f3", "n3", "f4", "n4"])
        let quarter = StationPoolBuilder.build(pool, reach: .only, discovery: 0.25, options: .init(limit: 4, artistGap: 0))
        XCTAssertEqual(quarter.filter { !$0.isFamiliar }.count, 1)
    }

    func testRelatedReachAimsForSixtyFortyAndBroadForFortyThirtyThirty() {
        let pool = StationCandidatePool(byTier: [
            .seed: (1...20).map { song("s\($0)", by: "S\($0)") },
            .related: (1...20).map { song("r\($0)", by: "R\($0)") },
            .broad: (1...20).map { song("b\($0)", by: "B\($0)") },
        ])
        let related = StationPoolBuilder.build(pool, reach: .related, discovery: 0, options: .init(limit: 10))
        XCTAssertEqual(related.filter { $0.tier == .seed }.count, 6)
        XCTAssertEqual(related.filter { $0.tier == .related }.count, 4)
        let broad = StationPoolBuilder.build(pool, reach: .broad, discovery: 0, options: .init(limit: 10))
        XCTAssertEqual(broad.filter { $0.tier == .seed }.count, 4)
        XCTAssertEqual(broad.filter { $0.tier == .related }.count, 3)
        XCTAssertEqual(broad.filter { $0.tier == .broad }.count, 3)
    }

    func testASparseTierLeavesItsShareToTheOthers() {
        let pool = StationCandidatePool(byTier: [.seed: (1...10).map { song("s\($0)", by: "S\($0)") }, .related: [song("r1", by: "R")]])
        let built = StationPoolBuilder.build(pool, reach: .related, discovery: 0, options: .init(limit: 8))
        XCTAssertEqual(built.count, 8)
        XCTAssertEqual(built.filter { $0.tier == .related }.count, 1)
    }

    func testArtistSpacingKeepsTheSameArtistApartWhenThePoolAllows() {
        let list = ["A", "A", "A", "B", "B", "C", "C", "D"].enumerated().map { song("\($0.offset)", by: $0.element) }
        let built = StationPoolBuilder.build(StationCandidatePool(byTier: [.seed: list]), reach: .only, discovery: 0,
                                             options: .init(artistGap: 2))
        let artists = built.map(\.track.artistName)
        XCTAssertEqual(artists.count, 8)
        for i in artists.indices.dropFirst(2) where i < 6 {
            XCTAssertFalse(artists[(i - 2)..<i].contains(artists[i]), "\(artists)")
        }
    }

    func testOneArtistOnlyStationRelaxesSpacingInsteadOfRunningDry() {
        let list = (1...5).map { song("a\($0)", by: "A") }
        let built = StationPoolBuilder.build(StationCandidatePool(byTier: [.seed: list]), reach: .only, discovery: 0)
        XCTAssertEqual(ids(built), ["a1", "a2", "a3", "a4", "a5"])
    }

    func testLimitAndDeterminism() {
        let pool = StationCandidatePool(byTier: [.seed: (1...30).map { song("s\($0)", by: "S\($0 % 4)", familiar: $0 < 10) },
                                                 .related: (1...30).map { song("r\($0)", by: "R\($0 % 3)", familiar: $0 < 5) }])
        XCTAssertEqual(StationPoolBuilder.build(pool, reach: .related, discovery: 0.3, options: .init(limit: 12)).count, 12)
        XCTAssertEqual(StationPoolBuilder.build(pool, reach: .related, discovery: 0.3, options: .init(limit: 0)), [])
        let a = StationPoolBuilder.build(pool, reach: .related, discovery: 0.3, options: .init(shuffleSeed: 42))
        let b = StationPoolBuilder.build(pool, reach: .related, discovery: 0.3, options: .init(shuffleSeed: 42))
        XCTAssertEqual(a, b, "same shuffle seed, same station")
        XCTAssertEqual(Set(ids(a)).count, a.count)
        XCTAssertEqual(StationPoolBuilder.build(pool, reach: .related, discovery: 0.3),
                       StationPoolBuilder.build(pool, reach: .related, discovery: 0.3))
        XCTAssertTrue(StationPoolBuilder.build(StationCandidatePool(), reach: .broad, discovery: 1).isEmpty)
    }

    func testSplitMixIsAFixedSequence() {
        var g = SplitMix64(seed: 0)
        XCTAssertEqual(g.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(g.next(), 0x6E78_9E6A_A1B9_65F4)
    }
}

// MARK: - Starter stations

private struct FakeStarterSource: StarterStationSource {
    var top: [StationSeed] = []
    var recent: [StationSeed] = []
    var recommended: [StationSeed] = []
    var failRecent = false

    func libraryTopArtists(limit: Int) async throws -> [StationSeed] { Array(top.prefix(limit)) }
    func recentlyPlayed(limit: Int) async throws -> [StationSeed] {
        if failRecent { throw FakeCatalog.Failure() }
        return Array(recent.prefix(limit))
    }
    func recommendations(limit: Int) async throws -> [StationSeed] { Array(recommended.prefix(limit)) }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> UUID {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
}

final class StarterStationSuggesterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func suggester(_ source: FakeStarterSource, max: Int = 6) -> StarterStationSuggester {
        let counter = Counter()
        let t0 = self.t0
        return StarterStationSuggester(source: source, maxSuggestions: max, makeID: { counter.next() }, now: { t0 })
    }

    func testSuggestsMixArtistsRecentsAndRecommendationsInOrder() async {
        let source = FakeStarterSource(
            top: [artist("l1", "Robyn", source: .library), artist("l2", "Lorde", source: .library)],
            recent: [StationSeed(kind: .song, catalogID: "s1", name: "Dancing On My Own"), artist("l1", "Robyn", source: .library)],
            recommended: [StationSeed(kind: .playlist, catalogID: "pl.1", name: "Indie Chill"),
                          StationSeed(kind: .genre, catalogID: "21", name: "Rock")])
        var base = StationConfiguration.sampleMorningMix
        base.requestedIntegrations = [.calendar]
        let s = await suggester(source).suggestions(base: base)
        XCTAssertEqual(s.map(\.draft.name), ["Your Mix", "Robyn Radio", "Lorde Radio", "Dancing On My Own Radio", "Indie Chill", "Rock Radio"])
        XCTAssertEqual(s.map(\.origin), [.libraryMix, .libraryArtist, .libraryArtist, .recentlyPlayed, .recommended, .recommended])
        XCTAssertEqual(s[0].draft.configuration.seeds.map(\.catalogID), ["l1", "l2"])
        XCTAssertEqual(s[0].draft.configuration.reach, .only, "library seeds play only themselves")
        XCTAssertEqual(s[4].draft.configuration.reach, .broad)
        XCTAssertEqual(s[1].draft.configuration.personality, base.personality, "keeps the listener's tuning")
        XCTAssertTrue(s.allSatisfy { $0.draft.configuration.requestedIntegrations.isEmpty }, "never carries connections")
        XCTAssertEqual(s.first?.draft.createdAt, t0)
        XCTAssertEqual(Set(s.map(\.id)).count, s.count)
    }

    func testSkipsTakenNamesCapsCountAndSurvivesAFailingSource() async {
        let source = FakeStarterSource(top: [artist("l1", "Robyn", source: .library)],
                                       recommended: (1...10).map { StationSeed(kind: .playlist, catalogID: "pl.\($0)", name: "List \($0)") },
                                       failRecent: true)
        let s = await suggester(source, max: 3).suggestions(existingNames: ["robyn radio"])
        XCTAssertEqual(s.map(\.draft.name), ["List 1", "List 2", "List 3"], "one artist is not a mix; a taken name is skipped")
    }

    func testLongNamesFitTheRecipeLimit() async {
        let name = String(repeating: "Long ", count: 20)
        let s = await suggester(FakeStarterSource(recommended: [artist("1", name)])).suggestions()
        let draft = try? XCTUnwrap(s.first?.draft)
        XCTAssertLessThanOrEqual(draft?.name.count ?? 99, StationRecipe.maxNameLength)
        XCTAssertTrue(draft?.name.hasSuffix(" Radio") ?? false)
    }

    @MainActor
    func testSuggestionsAreShownOnlyAndSaveGoesThroughTheRecipeLibrary() async throws {
        let lib = StationRecipeLibrary(store: InMemoryStationRecipeStore())
        await lib.load()
        let s = await suggester(FakeStarterSource(recommended: [artist("1", "Robyn")])).suggestions()
        XCTAssertEqual(s.count, 1)
        XCTAssertTrue(lib.recipes.isEmpty, "suggesting never saves")
        let draft = try XCTUnwrap(s.first?.draft)
        let saved = try await lib.save(name: draft.name, configuration: draft.configuration).get()
        XCTAssertEqual(saved.configuration.seeds, draft.configuration.seeds)
        XCTAssertEqual(lib.recipes.count, 1)
    }
}
