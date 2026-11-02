import XCTest
@testable import AeroDJCore

/// Song ratings, PR A (-Nova): the model, the approved numbers (`StationRatingTuning`), decay on an
/// injected day, caps, eviction, the three-strikes artist rule, and what the pool builder and the
/// resolver do with a bias. Days are plain integers (the feed's `day`), so every test is deterministic.
final class StationRatingsTests: XCTestCase {
    private typealias T = StationRatingTuning
    private let accuracy = 1e-9

    private func rated(_ song: String, _ artist: String, _ rating: SongRating, day: Int = 0,
                       artistID: String? = nil, origin: TrackOrigin = .catalog) -> StationRatingEntry {
        StationRatingEntry(songID: song, artistName: artist, artistID: artistID, rating: rating, ratedDay: day, origin: origin)
    }

    private func rated(_ song: String, _ rating: SongRating, day: Int = 0, artistID: String? = nil,
                       origin: TrackOrigin = .catalog) -> StationRatingEntry {
        rated(song, "Artist", rating, day: day, artistID: artistID, origin: origin)
    }

    private func bias(_ entries: [StationRatingEntry], today: Int, seeds: [StationSeed] = []) -> StationRatingBias {
        StationRatingBias.make(StationRatings(entries: entries), seeds: seeds, today: today, seedsFingerprint: 1)
    }

    // MARK: Levels and decay

    func testTiredHoldsFourteenDaysThenEasesBackToZeroByDayTwentyEight() {
        let tired = [rated("s", .tired, day: 100)]
        for today in 100..<114 {
            let b = bias(tired, today: today)
            XCTAssertTrue(b.excludedSongIDs.contains("s"), "day \(today - 100): held out")
            XCTAssertNil(b.songScores["s"])
        }
        XCTAssertEqual(bias(tired, today: 114).songScores["s"] ?? 0, -0.30, accuracy: accuracy, "back at -0.30")
        XCTAssertFalse(bias(tired, today: 114).excludedSongIDs.contains("s"))
        XCTAssertEqual(bias(tired, today: 121).songScores["s"] ?? 0, -0.15, accuracy: accuracy, "halfway")
        XCTAssertEqual(bias(tired, today: 127).songScores["s"] ?? 0, -0.30 / 14, accuracy: accuracy)
        let ended = bias(tired, today: 128)
        XCTAssertNil(ended.songScores["s"], "the entry ends at day 28")
        XCTAssertTrue(ended.isNeutral)
        XCTAssertTrue(tired[0].isExpired(today: 128))
        XCTAssertFalse(tired[0].isExpired(today: 127))
        XCTAssertTrue(bias(tired, today: 114).artistScores.isEmpty, "tired never touches the artist")
    }

    func testNeverExcludesTheSongPermanently() {
        let b = bias([rated("s", .never, day: 0)], today: 10_000)
        XCTAssertEqual(b.excludedSongIDs, ["s"])
        XCTAssertNil(b.songScores["s"])
        XCTAssertNil(b.artistScores["artist"], "one never-rated song leaves the artist at 0")
    }

    func testLikeHasASixtyDayHalfLife() {
        let likes = [rated("s", .like, day: 0)]
        XCTAssertEqual(bias(likes, today: 0).songScores["s"] ?? 0, 0.15, accuracy: accuracy)
        XCTAssertEqual(bias(likes, today: 0).artistScores["artist"] ?? 0, 0.05, accuracy: accuracy)
        XCTAssertEqual(bias(likes, today: 60).songScores["s"] ?? 0, 0.075, accuracy: accuracy)
        XCTAssertEqual(bias(likes, today: 60).artistScores["artist"] ?? 0, 0.025, accuracy: accuracy)
        XCTAssertEqual(bias(likes, today: 120).songScores["s"] ?? 0, 0.0375, accuracy: accuracy)
    }

