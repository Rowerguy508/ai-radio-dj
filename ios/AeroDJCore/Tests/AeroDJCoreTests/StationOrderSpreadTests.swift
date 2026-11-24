import XCTest
@testable import AeroDJCore

// #418 (-Atlas): what was still predictable after #423 (fresh seed + weave jitter) and #476 (varied
// fast-start opener). A list shorter than its share filled the opening of every start: Morning
// Calm's 8 seed songs (seed tier 0.6 of `.related`) were all in the first 13 songs of every start,
// and an artist station's 5 familiar top songs were all in its first 8. The shuffle only changed
// their order inside that window. Now (`Options.spreadShortLists`, on for every fresh-per-build seed
// source) a short list is spread over the queue. These tests measure it over many starts, and check
// that spacing, exclusions, dedupe and per-tier song counts still hold.

private func cand(_ id: String, _ artist: String, _ tier: StationCandidateTier, _ familiar: Bool) -> StationCandidate {
    StationCandidate(track: TrackInfo(id: id, title: "Song \(id)", artistName: artist), artistID: "a-" + artist,
                     tier: tier, isFamiliar: familiar)
}

/// Shaped like Morning Calm through `CatalogStationSeedResolver`: 8 song seeds, so the seed tier is
/// those 8 songs; related is 8 lists of 40 (4 songs per artist) round-robin, the first 5 of each familiar.
private func morningCalmLikePool() -> StationCandidatePool {
    let seedTier = (0..<8).map { cand("seed\($0)", "SA\($0)", .seed, true) }
    let perSeed = (0..<8).map { s in (0..<40).map { i in cand("r\(s)-\(i)", "RA\(s)-\(i / 4)", .related, i < 5) } }
    var related: [StationCandidate] = []
    for i in 0..<40 { for s in 0..<8 { related.append(perSeed[s][i]) } }
    return StationCandidatePool(byTier: [.seed: seedTier, .related: related])
}

/// One artist seed, `.only`: its 25 top songs, the first 5 familiar.
private func artistPool() -> StationCandidatePool {
    StationCandidatePool(byTier: [.seed: (0..<25).map { cand("t\($0)", "ART", .seed, $0 < 5) }])
}

private let starts: [UInt64] = {
    var stream = SplitMix64(seed: 0x418)
    return (0..<200).map { _ in stream.next() }
}()

private func build(_ pool: StationCandidatePool, _ seed: UInt64, spread: Bool, reach: StationReach = .related,
                   discovery: Double = 0.25, gap: Int = 2, limit: Int = 50, excluded: Set<String> = [],
                   ratings: StationRatingBias = .none) -> [StationCandidate] {
    StationPoolBuilder.build(pool, reach: reach, discovery: discovery,
                             options: .init(limit: limit, artistGap: gap, excludedSongIDs: excluded, shuffleSeed: seed,
                                            ratings: ratings, spreadShortLists: spread))
}

private let seedSongs = (0..<8).map { "seed\($0)" }
private let familiarTop = (0..<5).map { "t\($0)" }

/// Mean share of the first `k` songs that the previous start also had in its first `k`.
private func meanRepeatShare(_ orders: [[String]], k: Int) -> Double {
    var total = 0.0
    for i in orders.indices.dropFirst() {
        total += Double(Set(orders[i].prefix(k)).intersection(orders[i - 1].prefix(k)).count) / Double(k)
    }
    return total / Double(orders.count - 1)
}

/// Songs that are in the first `k` of every start.
private func inEveryOpening(_ orders: [[String]], k: Int) -> Set<String> {
    orders.dropFirst().reduce(Set(orders[0].prefix(k))) { $0.intersection($1.prefix(k)) }
}

private func positions(of ids: [String], in orders: [[String]]) -> [Int] {
    orders.flatMap { o in ids.compactMap { o.firstIndex(of: $0) } }
}

private func mean(_ values: [Int]) -> Double { Double(values.reduce(0, +)) / Double(max(values.count, 1)) }

private func assertSpacing(_ artists: [String], gap: Int, _ note: String, file: StaticString = #filePath, line: UInt = #line) {
    for i in artists.indices.dropFirst() {
        XCTAssertFalse(artists[max(0, i - gap)..<i].contains(artists[i]), "artistGap \(gap) broken at \(i), \(note)",
                       file: file, line: line)
    }
}

