import XCTest
@testable import AeroDJCore

// #418 (-Atlas): a station's opening song. Since #454 a tap starts on one song looked up on its own
// (`StationQueueFeed.firstSong`), and that lookup always used the first seed, so a station of song
// seeds (Morning Calm, Late Night) opened with the same song on every cold start. Every seed here is
// injected (`.fixed`, `.perDay`): no test reads the global random generator.

/// Like the app's catalog source: a song seed's core is that one song (its id is the seed id), an
/// artist seed's core is a few of its songs ("<id>-core-<n>"). Artist: "<id>-artist".
private actor OpenerFakeCatalog: StationSeedCatalog {
    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
        let artist = "\(seed.catalogID)-artist"
        if seed.kind == .song {
            return [StationCandidate(track: TrackInfo(id: seed.catalogID, title: seed.name, artistName: artist))]
        }
        return (0..<min(limit, 6)).map { n in
            StationCandidate(track: TrackInfo(id: "\(seed.catalogID)-core-\(n)", title: "\(seed.catalogID) \(n)", artistName: artist))
        }
    }

    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
        (0..<min(limit, 4)).map { n in
            StationCandidate(track: TrackInfo(id: "\(seed.catalogID)-related-\(n)", title: "\(seed.catalogID) r\(n)",
                                              artistName: "\(seed.catalogID)-related-artist-\(n)"))
        }
    }

    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { [] }
}

@MainActor
final class StationOpenerVarietyTests: XCTestCase {
    private let morning = BuiltInStations.morningCalm.configuration
    private let late = BuiltInStations.lateNight.configuration

    private func feed(_ source: StationShuffleSeedSource, limit: Int = 12,
                      recentlyPlayed: @escaping @MainActor () -> Set<String> = { [] }) -> StationQueueFeed<String> {
        StationQueueFeed<String>(resolver: CatalogStationSeedResolver(catalog: OpenerFakeCatalog()),
                                 materialize: { $0.map(\.id) },
                                 options: .init(limit: limit, seedSource: source),
                                 day: { 42 },
                                 recentlyPlayed: recentlyPlayed)
    }

    /// One tap's fast start on `config`: its first song, now playing.
    private func open(_ feed: StationQueueFeed<String>, _ config: StationConfiguration) async throws -> String {
        let looked = await feed.firstSong(for: config)
        let song = try XCTUnwrap(looked)
        XCTAssertTrue(feed.fastStartBegan(with: song, active: config))
        return song
    }

    private func seedIDs(_ config: StationConfiguration) -> [String] { config.seeds.map(\.catalogID) }

    // MARK: cold starts

    func testColdStartsOpenOnDifferentSeedsForDifferentBuildSeeds() async throws {
        var openers: [String] = []
        for buildSeed in UInt64(0)..<UInt64(32) {
            openers.append(try await open(feed(.fixed(buildSeed)), morning))
        }
        XCTAssertTrue(openers.allSatisfy(seedIDs(morning).contains), "\(openers)")
        XCTAssertGreaterThanOrEqual(Set(openers).count, 5, "32 cold starts opened with only \(Set(openers))")
    }

    func testTheSameBuildSeedOpensTheSameWay() async throws {
        let first = try await open(feed(.fixed(99)), late)
        let again = try await open(feed(.fixed(99)), late)
        XCTAssertEqual(first, again)
    }

    func testPerDayStillOpensOnTheFirstSeed() async throws {
        let song = try await open(feed(.perDay), morning)
        XCTAssertEqual(song, seedIDs(morning).first)
    }

    // MARK: no repeat within `openerMemory` starts

    /// Even with the SAME build seed every time (the worst case for a fixed stream), a station does
    /// not open with any of its last 3 openers (`StationQueueFeed.openerMemory`).
    func testAStationDoesNotRepeatAnOpenerWithinTheMemory() async throws {
        for source in [StationShuffleSeedSource.fixed(5), .perDay] {
            let feed = feed(source)
            var openers: [String] = []
            for _ in 0..<10 { openers.append(try await open(feed, morning)) }
            let window = 4                                        // the memory (3) plus this start
            for end in window...openers.count {
                let slice = openers[(end - window)..<end]
                XCTAssertEqual(Set(slice).count, window, "\(source): repeated within \(window): \(openers)")
            }
        }
    }

