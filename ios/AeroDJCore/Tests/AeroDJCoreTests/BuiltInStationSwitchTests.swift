import XCTest
@testable import AeroDJCore

// #442 (-Atlas): the shipped built-in stations (`BuiltInStations`) start and switch through the one
// station start path (`CreatedStationStarter.open`), the same call the phone row and the CarPlay
// list make. The catalog is a fake keyed by the built-ins' own seed ids, so the queue each test
// reads is the station's own: nothing here plays or claims Apple Music audio.

/// Songs are "<seed id>-<tier>-<n>". Artist: "<seed id>-artist" unless `artists` maps the seed.
private actor BuiltInFakeCatalog: StationSeedCatalog {
    private let artists: [String: String]
    private let perSeed: Int
    init(artists: [String: String] = [:], perSeed: Int = 6) {
        self.artists = artists
        self.perSeed = perSeed
    }

    private func songs(_ seed: StationSeed, _ tier: String, _ limit: Int) -> [StationCandidate] {
        let artist = artists[seed.catalogID] ?? "\(seed.catalogID)-artist"
        return (0..<min(limit, perSeed)).map { n in
            StationCandidate(track: TrackInfo(id: "\(seed.catalogID)-\(tier)-\(n)", title: "\(seed.catalogID) \(tier) \(n)",
                                              artistName: artist))
        }
    }

    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "core", limit) }
    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "related", limit) }
    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "broad", limit) }
}

@MainActor
final class BuiltInStationSwitchTests: XCTestCase {
    private final class Player {
        var queue: [String] = []
        var playing = false
        var epoch = 0
        var station: StationQueueKey?
        var transport: TransportState = .stopped
        var resumes = 0
        var nothingQueued: Bool { queue.isEmpty && !playing }
    }

    private let morning = BuiltInStations.morningCalm
    private let late = BuiltInStations.lateNight

    private func seedIDs(_ station: BuiltInStation) -> Set<String> { Set(station.configuration.seeds.map(\.catalogID)) }

    /// True when every queued song came from one of `station`'s own seeds.
    private func isFrom(_ station: BuiltInStation, _ queue: [String]) -> Bool {
        let ids = seedIDs(station)
        return !queue.isEmpty && queue.allSatisfy { song in ids.contains { song.hasPrefix("\($0)-") } }
    }

