import XCTest
@testable import AeroDJCore

// #418 (-Fry): "Songs order on stations is too predictable." A fresh shuffle seed per build (system
// randomness, injectable) and a bounded jitter in the weave. Every builder invariant (artistGap,
// exclusions, ratings, dedupe) is checked across 200 seeds; the refill keeps the up-next song first.

private let seeds: [UInt64] = (1...200).map { UInt64($0) &* 0x9E37_79B9_7F4A_7C15 }

private func cand(_ id: String, _ artist: String, _ tier: StationCandidateTier, familiar: Bool) -> StationCandidate {
    StationCandidate(track: TrackInfo(id: id, title: "Song \(id)", artistName: artist), artistID: "a-" + artist,
                     tier: tier, isFamiliar: familiar)
}

/// Three tiers of 40, two songs per artist, a third of each tier new. Plus a cross-tier ID duplicate
/// (`s0` again in related) and a title duplicate ("Song s1" by S0 in broad, another ID).
private func varietyPool() -> StationCandidatePool {
    var byTier: [StationCandidateTier: [StationCandidate]] = [:]
    for (tier, p) in [(StationCandidateTier.seed, "s"), (.related, "r"), (.broad, "b")] {
        byTier[tier] = (0..<40).map { i in cand("\(p)\(i)", "\(p.uppercased())\(i / 2)", tier, familiar: i % 3 != 0) }
    }
    byTier[.related]!.append(cand("s0", "S0", .related, familiar: true))
    byTier[.broad]!.append(StationCandidate(track: TrackInfo(id: "dup-title", title: "Song s1", artistName: "S0"),
                                            artistID: "a-S0", tier: .broad))
    return StationCandidatePool(byTier: byTier)
}

private func build(_ seed: UInt64?, gap: Int = 2, limit: Int = 60, excluded: Set<String> = [],
                   ratings: StationRatingBias = .none, reach: StationReach = .broad, discovery: Double = 0.3) -> [StationCandidate] {
    StationPoolBuilder.build(varietyPool(), reach: reach, discovery: discovery,
                             options: .init(limit: limit, artistGap: gap, excludedSongIDs: excluded, shuffleSeed: seed,
                                            ratings: ratings))
}

final class StationVarietyBuilderTests: XCTestCase {
    func testTheSameSeedGivesTheSameOrder() {
        for seed in seeds { XCTAssertEqual(build(seed).map(\.id), build(seed).map(\.id), "seed \(seed)") }
    }

    func testDifferentSeedsGiveDifferentOrders() {
        XCTAssertNotEqual(build(seeds[0]).map(\.id), build(seeds[1]).map(\.id))
        let orders = Set(seeds.map { build($0).map(\.id) })
        XCTAssertGreaterThanOrEqual(orders.count, 195, "200 seeds, essentially 200 orders")
    }

    /// artistGap, exclusions (played, never/tired, dropped artist), dedupe by ID and title, closest tier.
    func testInvariantsHoldForEverySeed() {
        let ratings = StationRatingBias(excludedSongIDs: ["b3", "s8"], droppedArtists: ["r3"])
        let excluded: Set<String> = ["s5", "r7"]
        for seed in seeds {
            let list = build(seed, gap: 2, limit: 60, excluded: excluded, ratings: ratings)
            XCTAssertEqual(list.count, 60, "seed \(seed)")
            let ids = list.map(\.id)
            XCTAssertTrue(Set(ids).isDisjoint(with: excluded.union(ratings.excludedSongIDs)), "seed \(seed)")
            XCTAssertFalse(list.contains { $0.tier != .seed && $0.track.artistName == "R3" }, "dropped artist, seed \(seed)")
            XCTAssertEqual(Set(ids).count, ids.count, "dedupe by ID, seed \(seed)")
            XCTAssertEqual(Set(list.map(\.titleKey)).count, list.count, "dedupe by title, seed \(seed)")
            XCTAssertFalse(ids.contains("dup-title"))
            if let s0 = list.first(where: { $0.id == "s0" }) { XCTAssertEqual(s0.tier, .seed, "closest tier kept") }
            let artists = list.map(\.artistKey)
            for i in artists.indices.dropFirst() {
                XCTAssertFalse(artists[max(0, i - 2)..<i].contains(artists[i]), "artistGap 2 broken at \(i), seed \(seed)")
            }
        }
    }