    func testEachStationKeepsItsOwnOpenerMemory() async throws {
        let feed = feed(.perDay)
        let a1 = try await open(feed, morning)
        let b1 = try await open(feed, late)
        let a2 = try await open(feed, morning)
        let b2 = try await open(feed, late)
        XCTAssertEqual([a1, b1], [seedIDs(morning)[0], seedIDs(late)[0]], "another station's start does not move this one")
        XCTAssertNotEqual(a1, a2)
        XCTAssertNotEqual(b1, b2)
        XCTAssertEqual(a2, seedIDs(morning)[1])
        XCTAssertEqual(b2, seedIDs(late)[1])
    }

    func testAOneSongStationStillOpens() async throws {
        var config = StationConfiguration.default
        config.seeds = [StationSeed(kind: .song, catalogID: "only-song", name: "Only")]
        config.reach = .only
        config = config.validated()
        let feed = feed(.fixed(3))
        for _ in 0..<3 {
            let song = try await open(feed, config)
            XCTAssertEqual(song, "only-song", "nothing else to open with: the same song, never nothing")
        }
    }

    func testAnArtistSeedSkipsItsLastOpenerAmongItsOwnSongs() async throws {
        var config = StationConfiguration.default
        config.seeds = [StationSeed(kind: .artist, catalogID: "solo", name: "Solo")]
        config.reach = .only
        config = config.validated()
        let feed = feed(.fixed(11))
        let first = try await open(feed, config)
        let second = try await open(feed, config)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasPrefix("solo-core-"))
    }

    // MARK: the opener cache (a tap back on a station built earlier)

    func testACachedOpenerIsNotTheSongTheStationLastOpenedWith() async throws {
        let feed = feed(.fixed(21))
        let built = await feed.prepare(morning)
        guard case .ready = built else { return XCTFail("Morning Calm builds, got \(built)") }
        let first = try await open(feed, morning)              // the staged queue's first song
        let switched = await feed.prepare(late)                 // another station is staged now
        guard case .ready = switched else { return XCTFail("Late Night builds, got \(switched)") }
        XCTAssertNotEqual(feed.stagedKey, StationQueueKey(morning))

        let back = try await open(feed, morning)                // from Morning Calm's cached openers
        XCTAssertNotEqual(back, first, "a tap back on Morning Calm opened with the same song again")
    }

    // MARK: guarantees kept

    /// The cold lookup reads one seed (#454, for speed): when that seed's song just played it finds
    /// nothing and the tap waits for the full build, as before. It never opens with a played song.
    func testARecentlyPlayedSongIsStillNeverTheOpener() async throws {
        let played: Set<String> = [seedIDs(morning)[0], seedIDs(morning)[3]]
        let feed = feed(.fixed(8), recentlyPlayed: { played })
        var opened: [String] = []
        for buildSeed in UInt64(0)..<UInt64(12) {
            let feed = buildSeed == 0 ? feed : self.feed(.fixed(buildSeed), recentlyPlayed: { played })
            guard let song = await feed.firstSong(for: morning) else { continue }
            XCTAssertFalse(played.contains(song), "\(song) just played")
            opened.append(song)
        }
        XCTAssertFalse(opened.isEmpty)
    }

    func testAStagedStartRecordsItsOpenerToo() async throws {
        let feed = feed(.perDay)
        let built = await feed.prepare(morning)
        guard case .ready = built else { return XCTFail("Morning Calm builds, got \(built)") }
        let staged = try XCTUnwrap(feed.takeForIdleStart(active: morning))
        let opener = try XCTUnwrap(staged.first)
        _ = await feed.prepare(late)
        let next = try await open(feed, morning)
        XCTAssertNotEqual(next, opener, "Play's staged start counts as the station's opener")
    }
}