final class StationOrderSpreadBuilderTests: XCTestCase {
    /// Morning Calm's shape. Before: all 8 seed songs inside the first 13 songs of nearly every
    /// start (measured 187 of 200), so every start sounded the same. Now: never, and the openings
    /// of consecutive starts share far fewer songs.
    func testASmallSeedTierNoLongerFillsEveryOpening() {
        let before = starts.map { build(morningCalmLikePool(), $0, spread: false).map(\.id) }
        let after = starts.map { build(morningCalmLikePool(), $0, spread: true).map(\.id) }
        func allSeedsEarly(_ orders: [[String]]) -> Int {
            orders.filter { o in seedSongs.allSatisfy { (o.firstIndex(of: $0) ?? .max) < 13 } }.count
        }
        XCTAssertGreaterThanOrEqual(allSeedsEarly(before), 150, "the predictable baseline this fixes")
        XCTAssertLessThanOrEqual(allSeedsEarly(after), 2)
        let repeatBefore = meanRepeatShare(before, k: 10), repeatAfter = meanRepeatShare(after, k: 10)
        XCTAssertLessThanOrEqual(repeatAfter, 0.25, "share of the first 10 the previous start also opened with")
        XCTAssertLessThan(repeatAfter, repeatBefore / 2)
        XCTAssertTrue(inEveryOpening(after, k: 10).isEmpty)
    }

    /// Positions are spread: a seed song lands across the queue, not only in its first 13 songs.
    func testASeedSongsPositionIsSpreadAcrossTheQueue() {
        let after = starts.map { build(morningCalmLikePool(), $0, spread: true).map(\.id) }
        let all = positions(of: seedSongs, in: after)
        XCTAssertGreaterThanOrEqual(mean(all), 15)
        XCTAssertGreaterThanOrEqual(all.max() ?? 0, 30)
        let seed0 = positions(of: ["seed0"], in: after)
        XCTAssertEqual(seed0.count, starts.count)
        for bucket in 0..<4 {
            let inBucket = seed0.filter { $0 / 10 == bucket }.count
            XCTAssertGreaterThanOrEqual(inBucket, starts.count / 10, "positions \(bucket * 10)–\(bucket * 10 + 9)")
        }
    }

    /// Spreading only moves songs: every start still has the same number of songs from each tier
    /// (all 8 seed songs), the same length, and the same songs as without spreading.
    func testSpreadingKeepsEveryTiersSongCount() {
        for seed in starts {
            let before = build(morningCalmLikePool(), seed, spread: false)
            let after = build(morningCalmLikePool(), seed, spread: true)
            XCTAssertEqual(after.count, 50, "seed \(seed)")
            XCTAssertEqual(after.filter { $0.tier == .seed }.count, before.filter { $0.tier == .seed }.count, "seed \(seed)")
            XCTAssertTrue(Set(seedSongs).isSubset(of: after.map(\.id)), "seed \(seed)")
        }
    }

    /// An artist station (`.only`, 25 top songs, 5 familiar): the 5 familiar songs were in the first
    /// 8 of every start. Now no song is in the first 10 of every start, and the familiar ones spread.
    func testAnArtistStationsFamiliarSongsSpread() {
        let before = starts.map { build(artistPool(), $0, spread: false, reach: .only, discovery: 0.3, gap: 0).map(\.id) }
        let after = starts.map { build(artistPool(), $0, spread: true, reach: .only, discovery: 0.3, gap: 0).map(\.id) }
        XCTAssertEqual(inEveryOpening(before, k: 10), Set(familiarTop), "the predictable baseline")
        XCTAssertTrue(inEveryOpening(after, k: 10).isEmpty)
        XCTAssertLessThan(meanRepeatShare(after, k: 10), meanRepeatShare(before, k: 10))
        XCTAssertGreaterThanOrEqual(mean(positions(of: familiarTop, in: after)), 8)
        for o in after { XCTAssertTrue(Set(familiarTop).isSubset(of: o)) }
    }

    /// Discovery 0 still means familiar only until the familiar songs run out (weight 0 waits).
    func testDiscoveryZeroStillPlaysFamiliarFirst() {
        for seed in starts {
            let o = build(artistPool(), seed, spread: true, reach: .only, discovery: 0, gap: 0).map(\.id)
            XCTAssertEqual(Set(o.prefix(5)), Set(familiarTop), "seed \(seed)")
        }
    }