    /// Ratings weighting: the jitter draws the same stream whatever the content, so with a seed a
    /// loved song never plays later than it would unrated, and a tired one never earlier.
    func testRatingsStillMoveSongsTheSameWayForEverySeed() throws {
        let loved = StationRatingBias(songScores: ["s30": 1.0])
        let tired = StationRatingBias(songScores: ["s4": -1.0])
        var movedUp = 0
        for seed in seeds {
            let base = build(seed, gap: 0, limit: 200, discovery: 0).map(\.id)
            let up = build(seed, gap: 0, limit: 200, ratings: loved, discovery: 0).map(\.id)
            let down = build(seed, gap: 0, limit: 200, ratings: tired, discovery: 0).map(\.id)
            let b = try XCTUnwrap(base.firstIndex(of: "s30")), u = try XCTUnwrap(up.firstIndex(of: "s30"))
            XCTAssertLessThanOrEqual(u, b, "seed \(seed)")
            if u < b { movedUp += 1 }
            let d = try XCTUnwrap(down.firstIndex(of: "s4")), b4 = try XCTUnwrap(base.firstIndex(of: "s4"))
            XCTAssertGreaterThanOrEqual(d, b4, "seed \(seed)")
        }
        XCTAssertGreaterThan(movedUp, 150, "a love moves the song up for nearly every seed")
    }

    func testNoSeedKeepsTheFixedWeave() {
        let lists = [(0..<10).map { cand("f\($0)", "F\($0)", .seed, familiar: true) },
                     (0..<10).map { cand("n\($0)", "N\($0)", .seed, familiar: false) }]
        var none: SplitMix64?
        XCTAssertEqual(StationPoolBuilder.weave(lists, weights: [0.5, 0.5], jitter: &none),
                       StationPoolBuilder.weave(lists, weights: [0.5, 0.5]))
        XCTAssertEqual(StationPoolBuilder.weave(lists, weights: [0.5, 0.5]).map(\.id).prefix(4), ["f0", "n0", "f1", "n1"])
    }
}

final class StationWeaveJitterTests: XCTestCase {
    private func lists(_ sizes: [Int]) -> [[StationCandidate]] {
        sizes.enumerated().map { l, n in (0..<n).map { cand("l\(l)-\($0)", "A\(l)-\($0)", .seed, familiar: true) } }
    }

    private func pattern(_ woven: [StationCandidate]) -> [Int] {
        woven.map { Int($0.id.dropFirst().prefix { $0 != "-" })! }
    }

    /// The jitter changes the cadence: 200 seeds give many familiar/new patterns, not one.
    func testJitterVariesTheCadence() {
        let input = lists([20, 20])
        let patterns = Set(seeds.map { seed -> [Int] in
            var rng: SplitMix64? = SplitMix64(seed: seed)
            return pattern(StationPoolBuilder.weave(input, weights: [0.7, 0.3], jitter: &rng))
        })
        XCTAssertGreaterThan(patterns.count, 50)
    }