    func testLoveHasAHundredTwentyDayHalfLife() {
        let loves = [rated("s", .love, day: 0)]
        XCTAssertEqual(bias(loves, today: 0).songScores["s"] ?? 0, 0.50, accuracy: accuracy)
        XCTAssertEqual(bias(loves, today: 0).artistScores["artist"] ?? 0, 0.25, accuracy: accuracy)
        XCTAssertEqual(bias(loves, today: 120).songScores["s"] ?? 0, 0.25, accuracy: accuracy)
        XCTAssertEqual(bias(loves, today: 120).artistScores["artist"] ?? 0, 0.125, accuracy: accuracy)
        XCTAssertEqual(bias(loves, today: -5).songScores["s"] ?? 0, 0.50, accuracy: accuracy, "a clock going back never boosts")
    }

    // MARK: Caps

    func testArtistLikesCapAtAQuarterAndShareTheLoveCap() {
        let tenLikes = (0..<10).map { rated("l\($0)", .like) }
        XCTAssertEqual(bias(tenLikes, today: 0).artistScores["artist"] ?? 0, 0.25, accuracy: accuracy)
        let fourLoves = (0..<4).map { rated("v\($0)", .love) }
        XCTAssertEqual(bias(fourLoves, today: 0).artistScores["artist"] ?? 0, 0.75, accuracy: accuracy)
        let oneLoveFiveLikes = [rated("v", .love)] + (0..<5).map { rated("l\($0)", .like) }
        XCTAssertEqual(bias(oneLoveFiveLikes, today: 0).artistScores["artist"] ?? 0, 0.50, accuracy: accuracy)
        let twoLovesTenLikes = (0..<2).map { rated("v\($0)", .love) } + tenLikes
        XCTAssertEqual(bias(twoLovesTenLikes, today: 0).artistScores["artist"] ?? 0, 0.75, accuracy: accuracy, "shared cap")
    }

    func testCombinedScoreIsClampedToPlusMinusOne() {
        let loved = bias((0..<4).map { rated("v\($0)", .love) }, today: 0)
        XCTAssertEqual(loved.score(songID: "v0", artistName: "ARTIST"), 1, accuracy: accuracy, "0.50 + 0.75, clamped")
        let low = bias((0..<5).map { rated("n\($0)", .never) } + [rated("t", .tired, day: 0)], today: 14)
        XCTAssertEqual(low.score(songID: "t", artistName: "Artist"), -1, accuracy: accuracy, "-0.30 - 0.75, clamped")
        XCTAssertEqual(low.score(songID: "other", artistName: "Someone"), 0)
    }

    // MARK: One rating per song

    func testOneCurrentRatingPerSongAndTheSameLevelClears() {
        var station = StationRatings()
        XCTAssertEqual(station.rate(rated("s", .like), today: 0), .like)
        XCTAssertEqual(station.rate(rated("s", .love), today: 0), .love, "another level replaces")
        XCTAssertEqual(station.count, 1)
        XCTAssertNil(station.rate(rated("s", .love), today: 0), "the same level clears")
        XCTAssertTrue(station.isEmpty)
    }

    func testArtistsMatchByLowercasedName() {
        let e = rated("s", "  The Calm  ", .love)
        XCTAssertEqual(e.artistName, "the calm")
        let b = bias([e], today: 0)
        XCTAssertEqual(b.score(songID: "x", artistName: "THE CALM"), 0.25, accuracy: accuracy)
    }

    // MARK: Three strikes

    func testThreeStrikesDropsANonSeedArtistAndStepsItsPenalty() {
        let expected: [Int: Double] = [1: 0, 2: -0.25, 3: -0.50, 4: -0.75, 5: -0.75]
        for (count, penalty) in expected {
            let b = bias((0..<count).map { rated("n\($0)", "Band", .never) }, today: 0)
            XCTAssertEqual(b.artistScores["band"] ?? 0, penalty, accuracy: accuracy, "\(count) nevers")
            XCTAssertEqual(b.droppedArtists.contains("band"), count >= 3, "\(count) nevers")
        }
    }

