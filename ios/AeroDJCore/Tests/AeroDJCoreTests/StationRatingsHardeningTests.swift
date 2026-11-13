import XCTest
@testable import AeroDJCore

/// Sentinel's #369 blockers (-Nova): a corrupt or hand-edited ratings file can never trap, and a
/// load holds no more than the per-station caps.
/// B1: day differences are overflow-safe; an implausible `ratedDay` reads as long ago (expired),
/// a future one as age 0. B2 with Orion's ruling: a save and a load trim the same way, 500 non-nevers
/// in the eviction order (never evicting a never) and 2000 nevers, oldest first.
final class StationRatingsHardeningTests: XCTestCase {
    private typealias T = StationRatingTuning
    private static let seeds = [StationSeed(kind: .artist, catalogID: "seed", name: "Seed", source: .catalog)]
    private static let config = StationConfiguration(seeds: seeds)
    private static var scope: StationRatingScope { StationRatingScope(recipeID: nil, configuration: config)! }

    private func json(_ entries: [(song: String, rating: String, day: String)]) -> Data {
        let list = entries.map {
            #"{"songID":"\#($0.song)","artistName":"A \#($0.song)","artistID":"aid-\#($0.song)","rating":"\#($0.rating)","ratedDay":\#($0.day),"origin":"catalog"}"#
        }.joined(separator: ",")
        return Data(#"{"version":1,"stations":{"\#(Self.scope.storageKey)":{"entries":[\#(list)]}}}"#.utf8)
    }

    private func load(_ data: Data, today: Int? = nil) throws -> StationRatingBook {
        let decoder = JSONDecoder()
        if let today { decoder.userInfo[StationRatingBook.todayKey] = today }
        return try decoder.decode(StationRatingBook.self, from: data)
    }

    // MARK: B1: days

    func testExtremeAndFutureDaysDecodeAndRunThroughBiasAndDecayWithoutTrapping() throws {
        let days = ["\(Int.min)", "\(Int.max)", "\(Int.max - 1)", "\(Int.min + 1)", "1e30", "-1e30", "12.5",
                    "null", "\"soon\"", "9500", "10000000", "400000"]
        var entries: [(String, String, String)] = []
        for (i, day) in days.enumerated() {
            for rating in ["tired", "never", "like", "love"] { entries.append(("s\(i)-\(rating)", rating, day)) }
        }
        let book = try load(json(entries))
        XCTAssertEqual(book.ratings(for: Self.scope).count, entries.count, "nothing is lost to a bad day")
        for entry in book.ratings(for: Self.scope).entries.values {
            XCTAssertTrue(T.plausibleDays.contains(entry.ratedDay), "\(entry.songID): day \(entry.ratedDay)")
        }
        for today in [Int.min, -1, 0, 9_400, Int.max] {
            let bias = book.bias(recipeID: nil, configuration: Self.config, today: today)
            for (_, score) in bias.songScores { XCTAssertTrue(score.isFinite) }
            for (_, score) in bias.artistScores { XCTAssertTrue(score.isFinite) }
            for i in days.indices {
                XCTAssertTrue(bias.excludedSongIDs.contains("s\(i)-never"), "a never stays a never on any day (\(today))")
                let s = bias.score(songID: "s\(i)-love", artistName: "A s\(i)-love")
                XCTAssertTrue(T.scoreRange.contains(s))
            }
            var copy = book
            copy.prune(today: today)   // no trap
            let songs = days.indices.flatMap { i in ["love", "like", "tired"].map {
                StationCandidate(track: TrackInfo(id: "s\(i)-\($0)", title: "t", artistName: "A s\(i)-\($0)"),
                                 tier: .seed, isFamiliar: true)
            } }
            var options = StationPoolBuilder.Options(limit: 50)
            options.ratings = bias
            let built = StationPoolBuilder.build(StationCandidatePool(byTier: [.seed: songs]), reach: .only, discovery: 0.3,
                                                 options: options)   // no trap
            XCTAssertFalse(built.isEmpty)
        }
    }

    func testAnImplausibleDayReadsAsLongAgoAndAFutureDayAsToday() throws {
        let today = 9_500
        let book = try load(json([("min-tired", "tired", "\(Int.min)"), ("max-tired", "tired", "\(Int.max)"),
                                  ("max-love", "love", "\(Int.max)"), ("future-tired", "tired", "\(today + 100)"),
                                  ("future-love", "love", "\(today + 100)")]))
        let entries = book.ratings(for: Self.scope).entries
        XCTAssertEqual(entries["min-tired"]?.ratedDay, T.implausibleDay)
        XCTAssertEqual(entries["max-tired"]?.ratedDay, T.implausibleDay, "Int.max is implausible, not 'forever held'")
        XCTAssertEqual(entries["max-tired"]?.isExpired(today: today), true, "an implausible tired is expired")
        XCTAssertEqual(entries["future-tired"]?.age(today: today), 0)
        let bias = book.bias(recipeID: nil, configuration: Self.config, today: today)
        XCTAssertFalse(bias.excludedSongIDs.contains("max-tired"))
        XCTAssertTrue(bias.excludedSongIDs.contains("future-tired"), "a future tired counts from today: held")
        XCTAssertEqual(bias.songScores["future-love"] ?? 0, T.loveSongBoost, accuracy: 1e-9, "a future love is full strength")
        XCTAssertLessThan(bias.songScores["max-love"] ?? 0, 1e-12, "an implausible love has decayed away")
        var pruned = book
        pruned.prune(today: today)
        XCTAssertNil(pruned.ratings(for: Self.scope).entries["max-tired"], "and is pruned")
    }

    func testDayArithmeticNeverOverflows() {
        XCTAssertEqual(T.ageDays(today: Int.max, ratedDay: Int.min), Int.max)
        XCTAssertEqual(T.ageDays(today: Int.min, ratedDay: Int.max), 0)
        XCTAssertEqual(T.ageDays(today: 10, ratedDay: 3), 7)
        XCTAssertEqual(T.ageDays(today: 3, ratedDay: 10), 0, "future: age 0")
        XCTAssertEqual(T.decay(ageDays: Int.max, halfLife: T.loveHalfLifeDays), 0, accuracy: 1e-300)
        XCTAssertEqual(T.decay(ageDays: 10, halfLife: .nan), 1)
        XCTAssertEqual(T.decay(ageDays: 10, halfLife: .infinity), 1)
        XCTAssertEqual(T.decay(ageDays: 10, halfLife: 0), 1)
        XCTAssertEqual(T.sanitizedDay(Int.min), T.implausibleDay)
        XCTAssertEqual(T.sanitizedDay(9_500), 9_500)
        let made = StationRatingEntry(songID: "x", artistName: "x", rating: .like, ratedDay: Int.max, origin: .catalog)
        XCTAssertEqual(made.ratedDay, T.implausibleDay, "init sanitizes too, not only decoding")
    }

    func testRatingAndEvictionWithExtremeTodayDoNotTrap() {
        var book = StationRatingBook()
        for i in 0..<(T.maxEntriesPerStation + 5) {
            let rating: SongRating = [.tired, .like, .love, .never][i % 4]
            book.rate(StationRatingEntry(songID: "s\(i)", artistName: "a\(i % 7)", rating: rating,
                                         ratedDay: [Int.min, Int.max, 0, 9_500][i % 4], origin: .catalog),
                      in: Self.scope, today: [Int.min, Int.max][i % 2])
        }
        let station = book.ratings(for: Self.scope)
        XCTAssertLessThanOrEqual(station.entries.values.filter { $0.rating != .never }.count, T.maxEntriesPerStation)
        XCTAssertLessThanOrEqual(station.entries.values.filter { $0.rating == .never }.count, T.maxNeversPerStation)
    }

    // MARK: B2: the limit on load

    func testLoadingTwoThousandEntriesKeepsFiveHundredNonNeversAndEveryNever() throws {
        let today = 9_500
        var entries: [(String, String, String)] = []
        for i in 0..<2000 {
            let rating = ["tired", "like", "love", "never"][i % 4]
            entries.append((String(format: "s%04d", i), rating, "\(today - (i % 50))"))
        }
        let nevers = Set(entries.filter { $0.1 == "never" }.map(\.0))
        XCTAssertEqual(nevers.count, 500)
        for todayKey in [Optional(today), nil] {
            let station = try load(json(entries), today: todayKey).ratings(for: Self.scope)
            XCTAssertEqual(station.entries.values.filter { $0.rating != .never }.count, T.maxEntriesPerStation)
            XCTAssertEqual(station.count, 1000)
            XCTAssertTrue(nevers.isSubset(of: Set(station.entries.keys)), "every never kept")
        }
    }

    func testLoadTrimsInTheEvictionOrder() throws {
        let today = 9_500
        var entries: [(String, String, String)] = []
        for i in 0..<300 { entries.append((String(format: "never%03d", i), "never", "\(today)")) }
        for i in 0..<350 { entries.append((String(format: "love%03d", i), "love", "\(today - i)")) }
        for i in 0..<250 { entries.append((String(format: "like%03d", i), "like", "\(today - i)")) }
        for i in 0..<50 { entries.append((String(format: "tired%03d", i), "tired", "\(today - 40)")) }  // expired
        let station = try load(json(entries), today: today).ratings(for: Self.scope)
        XCTAssertEqual(station.count, 800, "500 non-nevers plus every never")
        let kept = station.entries.values
        XCTAssertEqual(kept.filter { $0.rating == .tired }.count, 0, "expired tired go first")
        XCTAssertEqual(kept.filter { $0.rating == .like }.count, 150, "then the oldest likes")
        XCTAssertNil(station.rating(for: "like249"))
        XCTAssertEqual(station.rating(for: "like149"), .like)
        XCTAssertEqual(kept.filter { $0.rating == .love }.count, 350)
        XCTAssertEqual(kept.filter { $0.rating == .never }.count, 300)
    }

    // MARK: Orion's ruling: separate caps, the same on save and load

    private func entries(nevers: Int, others: Int, today: Int) -> [(song: String, rating: String, day: String)] {
        var list: [(song: String, rating: String, day: String)] = []
        for i in 0..<nevers { list.append((String(format: "n%05d", i), "never", "\(today - 3000 + i)")) }
        let kinds = ["like", "love", "tired"]
        for i in 0..<others { list.append((String(format: "o%05d", i), kinds[i % 3], "\(today - 3000 + i)")) }
        return list
    }

    /// (1) Save: a full station plus many nevers; a new rating evicts a non-never, never a never.
    func testASaveOverTheCapEvictsANonNeverAndNeverANever() {
        let today = 9_500
        var station = StationRatings(entries:
            (0..<500).map { StationRatingEntry(songID: String(format: "love%03d", $0), artistName: "a", rating: .love,
                                               ratedDay: today - 500 + $0, origin: .catalog) }
            + (0..<1500).map { StationRatingEntry(songID: String(format: "never%04d", $0), artistName: "b", rating: .never,
                                                  ratedDay: today - 9000 + $0, origin: .catalog) })
        station.rate(StationRatingEntry(songID: "new-love", artistName: "c", rating: .love, ratedDay: today,
                                        origin: .catalog), today: today)
        XCTAssertEqual(station.rating(for: "new-love"), .love)
        XCTAssertNil(station.rating(for: "love000"), "the oldest love goes")
        XCTAssertEqual(station.entries.values.filter { $0.rating != .never }.count, 500)
        XCTAssertEqual(station.entries.values.filter { $0.rating == .never }.count, 1500, "every never kept, even the oldest")
        XCTAssertEqual(station.rating(for: "never0000"), .never)
        station.rate(StationRatingEntry(songID: "new-never", artistName: "c", rating: .never, ratedDay: today,
                                        origin: .catalog), today: today)
        XCTAssertEqual(station.count, 2001, "a never is outside the 500 cap: nothing goes")
    }

    /// (2) Load: 700 nevers plus 600 others gives all 700 nevers plus 500 others.
    func testALoadOfSevenHundredNeversAndSixHundredOthersKeepsAllNeversAndFiveHundredOthers() throws {
        let today = 9_500
        let input = entries(nevers: 700, others: 600, today: today)
        let station = try load(json(input), today: today).ratings(for: Self.scope)
        let kept = station.entries.values
        XCTAssertEqual(kept.filter { $0.rating == .never }.count, 700)
        XCTAssertEqual(kept.filter { $0.rating != .never }.count, 500)
        XCTAssertEqual(station.count, 1200)
    }

    /// (3) The nevers ceiling: past 2000 the oldest nevers go, on save and on load.
    func testPastTwoThousandTheOldestNeversGoOnSaveAndOnLoad() throws {
        let today = 9_500
        let input = entries(nevers: 2005, others: 10, today: today)
        let loaded = try load(json(input), today: today).ratings(for: Self.scope)
        XCTAssertEqual(loaded.entries.values.filter { $0.rating == .never }.count, T.maxNeversPerStation)
        for i in 0..<5 { XCTAssertNil(loaded.rating(for: String(format: "n%05d", i)), "load drops the oldest never \(i)") }
        XCTAssertEqual(loaded.rating(for: "n00005"), .never)
        XCTAssertEqual(loaded.entries.values.filter { $0.rating != .never }.count, 10, "the others are untouched")

        var saved = StationRatings(entries: (0..<T.maxNeversPerStation).map {
            StationRatingEntry(songID: String(format: "n%05d", $0), artistName: "a", rating: .never,
                               ratedDay: today - 3000 + $0, origin: .catalog)
        })
        saved.rate(StationRatingEntry(songID: "zz-new-never", artistName: "a", rating: .never, ratedDay: today,
                                      origin: .catalog), today: today)
        XCTAssertEqual(saved.count, T.maxNeversPerStation)
        XCTAssertNil(saved.rating(for: "n00000"), "save drops the oldest never")
        XCTAssertEqual(saved.rating(for: "zz-new-never"), .never)
    }

    /// (4) The same entries give the same station whether rated one by one (saves) or loaded at once,
    /// including the case a just-made exemption would break (a fresh like once no older like is left).
    func testASaveAndALoadOfTheSameEntriesGiveTheSameStation() throws {
        let today = 9_500
        let input = entries(nevers: 2300, others: 1200, today: today).sorted { Int($0.day)! < Int($1.day)! }
        var saved = StationRatings()
        for e in input {
            saved.rate(StationRatingEntry(songID: e.song, artistName: "A \(e.song)", artistID: "aid-\(e.song)",
                                          rating: SongRating(rawValue: e.rating)!, ratedDay: Int(e.day)!, origin: .catalog),
                       today: today)
        }
        let loaded = try load(json(input), today: today).ratings(for: Self.scope)
        XCTAssertEqual(loaded.entries.values.filter { $0.rating == .never }.count, T.maxNeversPerStation)
        XCTAssertEqual(loaded.entries.values.filter { $0.rating != .never }.count, T.maxEntriesPerStation)
        XCTAssertEqual(saved, loaded)
        // And a saved station reloads unchanged.
        let reloaded = try JSONDecoder().decode(StationRatings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded, saved)
    }
}