    /// Bounded: while every list has songs left, no list is more than `1 + weaveJitter` songs off its
    /// share, and no list runs longer than the stated cap: `ceil(share / (1 - share)) + 3`.
    /// (The fixed weave's longest run is `ceil(share / (1 - share))`.)
    func testJitterIsBoundedAndCapsRuns() {
        let cases: [(sizes: [Int], weights: [Double])] = [
            ([40, 40], [0.7, 0.3]), ([40, 40], [0.5, 0.5]), ([40, 40], [0.25, 0.75]),
            ([60, 60, 60], [0.6, 0.4, 0]), ([60, 60, 60], [0.4, 0.3, 0.3]),
        ]
        for c in cases {
            let input = lists(c.sizes)
            let total = c.weights.filter { $0 > 0 }.reduce(0, +)
            let open = c.weights.indices.filter { c.weights[$0] > 0 }
            for seed in seeds {
                var rng: SplitMix64? = SplitMix64(seed: seed)
                let p = pattern(StationPoolBuilder.weave(input, weights: c.weights, jitter: &rng))
                XCTAssertEqual(p.count, c.sizes.reduce(0, +))
                var taken = Array(repeating: 0, count: c.sizes.count)
                var run = 0
                for (n, list) in p.enumerated() {
                    run = n > 0 && p[n - 1] == list ? run + 1 : 1
                    taken[list] += 1
                    guard open.allSatisfy({ taken[$0] < c.sizes[$0] }) else { break }
                    XCTAssertTrue(open.contains(list), "a zero-weight list waits, seed \(seed)")
                    for i in open {
                        let share = c.weights[i] / total
                        XCTAssertLessThanOrEqual(abs(Double(taken[i]) - share * Double(n + 1)),
                                                 1 + StationPoolBuilder.weaveJitter + 1e-9, "\(c) seed \(seed) at \(n)")
                    }
                    let share = c.weights[list] / total
                    let cap = Int((share / (1 - share)).rounded(.up)) + 3
                    XCTAssertLessThanOrEqual(run, cap, "\(c) run of list \(list), seed \(seed)")
                }
            }
        }
    }
}

// MARK: - Feed seed source

private func stationSeed(_ id: String) -> StationSeed { StationSeed(kind: .artist, catalogID: id, name: "Artist \(id)") }

private func varietyStation() -> StationConfiguration {
    var c = StationConfiguration.default
    c.seeds = [stationSeed("v")]
    c.reach = .related
    c.discovery = 0.3
    return c.validated()
}

private struct VarietyCatalog: StationSeedCatalog {
    private func songs(_ tier: String, _ limit: Int) -> [StationCandidate] {
        (0..<min(limit, 30)).map { n in
            StationCandidate(track: TrackInfo(id: "\(tier)-\(n)", title: "Title \(tier) \(n)", artistName: "\(tier)-artist-\(n)"))
        }
    }
    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs("core", limit) }
    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs("related", limit) }
    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs("broad", limit) }
}

private struct CountingGenerator: RandomNumberGenerator {
    var calls = 0
    mutating func next() -> UInt64 { calls += 1; return 0xABCD }
}

@MainActor
final class StationVarietyFeedTests: XCTestCase {
    private func feed(_ source: StationShuffleSeedSource? = nil) -> StationQueueFeed<String> {
        let options = source.map { StationPoolBuilder.Options(limit: 20, seedSource: $0) } ?? .init(limit: 20)
        return StationQueueFeed<String>(resolver: CatalogStationSeedResolver(catalog: VarietyCatalog()),
                                        materialize: { $0.map(\.id) }, options: options, day: { 42 })
    }

    private func order(_ f: StationQueueFeed<String>) async throws -> [String] {
        let outcome = await f.prepare(varietyStation())
        guard case .ready = outcome else { XCTFail("\(outcome)"); return [] }
        return try XCTUnwrap(f.takeForIdleStart(active: varietyStation()))
    }

    /// The owner's ask: two builds of the same station on the same day are not the same order.
    func testTheDefaultReshufflesEveryBuildOnTheSameDay() async throws {
        var orders = Set<[String]>()
        let one = feed()
        for _ in 0..<10 {
            orders.insert(try await order(one))
            orders.insert(try await order(feed()))
        }
        XCTAssertGreaterThan(orders.count, 15, "20 builds, same station, same day")
    }

