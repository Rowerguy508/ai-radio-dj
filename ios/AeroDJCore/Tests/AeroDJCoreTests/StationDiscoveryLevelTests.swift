import XCTest
@testable import AeroDJCore

// Discovery levels (-Atlas): presets over the existing `discovery` and `reach` fields, read back
// from them, and the deterministic queue mix each level gives.

private func seed(_ kind: StationSeedKind, _ id: String, _ source: StationSeedSource = .catalog) -> StationSeed {
    StationSeed(kind: kind, catalogID: id, name: "Name \(id)", source: source)
}

private func song(_ id: String, artist: String, familiar: Bool) -> StationCandidate {
    StationCandidate(track: TrackInfo(id: id, title: "Song \(id)", artistName: artist), artistID: artist, isFamiliar: familiar)
}

/// Seed tier: 4 familiar + 4 new. Related: 4 familiar + 4 new. Broad: 4 familiar + 4 new.
/// Every song by its own artist, so artist spacing never reorders the mix.
private func pool() -> StationCandidatePool {
    func tier(_ prefix: String) -> [StationCandidate] {
        (0..<8).map { song("\(prefix)\($0)", artist: "\(prefix)-a\($0)", familiar: $0 < 4) }
    }
    return StationCandidatePool(byTier: [.seed: tier("s"), .related: tier("r"), .broad: tier("b")])
}

final class StationDiscoveryLevelTests: XCTestCase {
    func testLevelsWriteTheExistingFields() {
        XCTAssertEqual(StationDiscoveryLevel.allCases, [.familiar, .balanced, .adventurous])
        XCTAssertEqual(StationDiscoveryLevel.familiar.reach, .only)
        XCTAssertEqual(StationDiscoveryLevel.balanced.reach, .related)
        XCTAssertEqual(StationDiscoveryLevel.adventurous.reach, .broad)
        XCTAssertEqual(StationDiscoveryLevel.familiar.discovery, 0.1)
        XCTAssertEqual(StationDiscoveryLevel.balanced.discovery, 0.3)
        XCTAssertEqual(StationDiscoveryLevel.adventurous.discovery, 0.7)
        for level in StationDiscoveryLevel.allCases {
            XCTAssertFalse(level.title.isEmpty)
            XCTAssertFalse(level.summary.isEmpty)
            let config = level.applied(to: StationConfiguration(seeds: [seed(.artist, "1")]))
            XCTAssertEqual(config.discovery, level.discovery)
            XCTAssertEqual(config.reach, level.reach)
            XCTAssertEqual(StationDiscoveryLevel.matching(config), level)
            XCTAssertEqual(StationDiscoveryLevel.closest(to: config), level)
        }
    }

    func testDefaultStationReadsAsBalanced() {
        XCTAssertEqual(StationDiscoveryLevel.default, .balanced)
        XCTAssertEqual(StationDiscoveryLevel.matching(.default), .balanced)
        XCTAssertEqual(StationDiscoveryLevel.balanced.applied(to: .default), .default,
                       "balanced is exactly today's defaults, so nothing about an untouched station changes")
    }

    func testAppliedKeepsEveryOtherField() {
        var base = StationConfiguration.sampleMorningMix
        base.seeds = [seed(.artist, "1")]
        let applied = StationDiscoveryLevel.adventurous.applied(to: base)
        XCTAssertEqual(applied.genres, base.genres)
        XCTAssertEqual(applied.moods, base.moods)
        XCTAssertEqual(applied.energy, base.energy)
        XCTAssertEqual(applied.personality, base.personality)
        XCTAssertEqual(applied.commentary, base.commentary)
        XCTAssertEqual(applied.briefing, base.briefing)
        XCTAssertEqual(applied.requestedIntegrations, base.requestedIntegrations)
        XCTAssertEqual(applied.seeds, base.seeds)
    }