    private func rig() async -> (StationConfigurationModel, StationQueueFeed<String>, CreatedStationStarter<String>, Player) {
        let model = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .default))),
            consent: StaticIntegrationConsent([:]))
        await model.load()
        let feed = StationQueueFeed<String>(resolver: CatalogStationSeedResolver(catalog: BuiltInFakeCatalog()),
                                            materialize: { $0.map(\.id) },
                                            options: .init(limit: 12, seedSource: .fixed(418)))
        feed.follow(model)
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(5), pollInterval: .milliseconds(1),
                                            fillTimeout: .seconds(5))
        return (model, feed, starter, Player())
    }

    /// The phone row tap and the CarPlay pick: `StationStartFacts.builtInRecipe` applied as the
    /// live recipe, then the shared start path.
    private func tap(_ station: BuiltInStation, _ model: StationConfigurationModel,
                     _ starter: CreatedStationStarter<String>, _ player: Player,
                     trigger: StationOpenTrigger = .userTap) async -> CreatedStationOpenOutcome {
        let recipe = StationStartFacts.builtInRecipe(for: station.id)
        return await starter.open(
            trigger,
            recipeID: station.id,
            available: recipe != nil,
            liveRecipeID: { model.active.seeds == station.configuration.seeds ? station.id : nil },
            authorize: {},
            apply: {
                guard let recipe else { return false }
                await model.applyRecipe(recipe)
                return true
            },
            active: { model.active },
            nothingQueued: { player.nothingQueued },
            playingStation: { player.station },
            switchNow: { await model.applyPendingForStationSwitch() },
            queueEpoch: { player.epoch },
            transport: { player.transport },
            resume: { player.resumes += 1; player.playing = true; player.transport = .playing },
            start: { items in
                player.epoch += 1
                player.queue = items
                player.station = StationQueueKey(model.active)
                player.playing = true
                player.transport = .playing
            },
            append: { first, songs in
                guard player.queue.first == first else { return false }
                player.queue += songs
                return true
            })
    }

    /// Waits on the clock (never a poll count) for the background fill.
    private func waitUntil(_ condition: () -> Bool, within limit: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + limit
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func startMorning(_ model: StationConfigurationModel, _ feed: StationQueueFeed<String>,
                              _ starter: CreatedStationStarter<String>, _ player: Player) async {
        let outcome = await tap(morning, model, starter, player)
        guard case .started = outcome else { return XCTFail("Morning Calm starts, got \(outcome)") }
        await waitUntil { player.queue.count >= 12 }
        XCTAssertTrue(isFrom(morning, player.queue), "\(player.queue)")
        XCTAssertEqual(feed.playingKey, StationQueueKey(morning.configuration))
        await model.setPlaybackActivity(.holdingSong)
    }

    private func assertNowOnLateNight(_ outcome: CreatedStationOpenOutcome, _ model: StationConfigurationModel,
                                      _ feed: StationQueueFeed<String>, _ player: Player, epochBefore: Int,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        guard case .started = outcome else { return XCTFail("Late Night starts now, got \(outcome)", file: file, line: line) }
        XCTAssertEqual(player.epoch, epochBefore + 1, "Morning Calm's queue was replaced once", file: file, line: line)
        XCTAssertTrue(isFrom(late, player.queue), "only Late Night's songs: \(player.queue)", file: file, line: line)
        XCTAssertEqual(model.active.seeds, late.configuration.seeds, "the tap is not held for the boundary", file: file, line: line)
        XCTAssertEqual(feed.playingKey, StationQueueKey(late.configuration), file: file, line: line)
        await waitUntil { player.queue.count >= 12 }
        XCTAssertTrue(isFrom(late, player.queue), "the fill appends Late Night only: \(player.queue)", file: file, line: line)
    }

    func testTheTwoBuiltInsAreDifferentStations() throws {
        let a = try XCTUnwrap(StationQueueKey(morning.configuration))
        let b = try XCTUnwrap(StationQueueKey(late.configuration))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(seedIDs(morning).isDisjoint(with: seedIDs(late)))
    }

    func testTappingLateNightWhileMorningCalmPlaysSwitchesNow() async {
        let (model, feed, starter, player) = await rig()
        await startMorning(model, feed, starter, player)
        XCTAssertEqual(player.transport, .playing)
        let epoch = player.epoch

        let outcome = await tap(late, model, starter, player)
        await assertNowOnLateNight(outcome, model, feed, player, epochBefore: epoch)
    }

    func testTappingLateNightWhileMorningCalmIsPausedSwitchesNow() async {
        let (model, feed, starter, player) = await rig()
        await startMorning(model, feed, starter, player)
        player.playing = false
        player.transport = .paused
        XCTAssertFalse(player.nothingQueued, "paused mid-song still holds Morning Calm's queue")
        let epoch = player.epoch

        let outcome = await tap(late, model, starter, player)
        XCTAssertEqual(player.resumes, 0, "a different station starts; the old one is not resumed")
        await assertNowOnLateNight(outcome, model, feed, player, epochBefore: epoch)
    }

    func testTappingLateNightWhileIdleStartsIt() async {
        let (model, feed, starter, player) = await rig()
        await startMorning(model, feed, starter, player)
        player.queue = []
        player.playing = false
        player.transport = .stopped
        await model.setPlaybackActivity(.idle)
        XCTAssertTrue(player.nothingQueued)
        let epoch = player.epoch

        let outcome = await tap(late, model, starter, player)
        await assertNowOnLateNight(outcome, model, feed, player, epochBefore: epoch)
    }

    func testSwitchingBackToMorningCalmPlaysMorningCalmAgain() async {
        let (model, feed, starter, player) = await rig()
        await startMorning(model, feed, starter, player)
        let epoch = player.epoch
        let switched = await tap(late, model, starter, player)
        await assertNowOnLateNight(switched, model, feed, player, epochBefore: epoch)
        await model.setPlaybackActivity(.holdingSong)

        let back = await tap(morning, model, starter, player)
        guard case .started = back else { return XCTFail("Morning Calm starts again, got \(back)") }
        XCTAssertTrue(isFrom(morning, player.queue), "\(player.queue)")
        XCTAssertEqual(model.active.seeds, morning.configuration.seeds)
        XCTAssertEqual(feed.playingKey, StationQueueKey(morning.configuration))
    }

    func testTappingThePlayingBuiltInChangesNothingAndThePausedOneResumes() async {
        let (model, feed, starter, player) = await rig()
        await startMorning(model, feed, starter, player)
        let queue = player.queue
        let epoch = player.epoch

        let again = await tap(morning, model, starter, player)
        XCTAssertEqual(again, .alreadyPlaying)
        XCTAssertEqual(player.queue, queue)
        XCTAssertEqual(player.epoch, epoch)

        player.playing = false
        player.transport = .paused
        let paused = await tap(morning, model, starter, player)
        XCTAssertEqual(paused, .resumed)
        XCTAssertEqual(player.resumes, 1)
        XCTAssertEqual(player.queue, queue)
        XCTAssertEqual(player.epoch, epoch)
    }

    func testARestoredBuiltInSelectionNeverPlays() async {
        let (model, _, starter, player) = await rig()
        let restored = await tap(late, model, starter, player, trigger: .restore)
        XCTAssertEqual(restored, .restoredOnly)
        XCTAssertEqual(player.epoch, 0)
        XCTAssertTrue(player.queue.isEmpty)
    }

    // MARK: the fast start keeps the station's spacing (#442 scope: "keep station spacing")

    /// Four seeds, one artist each, so the builder can always keep `artistGap` (2) apart.
    private func spacedStation() -> (StationConfiguration, [String: String]) {
        var config = StationConfiguration.default
        config.seeds = ["s1", "s2", "s3", "s4"].map { StationSeed(kind: .artist, catalogID: $0, name: "Seed \($0)") }
        config.reach = .only
        let artists = ["s1": "Artist One", "s2": "Artist Two", "s3": "Artist Three", "s4": "Artist Four"]
        return (config.validated(), artists)
    }

    private func artist(of song: String, _ artists: [String: String]) -> String? {
        artists.first { song.hasPrefix("\($0.key)-") }?.value
    }

    /// The fast-start song plus the background fill is one run of the station: the songs appended
    /// right behind the playing song keep the artist gap from it, for every build seed.
    func testTheFillAppendedBehindTheFirstSongKeepsTheArtistGap() async throws {
        let (config, artists) = spacedStation()
        let gap = StationPoolBuilder.Options().artistGap
        var seam = 0
        for buildSeed in UInt64(0)..<UInt64(40) {
            let feed = StationQueueFeed<String>(
                resolver: CatalogStationSeedResolver(catalog: BuiltInFakeCatalog(artists: artists, perSeed: 8)),
                materialize: { $0.map(\.id) },
                options: .init(limit: 24, seedSource: .fixed(buildSeed)))
            let opener = await feed.firstSong(for: config)
            let first = try XCTUnwrap(opener)
            XCTAssertTrue(feed.fastStartBegan(with: first, active: config))
            let built = await feed.prepare(config)
            XCTAssertEqual(built, .ready(songs: 24))
            let fill = try XCTUnwrap(feed.takeForFill(active: config, after: first))
            XCTAssertFalse(fill.contains(first), "seed \(buildSeed): the playing song is not appended again")

            let run = [first] + fill
            let firstArtist = artist(of: first, artists)
            for song in fill.prefix(gap) where artist(of: song, artists) == firstArtist { seam += 1 }
            // The builder's rule (`StationPoolBuilder.spaced`): the gap holds unless every song
            // still to come would break it (the end of a lopsided pool), never across the seam.
            for i in run.indices.dropFirst() {
                let window = Set(run[max(0, i - gap)..<i].map { artist(of: $0, artists) })
                guard window.contains(artist(of: run[i], artists)) else { continue }
                XCTAssertTrue(run[i...].allSatisfy { window.contains(artist(of: $0, artists)) },
                              "seed \(buildSeed): \(run[i]) within \(gap) of the same artist: \(run.prefix(i + 1))")
            }
        }
        XCTAssertEqual(seam, 0, "a song by the playing song's artist was appended right behind it")
    }

    /// Re-spacing only moves songs: the fill is the same songs the build staged, minus the first.
    func testTheSpacedFillLosesNoSongs() async throws {
        let (config, artists) = spacedStation()
        let feed = StationQueueFeed<String>(
            resolver: CatalogStationSeedResolver(catalog: BuiltInFakeCatalog(artists: artists, perSeed: 8)),
            materialize: { $0.map(\.id) },
            options: .init(limit: 24, seedSource: .fixed(7)))
        let built = await feed.prepare(config)
        XCTAssertEqual(built, .ready(songs: 24))
        let staged = try XCTUnwrap(feed.takeForIdleStart(active: config))
        feed.handOffFinished(.failed)                            // puts the same build back
        let opener = await feed.firstSong(for: config)
        let first = try XCTUnwrap(opener)
        XCTAssertEqual(first, staged.first, "the staged queue's first song opens")
        XCTAssertTrue(feed.fastStartBegan(with: first, active: config))
        let fill = try XCTUnwrap(feed.takeForFill(active: config, after: first))
        XCTAssertEqual(Set(fill), Set(staged.dropFirst()))
        XCTAssertEqual(fill.count, staged.count - 1)
    }
}