    func testASeedArtistIsOnlyDownWeightedWithAFloorOfMinusAHalf() {
        let byName = [StationSeed(kind: .artist, catalogID: "seed-1", name: "Band")]
        let byID = [StationSeed(kind: .artist, catalogID: "a-9", name: "Renamed")]
        for count in 1...6 {
            let plain = (0..<count).map { rated("n\($0)", "Band", .never) }
            let withID = (0..<count).map { rated("n\($0)", "Band", .never, artistID: "a-9") }
            for (label, b) in [("name", bias(plain, today: 0, seeds: byName)), ("id", bias(withID, today: 0, seeds: byID))] {
                let want = count <= 1 ? 0 : max(-0.50, -0.25 * Double(count - 1))
                XCTAssertEqual(b.artistScores["band"] ?? 0, want, accuracy: accuracy, "\(label) \(count)")
                XCTAssertFalse(b.droppedArtists.contains("band"), "\(label) \(count): a seed artist is never dropped")
            }
        }
        let genreSeed = [StationSeed(kind: .genre, catalogID: "20", name: "Band")]
        XCTAssertTrue(bias((0..<3).map { rated("n\($0)", "Band", .never) }, today: 0, seeds: genreSeed)
            .droppedArtists.contains("band"), "only artist seeds protect an artist")
    }

    // MARK: Limits

    func testFiveHundredPerStationEvictsExpiredTiredThenLikesThenLovesThenNevers() {
        let today = 1_000
        var seed: [StationRatingEntry] = [
            rated("expired", .tired, day: today - 40),
            rated("like-new", .like, day: 50), rated("like-old", .like, day: 40),
            rated("love-old", .love, day: 10), rated("love-new", .love, day: 60),
            rated("tired-old", .tired, day: today - 2), rated("tired-new", .tired, day: today - 1),
        ]
        seed += (0..<(T.maxEntriesPerStation - seed.count)).map { rated(String(format: "never-%03d", $0), .never, day: 5) }
        var station = StationRatings(entries: seed)
        XCTAssertEqual(station.count, 500)
        let order = ["expired", "like-old", "like-new", "love-old", "love-new", "tired-old", "tired-new", "never-000", "never-001"]
        for (i, victim) in order.enumerated() {
            XCTAssertNotNil(station.rating(for: victim), "\(victim) is still there before step \(i)")
            station.rate(rated("added-\(i)", .never, day: today), today: today)
            XCTAssertEqual(station.count, 500, "step \(i)")
            XCTAssertNil(station.rating(for: victim), "step \(i) evicts \(victim)")
            XCTAssertEqual(station.rating(for: "added-\(i)"), .never, "the new rating is kept")
        }
    }

    func testPruneDropsOnlyExpiredTired() {
        var book = StationRatingBook()
        let scope = StationRatingScope.recipe(UUID())
        book.rate(rated("old", .tired, day: 0), in: scope, today: 0)
        book.rate(rated("keep", .never, day: 0), in: scope, today: 0)
        book.prune(today: 27)
        XCTAssertEqual(book.ratings(for: scope).count, 2)
        book.prune(today: 28)
        XCTAssertEqual(book.ratings(for: scope).count, 1)
        XCTAssertEqual(book.rating(for: "keep", in: scope), .never)
    }

    // MARK: Scope, book, file format

    func testScopeIsTheRecipeOrTheSeedHashAndTagsOnlyHasNone() {
        let seeds = [StationSeed(kind: .artist, catalogID: "1", name: "A")]
        let tagsOnly = StationConfiguration(genres: ["jazz"])
        XCTAssertNil(StationRatingScope(recipeID: nil, configuration: tagsOnly))
        XCTAssertNil(StationRatingScope(recipeID: UUID(), configuration: tagsOnly), "tags-only can't be rated in v1")
        let id = UUID()
        XCTAssertEqual(StationRatingScope(recipeID: id, configuration: StationConfiguration(seeds: seeds)), .recipe(id))
        let a = StationRatingScope(recipeID: nil, configuration: StationConfiguration(discovery: 0.1, seeds: seeds, reach: .only))
        let b = StationRatingScope(recipeID: nil, configuration: StationConfiguration(discovery: 0.9, seeds: seeds, reach: .broad))
        XCTAssertEqual(a, b, "reach and discovery are tuning, not the station")
        let c = StationRatingScope(recipeID: nil, configuration: StationConfiguration(seeds: [StationSeed(kind: .artist, catalogID: "2", name: "A")]))
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(StationRatingBook().bias(recipeID: id, configuration: tagsOnly, today: 0), .none)
    }