    /// artistGap, exclusions (played, never/tired, dropped artist) and dedupe hold for every start.
    func testInvariantsHoldWithSpreading() {
        var pool = morningCalmLikePool()
        pool.byTier[.related]!.append(cand("seed3", "SA3", .related, true))   // cross-tier duplicate ID
        pool.byTier[.related]!.append(StationCandidate(track: TrackInfo(id: "dup-title", title: "Song seed4", artistName: "SA4"),
                                                       artistID: "a-SA4", tier: .related))
        let ratings = StationRatingBias(excludedSongIDs: ["seed5", "r2-3"], droppedArtists: ["ra1-0"])
        let excluded: Set<String> = ["seed6", "r0-0"]
        for seed in starts {
            let list = build(pool, seed, spread: true, excluded: excluded, ratings: ratings)
            let ids = list.map(\.id)
            XCTAssertEqual(list.count, 50, "seed \(seed)")
            XCTAssertTrue(Set(ids).isDisjoint(with: excluded.union(ratings.excludedSongIDs)), "seed \(seed)")
            XCTAssertFalse(list.contains { $0.track.artistName == "RA1-0" }, "dropped artist, seed \(seed)")
            XCTAssertEqual(Set(ids).count, ids.count, "dedupe by ID, seed \(seed)")
            XCTAssertEqual(Set(list.map(\.titleKey)).count, list.count, "dedupe by title, seed \(seed)")
            XCTAssertEqual(list.first { $0.id == "seed3" }?.tier, .seed, "closest tier kept, seed \(seed)")
            assertSpacing(list.map(\.artistKey), gap: 2, "seed \(seed)")
        }
    }

    func testPacedShares() {
        func close(_ a: [Double], _ b: [Double], _ note: String) {
            XCTAssertEqual(a.count, b.count)
            for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-9, note) }
        }
        // Morning Calm: 8 seed songs over 40 slots get one slot in 5; related takes the rest.
        close(StationPoolBuilder.pacedShares(counts: [8, 320], weights: [0.6, 0.4], slots: 40), [0.2, 0.8], "short seed tier")
        // Nothing short: the weights, normalized.
        close(StationPoolBuilder.pacedShares(counts: [100, 100], weights: [0.6, 0.4], slots: 40), [0.6, 0.4], "nothing short")
        // Water-filling: capping the first makes the second short too; the third takes the rest.
        close(StationPoolBuilder.pacedShares(counts: [4, 10, 100], weights: [0.4, 0.3, 0.3], slots: 40),
              [0.1, 0.25, 0.65], "two short")
        // Every list short: by count. A zero-weight list stays zero.
        close(StationPoolBuilder.pacedShares(counts: [2, 6], weights: [0.5, 0.5], slots: 40), [0.05, 0.15], "all short")
        close(StationPoolBuilder.pacedShares(counts: [5, 20], weights: [1, 0], slots: 25), [0.2, 0], "zero weight")
    }

    /// Only a source with a fresh seed per build spreads; `.perDay` and `.fixed` keep their orders.
    func testOnlyFreshPerBuildSourcesSpread() {
        XCTAssertTrue(StationShuffleSeedSource.systemRandom.isFreshPerBuild)
        XCTAssertTrue(StationShuffleSeedSource.stream(1).isFreshPerBuild)
        XCTAssertFalse(StationShuffleSeedSource.perDay.isFreshPerBuild)
        XCTAssertFalse(StationShuffleSeedSource.fixed(1).isFreshPerBuild)
        XCTAssertFalse(StationPoolBuilder.Options().spreadShortLists, "the builder default is the old weave")
    }
}

// MARK: - Through the feed

private func songSeed(_ n: Int) -> StationSeed { StationSeed(kind: .song, catalogID: "seed\(n)", name: "Seed \(n)", source: .catalog) }

private func morningCalmLike() -> StationConfiguration {
    var c = StationConfiguration.default
    c.seeds = (0..<8).map(songSeed)
    c.reach = .related
    c.discovery = 0.25
    return c.validated()
}

/// Through `CatalogStationSeedResolver`: a song seed's core songs are the song; related is 40 songs.
private struct SongSeedCatalog: StationSeedCatalog {
    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
        let n = seed.catalogID.dropFirst(4)
        return [cand(seed.catalogID, "SA\(n)", .seed, true)]
    }
    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
        let n = seed.catalogID.dropFirst(4)
        return (0..<min(limit, 40)).map { i in cand("r\(n)-\(i)", "RA\(n)-\(i / 4)", .related, true) }
    }
    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { [] }
}

@MainActor
final class StationOrderSpreadFeedTests: XCTestCase {
    private var artists: [String: String] = [:]

    private func feed(_ source: StationShuffleSeedSource) -> StationQueueFeed<String> {
        StationQueueFeed<String>(resolver: CatalogStationSeedResolver(catalog: SongSeedCatalog()),
                                 materialize: { $0.map(\.id) }, options: .init(limit: 50, seedSource: source), day: { 42 })
    }