    func testLibrarySeedsKeepOnlyAtEveryLevelAndStillMatch() {
        let library = StationConfiguration(seeds: [seed(.playlist, "p.1", .library)])
        for level in StationDiscoveryLevel.allCases {
            let config = level.applied(to: library)
            XCTAssertEqual(config.reach, .only, "library picks never expand")
            XCTAssertEqual(config.discovery, level.discovery)
            XCTAssertEqual(StationDiscoveryLevel.matching(config), level, "a library station matches on discovery alone")
        }
    }

    func testHandTunedStationsAreCustomButHaveAClosestLevel() {
        let custom = StationConfiguration(discovery: 0.55, seeds: [seed(.artist, "1")], reach: .related)
        XCTAssertNil(StationDiscoveryLevel.matching(custom))
        XCTAssertEqual(StationDiscoveryLevel.closest(to: custom), .balanced, "reach decides first")
        let broadFamiliar = StationConfiguration(discovery: 0.0, seeds: [seed(.artist, "1")], reach: .broad)
        XCTAssertEqual(StationDiscoveryLevel.closest(to: broadFamiliar), .adventurous)
        let onlyNew = StationConfiguration(discovery: 1.0, seeds: [seed(.artist, "1")], reach: .only)
        XCTAssertEqual(StationDiscoveryLevel.closest(to: onlyNew), .familiar)
        let libraryMid = StationConfiguration(discovery: 0.2, seeds: [seed(.artist, "l", .library)])
        XCTAssertEqual(StationDiscoveryLevel.closest(to: libraryMid), .familiar, "an exact tie picks the more familiar level")
        let libraryHigh = StationConfiguration(discovery: 0.9, seeds: [seed(.artist, "l", .library)])
        XCTAssertEqual(StationDiscoveryLevel.closest(to: libraryHigh), .adventurous)
    }

    // MARK: Backward compatibility (no new persisted fields)

    func testConfigurationsSavedBeforeLevelsDecodeUnchangedAndReadAsALevel() throws {
        // Before seeds (#157): tags and tuning only.
        let preSeeds = #"{"genres":["jazz"],"moods":[],"energy":0.4,"discovery":0.3,"personality":"warm","commentary":"occasional","briefing":{"enabled":true,"window":{"startMinute":420,"durationMinutes":120},"targetSeconds":300,"sections":["calendar"]},"requestedIntegrations":["calendar"]}"#
        let a = try JSONDecoder().decode(StationConfiguration.self, from: Data(preSeeds.utf8))
        XCTAssertEqual(a.genres, ["jazz"])
        XCTAssertEqual(a.energy, 0.4)
        XCTAssertEqual(a.requestedIntegrations, [.calendar])
        XCTAssertEqual(a.seeds, [])
        XCTAssertEqual(a.reach, .related)
        XCTAssertEqual(StationDiscoveryLevel.matching(a), .balanced)

        // With seeds and reach, hand-tuned discovery: decodes losslessly, reads as custom.
        let seeded = #"{"discovery":0.65,"seeds":[{"kind":"artist","catalogID":"159260351","name":"A","source":"catalog"},{"kind":"genre","catalogID":"21","name":"Rock","source":"catalog"}],"reach":"broad"}"#
        let b = try JSONDecoder().decode(StationConfiguration.self, from: Data(seeded.utf8))
        XCTAssertEqual(b.discovery, 0.65)
        XCTAssertEqual(b.reach, .broad)
        XCTAssertEqual(b.seeds.map(\.catalogID), ["159260351", "21"])
        XCTAssertNil(StationDiscoveryLevel.matching(b))
        XCTAssertEqual(StationDiscoveryLevel.closest(to: b), .adventurous)
        XCTAssertEqual(try JSONDecoder().decode(StationConfiguration.self, from: JSONEncoder().encode(b)), b)
    }