    func testFixedSeedsAreDeterministicAndDiffer() async throws {
        let a = try await order(feed(.fixed(1)))
        let again = try await order(feed(.fixed(1)))
        let other = try await order(feed(.fixed(2)))
        XCTAssertEqual(a, again)
        XCTAssertNotEqual(a, other)
        let day1 = try await order(feed(.perDay))
        let day2 = try await order(feed(.perDay))
        XCTAssertEqual(day1, day2, "the pre-#418 seed, for old tests")
    }

    /// Sentinel: the default seed comes from the system generator only, nothing personal.
    func testTheDefaultSeedIsSystemRandomOnly() throws {
        XCTAssertEqual(StationPoolBuilder.Options().seedSource, .systemRandom)
        var gen = CountingGenerator()
        var perDayRead = false
        let seed = StationShuffleSeedSource.systemRandom.seed(perDay: { perDayRead = true; return 1 }(), using: &gen)
        XCTAssertEqual(seed, 0xABCD)
        XCTAssertEqual(gen.calls, 1)
        XCTAssertFalse(perDayRead, "the station key and day are never mixed into the system seed")
        XCTAssertEqual(StationShuffleSeedSource.fixed(9).seed(perDay: 1), 9)
        XCTAssertEqual(StationShuffleSeedSource.perDay.seed(perDay: 5), 5)

        // Source pin: the default path builds a SystemRandomNumberGenerator and nothing else.
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AeroDJCore/Station/StationSeedEngine.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public enum StationShuffleSeedSource"))
        let end = try XCTUnwrap(source.range(of: "struct SplitMix64", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("var system = SystemRandomNumberGenerator()"))
        XCTAssertTrue(body.contains("case .systemRandom: generator.next()"))
        for banned in ["identifierForVendor", "UIDevice", "userID", "accountID", "history", "UserDefaults", "Logger", "print("] {
            XCTAssertFalse(body.contains(banned), banned)
        }
        // Never logged: no queue event carries a seed.
        let events: [StationQueueEvent] = [.built(songs: 1, poolSongs: 2, failedLookups: 0, libraryLimited: 0),
                                           .notBuilt(.emptyPool, failedLookups: 0), .handedOff(.refill, songs: 3)]
        for e in events { XCTAssertFalse(e.diagnostics.lowercased().contains("seed"), e.diagnostics) }
    }

    /// Echo: a prepared break's closing line names the next song. A rebuild with a new seed never
    /// moves it: every refill starts with the playing queue's up-next song, and the playing queue is
    /// never edited. 200 rebuilds, each with a fresh system seed.
    func testARebuildNeverMovesTheUpNextSong() async throws {
        let f = feed()
        let st = varietyStation()
        var queue = ["tap-1", "tap-2", "up-next"]
        f.queueStarted(for: st, songCount: queue.count)
        var firsts = Set<String>()
        for round in 0..<200 {
            let outcome = await f.prepare(st)
            XCTAssertNotEqual(outcome, .skipped(.emptyPool))
            for _ in 0..<1000 where f.stagedCount == nil { await Task.yield() }
            let before = queue
            let upNext = queue[queue.count - 1]
            let refill = try XCTUnwrap(f.queueForNextSong(after: queue.count - 2, in: queue, active: st,
                                                          playbackMayStart: true, sameSong: ==), "round \(round)")
            XCTAssertEqual(queue, before, "the playing queue is never edited")
            XCTAssertEqual(refill.first, upNext, "round \(round): the break's next song stays next")
            XCTAssertEqual(refill.filter { $0 == upNext }.count, 1)
            if refill.count > 1 { firsts.insert(refill[1]) }
            f.handOffFinished(.started)
            queue = [refill[0], refill.count > 1 ? refill[1] : "pad", "up-next-\(round)"]
            f.queueStarted(for: st, songCount: queue.count)
        }
        XCTAssertGreaterThan(firsts.count, 5, "what follows the up-next song is reshuffled")
    }
}