    /// One station start: build, then take the staged queue as Play with nothing queued does.
    private func start(_ f: StationQueueFeed<String>) async throws -> [String] {
        let outcome = await f.prepare(morningCalmLike())
        guard case .ready = outcome else { XCTFail("\(outcome)"); return [] }
        return try XCTUnwrap(f.takeForIdleStart(active: morningCalmLike()))
    }

    private func artist(_ id: String) -> String {
        id.hasPrefix("seed") ? "sa\(id.dropFirst(4))" : "ra" + id.dropFirst().prefix { $0 != "-" } + "-\((Int(id.split(separator: "-")[1]) ?? 0) / 4)"
    }

    /// The injected stream replays a run of starts exactly, and every start in it is a new order.
    func testAnInjectedStreamReplaysAndEveryStartDiffers() async throws {
        let a = feed(.stream(0x418)), b = feed(.stream(0x418))
        var runA: [[String]] = [], runB: [[String]] = []
        for _ in 0..<30 {
            runA.append(try await start(a))
            runB.append(try await start(b))
        }
        XCTAssertEqual(runA, runB, "same stream, same starts")
        XCTAssertEqual(Set(runA).count, 30, "every start a new order")
        XCTAssertGreaterThanOrEqual(Set(runA.map { Array($0.prefix(5)) }).count, 29, "the first 5 songs differ")
        let other = feed(.stream(0x419))
        let otherFirst = try await start(other)
        XCTAssertNotEqual(otherFirst, runA[0], "another stream, another run")
    }

    /// The same station started again and again: the seed songs no longer all open every start,
    /// positions spread, and artist spacing holds in every queue handed out.
    func testRepeatedStartsOfOneStationAreSpreadAndSpaced() async throws {
        let f = feed(.stream(0xA71A5))
        var orders: [[String]] = []
        for _ in 0..<60 { orders.append(try await start(f)) }
        let allSeedsEarly = orders.filter { o in seedSongs.allSatisfy { (o.firstIndex(of: $0) ?? .max) < 13 } }.count
        XCTAssertLessThanOrEqual(allSeedsEarly, 1)
        XCTAssertGreaterThanOrEqual(mean(positions(of: seedSongs, in: orders)), 15)
        XCTAssertLessThanOrEqual(meanRepeatShare(orders, k: 10), 0.25)
        for (n, o) in orders.enumerated() {
            XCTAssertEqual(o.count, 50)
            XCTAssertTrue(Set(seedSongs).isSubset(of: o), "start \(n)")
            assertSpacing(o.map(artist), gap: 2, "start \(n)")
        }
    }

    /// The app default's spread path, pinned to the same SplitMix64 replay the other
    /// spread tests in this file use (`.stream(0x418)`). Same bounds as before: at most
    /// one of 40 starts has every seed song in the first 13, and the mean seed position
    /// is at least 12. The unseeded `.systemRandom` version of this could flake in CI.
    func testTheAppDefaultSpreads() async throws {
        let f = feed(.stream(0x418))
        var orders: [[String]] = []
        for _ in 0..<40 { orders.append(try await start(f)) }
        let allSeedsEarly = orders.filter { o in seedSongs.allSatisfy { (o.firstIndex(of: $0) ?? .max) < 13 } }.count
        XCTAssertLessThanOrEqual(allSeedsEarly, 1)
        XCTAssertGreaterThanOrEqual(mean(positions(of: seedSongs, in: orders)), 12)
    }

    /// Smoke check that the live `.systemRandom` default is still a fresh-per-build
    /// source and actually varies. This does not re-assert the spread bounds: those
    /// are statistical on an unseeded RNG and could flake. 40 identical orders would
    /// mean the default is stuck, not a flaky shuffle.
    func testTheAppDefaultSystemRandomVaries() async throws {
        XCTAssertTrue(StationShuffleSeedSource.systemRandom.isFreshPerBuild)
        let f = feed(.systemRandom)
        var orders: [[String]] = []
        for _ in 0..<40 { orders.append(try await start(f)) }
        XCTAssertGreaterThan(Set(orders).count, 1, "40 starts under .systemRandom must not all be the same order")
    }

    /// `.perDay` (the tests' predictable order) is unchanged: it does not spread.
    func testPerDayKeepsItsOrder() async throws {
        let first = try await start(feed(.perDay))
        let second = try await start(feed(.perDay))
        XCTAssertEqual(first, second)
        XCTAssertTrue(seedSongs.allSatisfy { (first.firstIndex(of: $0) ?? .max) < 14 }, "the old front-loaded weave")
    }
}