    func testALevelAddsNoKeysToTheSavedConfiguration() throws {
        func keys(_ config: StationConfiguration) throws -> Set<String> {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
            return Set(try XCTUnwrap(object).keys)
        }
        let before = try keys(.default)
        for level in StationDiscoveryLevel.allCases {
            XCTAssertEqual(try keys(level.applied(to: .default)), before)
        }
        XCTAssertEqual(before, ["genres", "moods", "energy", "discovery", "personality", "commentary", "briefing",
                                "requestedIntegrations", "seeds", "reach"])
    }

    // MARK: Queue mix (deterministic)

    func testFamiliarPlaysOnlyTheSeedsHitsFirst() {
        let list = StationPoolBuilder.build(pool(), configuration: StationDiscoveryLevel.familiar.applied(to: .default))
        // 0.1 new: every hit before the first new song in an 8-song pool.
        XCTAssertEqual(list.map(\.id), ["s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7"])
        XCTAssertTrue(list.allSatisfy { $0.tier == .seed })
        XCTAssertEqual(Array(list.prefix(4)).filter(\.isFamiliar).count, 4)
    }

    func testBalancedAddsSimilarArtistsButNotTheWiderGenre() {
        let list = StationPoolBuilder.build(pool(), configuration: StationDiscoveryLevel.balanced.applied(to: .default))
        XCTAssertEqual(Set(list.map(\.tier)), [.seed, .related])
        XCTAssertEqual(list.count, 16)
        let first10 = list.prefix(10)
        XCTAssertEqual(first10.filter { $0.tier == .seed }.count, 6, "seed 60%, related 40%")
        XCTAssertEqual(first10.filter(\.isFamiliar).count, 7, "about 3 in 10 new")
    }

    func testAdventurousReachesTheWiderGenreAndLeansNew() {
        let list = StationPoolBuilder.build(pool(), configuration: StationDiscoveryLevel.adventurous.applied(to: .default))
        XCTAssertEqual(Set(list.map(\.tier)), [.seed, .related, .broad])
        XCTAssertEqual(list.count, 24)
        let first10 = list.prefix(10)
        XCTAssertEqual(first10.filter { $0.tier == .seed }.count, 4, "seed 40%, related 30%, broad 30%")
        XCTAssertEqual(first10.filter { $0.tier == .broad }.count, 3)
        XCTAssertGreaterThan(first10.filter { !$0.isFamiliar }.count, first10.filter(\.isFamiliar).count)
    }

    func testEachLevelIsMoreAdventurousThanTheLast() {
        func newShare(_ level: StationDiscoveryLevel) -> Int {
            StationPoolBuilder.build(pool(), configuration: level.applied(to: .default), options: .init(limit: 6))
                .filter { !$0.isFamiliar || $0.tier != .seed }.count
        }
        XCTAssertLessThan(newShare(.familiar), newShare(.balanced))
        XCTAssertLessThan(newShare(.balanced), newShare(.adventurous))
    }

    func testSameLevelAndShuffleSeedGiveTheSameQueue() {
        for level in StationDiscoveryLevel.allCases {
            let config = level.applied(to: .default)
            let options = StationPoolBuilder.Options(shuffleSeed: 42)
            let a = StationPoolBuilder.build(pool(), configuration: config, options: options)
            let b = StationPoolBuilder.build(pool(), configuration: config, options: options)
            XCTAssertEqual(a, b)
            XCTAssertEqual(a, StationPoolBuilder.build(pool(), reach: config.reach, discovery: config.discovery, options: options),
                           "the configuration overload is the existing builder")
        }
    }

    func testLibraryStationAtAdventurousStillPlaysOnlyItsOwnSongs() {
        let config = StationDiscoveryLevel.adventurous.applied(to: StationConfiguration(seeds: [seed(.playlist, "p.1", .library)]))
        let list = StationPoolBuilder.build(pool(), configuration: config)
        XCTAssertTrue(list.allSatisfy { $0.tier == .seed })
        XCTAssertEqual(list.first?.isFamiliar, false, "0.7 new: a library playlist leans to its deeper tracks")
    }
}