    func testBookRoundTripsAndNormalizesOnLoad() throws {
        var book = StationRatingBook()
        let scope = StationRatingScope.seeds(0xabc)
        book.rate(rated("s1", "Band", .love, day: 3, artistID: "a1"), in: scope, today: 3)
        book.rate(rated("s2", "Band", .never, day: 4, origin: .library), in: .recipe(UUID()), today: 4)
        let data = try JSONEncoder().encode(book)
        let back = try JSONDecoder().decode(StationRatingBook.self, from: data)
        XCTAssertEqual(back, book)
        XCTAssertEqual(back.changes, 0, "the change counter is per process, never saved")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("changes"))

        let raw = #"{"version":1,"stations":{"seeds:1":{"entries":[{"songID":"x","artistName":" LOUD Band ","rating":"love","ratedDay":1,"origin":"weird"}]}}}"#
        let loaded = try JSONDecoder().decode(StationRatingBook.self, from: Data(raw.utf8))
        let e = try XCTUnwrap(loaded.ratings(for: .seeds(1)).entries["x"])
        XCTAssertEqual(e.artistName, "loud band")
        XCTAssertEqual(e.origin, .unknown, "an unknown origin fails closed")
    }

    func testBookRevisionMovesOnEveryChangeAndClearsWork() {
        var book = StationRatingBook()
        let config = StationConfiguration(seeds: [StationSeed(kind: .artist, catalogID: "1", name: "A")])
        let scope = StationRatingScope(recipeID: nil, configuration: config)!
        let r0 = book.bias(recipeID: nil, configuration: config, today: 5).revision
        book.rate(rated("s", .never), in: scope, today: 5)
        let r1 = book.bias(recipeID: nil, configuration: config, today: 5).revision
        XCTAssertNotEqual(r0, r1)
        XCTAssertNotEqual(r1, book.bias(recipeID: nil, configuration: config, today: 6).revision, "a new day is a new revision")
        XCTAssertEqual(book.bias(recipeID: nil, configuration: config, today: 5).excludedSongIDs, ["s"])
        book.clearStation(scope)
        XCTAssertTrue(book.bias(recipeID: nil, configuration: config, today: 5).isNeutral)
        book.rate(rated("s", .never), in: scope, today: 5)
        book.clearAll()
        XCTAssertTrue(book.stations.isEmpty)
    }

    // MARK: Love affinity

    func testAffinityUsesOnlyCatalogLovesWithAnArtistIDAndNeverASeed() {
        let seeds = [StationSeed(kind: .artist, catalogID: "seed-a", name: "Seed Band")]
        let entries = [
            rated("1", "Seed Band", .love, artistID: "seed-a"),
            rated("2", "Library Band", .love, artistID: "lib", origin: .library),
            rated("3", "Unknown Band", .love, artistID: "unk", origin: .unknown),
            rated("4", "No ID Band", .love),
            rated("5", "Two", .love, artistID: "two"), rated("6", "Two", .love, artistID: "two"),
            rated("7", "One", .love, artistID: "one"),
            rated("8", "Third", .love, day: -100, artistID: "third"),
            rated("9", "Liked", .like, artistID: "liked"),
        ]
        let b = bias(entries, today: 0, seeds: seeds)
        XCTAssertEqual(b.affinityArtists.map(\.artistID), ["two", "one"], "best two, catalog only, not a seed")
    }

    // MARK: Pool builder

    private func pool(_ n: Int, tier: StationCandidateTier = .seed, prefix: String = "s") -> [StationCandidate] {
        (0..<n).map { StationCandidate(track: TrackInfo(id: "\(prefix)\($0)", title: "T\(prefix)\($0)", artistName: "A\(prefix)\($0)"),
                                       tier: tier, isFamiliar: true) }
    }

    private func build(_ songs: [StationCandidate], _ ratings: StationRatingBias, gap: Int = 0,
                       reach: StationReach = .only) -> [String] {
        var byTier: [StationCandidateTier: [StationCandidate]] = [:]
        for s in songs { byTier[s.tier, default: []].append(s) }
        return StationPoolBuilder.build(StationCandidatePool(byTier: byTier), reach: reach, discovery: 0,
                                        options: .init(limit: 100, artistGap: gap, ratings: ratings)).map(\.id)
    }

    func testANeutralBiasBuildsExactlyAsBefore() {
        let songs = pool(20)
        let base = StationPoolBuilder.build(StationCandidatePool(byTier: [.seed: songs]), reach: .only, discovery: 0.3,
                                            options: .init(limit: 50, shuffleSeed: 7)).map(\.id)
        let unrelated = bias([rated("elsewhere", "Nobody", .love)], today: 0)
        let withBias = StationPoolBuilder.build(StationCandidatePool(byTier: [.seed: songs]), reach: .only, discovery: 0.3,
                                                options: .init(limit: 50, shuffleSeed: 7, ratings: unrelated)).map(\.id)
        XCTAssertEqual(base, withBias, "ratings for songs not in the pool change nothing")
    }

    func testAScoreMovesASongAtMostThirtyPercentOfItsList() {
        let songs = pool(10)
        // love song + artist: 0.50 + 0.25 = 0.75 -> round(0.75 × 0.3 × 10) = 2 places up.
        let loved = build(songs, bias([rated("s9", "As9", .love)], today: 0))
        XCTAssertEqual(loved.firstIndex(of: "s9"), 7)
        // clamped to 1 -> 3 places, the most.
        let maxed = build(songs, bias([rated("s9", "As9", .love)] + (0..<3).map { rated("x\($0)", "As9", .love) }, today: 0))
        XCTAssertEqual(maxed.firstIndex(of: "s9"), 6)
        // like: 0.15 + 0.05 = 0.20 -> round(0.6) = 1 place.
        XCTAssertEqual(build(songs, bias([rated("s5", "As5", .like)], today: 0)).firstIndex(of: "s5"), 4)
        // tired at its return: -0.30 -> round(-0.9) = 1 place down.
        XCTAssertEqual(build(songs, bias([rated("s2", "As2", .tired, day: 0)], today: 14)).firstIndex(of: "s2"), 3)
        // the others keep their relative order.
        XCTAssertEqual(loved.filter { $0 != "s9" }, songs.map(\.id).filter { $0 != "s9" })
    }

    func testNeverAndHeldTiredSongsAreLeftOut() {
        let b = bias([rated("s1", "As1", .never), rated("s2", "As2", .tired, day: 0)], today: 3)
        let ids = build(pool(5), b)
        XCTAssertFalse(ids.contains("s1"))
        XCTAssertFalse(ids.contains("s2"))
        XCTAssertEqual(ids.count, 3)
    }

    func testADroppedArtistLeavesRelatedAndBroadButNotTheSeedTier() {
        let band = { (id: String, tier: StationCandidateTier) in
            StationCandidate(track: TrackInfo(id: id, title: id, artistName: "Band"), tier: tier)
        }
        let songs = [band("seed-song", .seed), band("rel-song", .related), band("broad-song", .broad)]
            + pool(3, prefix: "x") + pool(3, tier: .related, prefix: "r") + pool(3, tier: .broad, prefix: "b")
        let dropped = bias((0..<3).map { rated("n\($0)", "band", .never) }, today: 0)
        let ids = build(songs, dropped, reach: .broad)
        XCTAssertTrue(ids.contains("seed-song"))
        XCTAssertFalse(ids.contains("rel-song"))
        XCTAssertFalse(ids.contains("broad-song"))
    }

    func testSameArtistSpacingStillAppliesAfterTheReRank() {
        let songs = [StationCandidate(track: TrackInfo(id: "a1", title: "a1", artistName: "Star")),
                     StationCandidate(track: TrackInfo(id: "a2", title: "a2", artistName: "Star"))] + pool(8)
        let loved = bias([rated("a1", "Star", .love), rated("a2", "Star", .love)], today: 0)
        let ids = build(songs, loved, gap: 2)
        let first = ids.firstIndex(of: "a1")!, second = ids.firstIndex(of: "a2")!
        XCTAssertGreaterThan(abs(second - first), 2, "two other songs between them")
    }

    // MARK: Resolver: love steers discovery

    private actor Calls {
        var related: [StationSeed] = []
        var limits: [Int] = []
        func add(_ seed: StationSeed, _ limit: Int) { related.append(seed); limits.append(limit) }
    }

    private struct RecordingCatalog: StationSeedCatalog {
        let calls: Calls
        let relatedPerSeed: Int
        func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
            (0..<5).map { StationCandidate(track: TrackInfo(id: "\(seed.catalogID)-core-\($0)", title: "c\($0)", artistName: seed.catalogID)) }
        }
        func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
            await calls.add(seed, limit)
            return (0..<min(limit, relatedPerSeed)).map {
                StationCandidate(track: TrackInfo(id: "\(seed.catalogID)-rel-\($0)", title: "r\($0)", artistName: "\(seed.catalogID)-rel"))
            }
        }
        func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { [] }
    }

    func testLovedArtistsAddRelatedSongsCappedAtTwentyPercentWithoutBecomingSeeds() async {
        let calls = Calls()
        let resolver = CatalogStationSeedResolver(catalog: RecordingCatalog(calls: calls, relatedPerSeed: 40))
        let seeds = [StationSeed(kind: .artist, catalogID: "seed", name: "Seed")]
        let affinity = [StationAffinityArtist(artistID: "seed", name: "seed"),
                        StationAffinityArtist(artistID: "love-1", name: "one"),
                        StationAffinityArtist(artistID: "love-2", name: "two"),
                        StationAffinityArtist(artistID: "love-3", name: "three")]
        let pool = await resolver.resolve(seeds: seeds, reach: .related, affinity: affinity)
        let asked = await calls.related
        let limits = await calls.limits
        XCTAssertEqual(asked.map(\.catalogID), ["seed", "love-1", "love-2"], "the seed's own lookup, then two loved artists")
        XCTAssertEqual(Array(limits.dropFirst()), [10, 10])
        XCTAssertTrue(asked.dropFirst().allSatisfy { $0.kind == .artist && $0.source == .catalog },
                      "only catalog artist IDs reach Apple Music")
        let related = pool.songs(.related)
        let affinitySongs = related.filter { $0.id.hasPrefix("love-") }
        XCTAssertEqual(related.count, 50)
        XCTAssertEqual(affinitySongs.count, 10, "40 regular -> at most 10 affinity (20% of 50)")
        XCTAssertLessThanOrEqual(Double(affinitySongs.count), 0.2 * Double(related.count) + 1e-9)
        XCTAssertEqual(Array(related.prefix(5)).filter { $0.id.hasPrefix("love-") }.count, 1, "spread through the tier")
        XCTAssertTrue(affinitySongs.allSatisfy { $0.tier == .related })
    }

    func testNoAffinityLookupsAtOnlyReachOrForALibrarySeed() async {
        let affinity = [StationAffinityArtist(artistID: "love-1", name: "one")]
        for (label, seeds, reach) in [
            ("only", [StationSeed(kind: .artist, catalogID: "seed", name: "Seed")], StationReach.only),
            ("library", [StationSeed(kind: .artist, catalogID: "lib", name: "Mine", source: .library)], StationReach.broad),
        ] {
            let calls = Calls()
            let resolver = CatalogStationSeedResolver(catalog: RecordingCatalog(calls: calls, relatedPerSeed: 40))
            let pool = await resolver.resolve(seeds: seeds, reach: reach, affinity: affinity)
            let asked = await calls.related
            XCTAssertTrue(asked.isEmpty, label)
            XCTAssertTrue(pool.songs(.related).isEmpty, label)
        }
    }
}
