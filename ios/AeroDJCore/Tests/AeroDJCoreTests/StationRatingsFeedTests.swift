import XCTest
@testable import AeroDJCore

/// Song ratings through `StationQueueFeed` (-Nova, PR A): a new ratings revision rebuilds the staged
/// queue but is never a station change, never touches `StationQueueKey`, and never re-opens the
/// show (Echo reviews the re-greet test). Plus Sentinel's pins: ratings are personal context that
/// never reaches the DJ script or a voice.
private actor RatingCalls {
    var related: [StationSeed] = []
    func add(_ seed: StationSeed) { related.append(seed) }
}

private struct RatingFeedCatalog: StationSeedCatalog {
    var calls: RatingCalls? = nil
    private func songs(_ seed: StationSeed, _ tier: String) -> [StationCandidate] {
        (0..<6).map { StationCandidate(track: TrackInfo(id: "\(seed.catalogID)-\(tier)-\($0)", title: "Title \(tier) \($0)",
                                                         artistName: "\(seed.catalogID)-\(tier)-artist-\($0)"),
                                       artistID: "\(seed.catalogID)-\(tier)-aid-\($0)") }
    }
    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "core") }
    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
        await calls?.add(seed)
        return songs(seed, "related")
    }
    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "broad") }
}

private struct SilentVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 1, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class StationRatingsFeedTests: XCTestCase {
    private static let today = 42
    private static func seeds(_ id: String) -> [StationSeed] {
        [StationSeed(kind: .artist, catalogID: id, name: "Artist \(id)", source: .catalog)]
    }
    private static let station = StationConfiguration(seeds: seeds("first"))

    private var book = StationRatingBook()
    private var events: [StationQueueEvent] = []

    private func never(_ song: String, artist: String = "someone", in config: StationConfiguration = station) {
        book.rate(StationRatingEntry(songID: song, artistName: artist, rating: .never, ratedDay: Self.today, origin: .catalog),
                  in: StationRatingScope(recipeID: nil, configuration: config)!, today: Self.today)
    }

    private func feed(catalog: RatingFeedCatalog = RatingFeedCatalog(),
                      biasFor: StationConfiguration = station) -> StationQueueFeed<String> {
        StationQueueFeed<String>(resolver: CatalogStationSeedResolver(catalog: catalog), materialize: { $0.map(\.id) },
                                 options: .init(limit: 12), day: { Self.today },
                                 ratings: { [unowned self] in self.book.bias(recipeID: nil, configuration: biasFor, today: Self.today) },
                                 log: { [unowned self] in self.events.append($0) })
    }

    private func current(_ feed: StationQueueFeed<String>) -> StationRatingRevision {
        book.bias(recipeID: nil, configuration: Self.station, today: Self.today).revision
    }

    // MARK: Revision

    func testARatingRebuildsTheStagedQueueWithoutAStationChange() async {
        let f = feed()
        let built = await f.prepare(Self.station)
        XCTAssertEqual(built, .ready(songs: 12))
        let again = await f.prepare(Self.station)
        XCTAssertEqual(again, .unchanged)
        f.queueStarted(for: Self.station, songCount: 12)
        let keyBefore = f.playingKey

        never("first-core-2")
        XCTAssertNotEqual(f.stagedRatingRevision, current(f), "the staged queue is now stale")
        XCTAssertEqual(StationQueueKey(Self.station), keyBefore, "a rating never touches the key")
        let rebuilt = await f.prepare(Self.station)
        XCTAssertEqual(rebuilt, .ready(songs: 11), "a new revision rebuilds")
        let still = await f.prepare(Self.station)
        XCTAssertEqual(still, .unchanged)
        XCTAssertEqual(f.stagedRatingRevision, current(f))

        events = []
        XCTAssertNil(f.takeForBoundary(active: Self.station, playbackMayStart: true), "not a station change")
        XCTAssertEqual(events, [.keptCurrentQueue(.songBoundary, .sameStation)])
        XCTAssertEqual(f.playingKey, keyBefore)

        let items = f.takeForIdleStart(active: Self.station) ?? []
        XCTAssertEqual(items.count, 11)
        XCTAssertFalse(items.contains("first-core-2"))
    }

    func testABiasMadeForOtherSeedsDoesNothing() async {
        let other = StationConfiguration(seeds: Self.seeds("other"))
        never("first-core-2", in: other)
        let f = feed(biasFor: other)
        _ = await f.prepare(Self.station)
        let items = f.takeForIdleStart(active: Self.station) ?? []
        XCTAssertEqual(items.count, 12)
        XCTAssertTrue(items.contains("first-core-2"), "another station's ratings never land here")
    }

    func testARefillWithStaleRatingsStillHandsOffAndRebuilds() async {
        let f = feed()
        _ = await f.prepare(Self.station)
        f.queueStarted(for: Self.station, songCount: 2)
        never("first-core-2")
        XCTAssertNotEqual(f.stagedRatingRevision, current(f), "the staged queue predates the rating")
        let refill = f.queueForNextSong(after: 0, in: ["q0", "q1"], active: Self.station, playbackMayStart: true, sameSong: ==)
        XCTAssertEqual(refill?.first, "q1", "a rating never strands the station")
        XCTAssertEqual(refill?.count, 12, "the stale queue is handed over screened")
        XCTAssertEqual(refill?.contains("first-core-2"), false, "a just-marked never song never plays, not even once")
        for _ in 0..<200 where f.stagedRatingRevision != current(f) { await Task.yield() }
        XCTAssertEqual(f.stagedRatingRevision, current(f), "the next refill is rebuilt with the rating")
        f.handOffFinished(.started)
        let next = f.queueForNextSong(after: 0, in: ["r0", "r1"], active: Self.station, playbackMayStart: true, sameSong: ==) ?? []
        XCTAssertEqual(next.count, 12)
        XCTAssertFalse(next.contains("first-core-2"))
    }

    func testRatingsChangedRebuildsInTheBackground() async {
        let f = feed()
        _ = await f.prepare(Self.station)
        never("first-related-0")
        f.ratingsChanged(Self.station)
        for _ in 0..<200 where f.stagedRatingRevision != current(f) { await Task.yield() }
        XCTAssertEqual(f.stagedRatingRevision, current(f))
        XCTAssertEqual(f.stagedCount, 11)
    }

    func testTheFeedRemembersCatalogArtistIDsFromItsLastBuild() async {
        let f = feed()
        _ = await f.prepare(Self.station)
        XCTAssertEqual(f.artistID(forSong: "first-core-0"), "first-core-aid-0")
        XCTAssertNil(f.artistID(forSong: "not-built"))
    }

    func testLoveSteersDiscoveryThroughATransientSeedWithoutChangingTheStation() async {
        let calls = RatingCalls()
        let scope = StationRatingScope(recipeID: nil, configuration: Self.station)!
        book.rate(StationRatingEntry(songID: "first-related-0", artistName: "fave", artistID: "fave-id", rating: .love,
                                     ratedDay: Self.today, origin: .catalog), in: scope, today: Self.today)
        book.rate(StationRatingEntry(songID: "mine-0", artistName: "private", artistID: "lib-id", rating: .love,
                                     ratedDay: Self.today, origin: .library), in: scope, today: Self.today)
        let keyBefore = StationQueueKey(Self.station)
        let f = feed(catalog: RatingFeedCatalog(calls: calls))
        _ = await f.prepare(Self.station)
        let asked = await calls.related
        XCTAssertEqual(asked.map(\.catalogID), ["first", "fave-id"], "one lookup for the loved catalog artist, none for library")
        XCTAssertEqual(StationQueueKey(Self.station), keyBefore)
        XCTAssertEqual(Self.station.seeds.map(\.catalogID), ["first"], "never saved as a seed")
    }

    // MARK: No re-greet (Echo): a rating through the real feed and DJ session

    @MainActor
    private final class Player {
        let station: StationConfigurationModel
        let session: DJBreakSession
        let feed: StationQueueFeed<String>
        private(set) var queue: [String] = []

        init(station: StationConfigurationModel, session: DJBreakSession, ratings: @escaping @MainActor () -> StationRatingBias) {
            self.station = station
            self.session = session
            feed = StationQueueFeed<String>(resolver: CatalogStationSeedResolver(catalog: RatingFeedCatalog()),
                                            materialize: { $0.map(\.id) }, options: .init(limit: 12), day: { 42 },
                                            ratings: ratings)
        }

        func tap(_ songs: [String]) async {
            let reservation = session.reserveQueueSetup()
            queue = songs
            feed.queueStarted(for: station.committedDisplayed, songCount: songs.count)
            await session.beginQueueInBackground(reservation, Self.tracks(songs)).value
        }

        @discardableResult
        func boundary(after k: Int) async -> Bool {
            _ = await session.naturalBoundary(afterTrack: k)
            guard let next = feed.queueForNextSong(after: k, in: queue, active: station.active,
                                                   playbackMayStart: true, sameSong: ==) else { return false }
            let reservation = session.reserveQueueSetup()
            queue = next
            await session.beginQueueInBackground(reservation, Self.tracks(next)).value
            feed.handOffFinished(.started)
            return true
        }

        static func tracks(_ ids: [String]) -> [DJTrack] {
            ids.map { DJTrack(id: $0, title: "Song \($0)", artist: "Artist \($0)") }
        }
    }

    private static func mine(_ n: Int) -> [String] { (0..<n).map { "mine-\($0)" } }

    private func rig(seed: UInt64) async -> Player {
        var config = StationConfiguration(genres: ["jazz", "soul"], moods: ["mellow"], commentary: .frequent)
        config.seeds = Self.seeds("first")
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: SilentVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: seed, hour: { 14 })
        await session.start()
        let player = Player(station: station, session: session) { [unowned self, unowned station] in
            self.book.bias(recipeID: nil, configuration: station.committedDisplayed, today: 42)
        }
        _ = await player.feed.prepare(station.committedDisplayed)
        return player
    }

    private func openers(_ p: Player) -> [Int] {
        p.session.testPlannedBreaks.filter { $0.value.shape == .showOpener }.keys.sorted()
    }

    func testARatingThroughTheFeedNeverChangesTheKeyOrReGreets() async {
        for seed in UInt64(0)..<5 {
            book = StationRatingBook()
            let label = "seed \(seed)"
            let p = await rig(seed: seed)
            await p.tap(Self.mine(12))
            XCTAssertEqual(openers(p), [p.session.plannedBoundaries.first ?? -1], "\(label): the station opens the show")
            let playing = (openers(p).first ?? 0) + 1
            await p.session.songStarted(index: playing, remaining: .seconds(1))
            let kept = openers(p)
            let keyBefore = StationQueueKey(p.station.committedDisplayed)

            // Rate two station songs: never, and love.
            let scope = StationRatingScope(recipeID: nil, configuration: p.station.committedDisplayed)!
            book.rate(StationRatingEntry(songID: "first-core-1", artistName: "first-core-artist-1", rating: .never,
                                         ratedDay: 42, origin: .catalog), in: scope, today: 42)
            book.rate(StationRatingEntry(songID: "first-related-5", artistName: "first-related-artist-5",
                                         artistID: "first-related-aid-5", rating: .love, ratedDay: 42, origin: .catalog),
                      in: scope, today: 42)
            p.feed.ratingsChanged(p.station.committedDisplayed)
            // The rebuild runs in the background (a song's length in the app); wait for it.
            let revision = book.bias(recipeID: nil, configuration: p.station.committedDisplayed, today: 42).revision
            for _ in 0..<500 where p.feed.stagedRatingRevision != revision { await Task.yield() }
            XCTAssertEqual(p.feed.stagedRatingRevision, revision, "\(label): rebuilt with the ratings")

            let keyAfter = StationQueueKey(p.station.committedDisplayed)
            XCTAssertEqual(keyAfter, keyBefore, "\(label): the key is unchanged")
            XCTAssertEqual(keyAfter?.seeds, keyBefore?.seeds, "\(label): the seed part #362 compares is unchanged")
            XCTAssertEqual(p.station.committedDisplayed.seeds, Self.seeds("first"), "\(label): no loved artist became a seed")

            let handedOff = await p.boundary(after: playing)
            XCTAssertFalse(handedOff, "\(label): a rating is not a station change")
            XCTAssertEqual(openers(p), kept, "\(label): no new opener in the kept plan")

            // The refill: rebuilt with the ratings, the same station, no opener.
            let k = p.queue.count - 2
            await p.session.songStarted(index: k, remaining: .seconds(1))
            _ = await p.feed.prepare(p.station.active)
            let refilled = await p.boundary(after: k)
            XCTAssertTrue(refilled, "\(label): the station refills")
            XCTAssertFalse(p.queue.contains("first-core-1"), "\(label): the never-rated song is gone")
            XCTAssertTrue(p.queue.contains("first-related-5"), label)
            XCTAssertEqual(openers(p), [], "\(label): the refill does not re-greet")
            await p.tap(Self.mine(12))
            XCTAssertEqual(openers(p), [], "\(label): nor does the next tap")
            await p.session.stop()
        }
    }

    // MARK: Screening the hand-off (Fry/Orion ruling)

    func testTheLastSongOfThePlayingQueueIsScreenedToo() async {
        let f = feed()
        _ = await f.prepare(Self.station)
        f.queueStarted(for: Self.station, songCount: 2)
        never("q1")
        let refill = f.queueForNextSong(after: 0, in: ["q0", "q1"], active: Self.station, playbackMayStart: true, sameSong: ==)
        XCTAssertEqual(refill?.count, 12)
        XCTAssertEqual(refill?.contains("q1"), false, "the playing queue's last song was marked never: not handed over")
        XCTAssertEqual(refill?.first, "first-core-0")
    }

    func testTiredSongsStillHeldAreScreenedAndEasedBackOnesAreNot() async {
        let f = feed()
        _ = await f.prepare(Self.station)
        let scope = StationRatingScope(recipeID: nil, configuration: Self.station)!
        book.rate(StationRatingEntry(songID: "first-core-3", artistName: "a", rating: .tired, ratedDay: Self.today,
                                     origin: .catalog), in: scope, today: Self.today)
        book.rate(StationRatingEntry(songID: "first-core-4", artistName: "b", rating: .tired,
                                     ratedDay: Self.today - StationRatingTuning.tiredHoldDays, origin: .catalog),
                  in: scope, today: Self.today)
        let items = f.takeForIdleStart(active: Self.station) ?? []
        XCTAssertFalse(items.contains("first-core-3"), "held tired: out")
        XCTAssertTrue(items.contains("first-core-4"), "past the hold: back (ranked lower in the next build)")
    }

    func testAStaleStagedQueueIsScreenedAtAStationSwitchAndRebuilt() async {
        let other = StationConfiguration(seeds: Self.seeds("other"))
        let f = feed(biasFor: other)
        _ = await f.prepare(other)
        f.queueStarted(for: Self.station, songCount: 12)
        book.rate(StationRatingEntry(songID: "other-core-0", artistName: "x", rating: .never, ratedDay: Self.today,
                                     origin: .catalog), in: StationRatingScope(recipeID: nil, configuration: other)!,
                  today: Self.today)
        let items = f.takeForBoundary(active: other, playbackMayStart: true) ?? []
        XCTAssertEqual(items.count, 11)
        XCTAssertFalse(items.contains("other-core-0"))
        f.handOffFinished(.failed)
        let retried = f.takeForIdleStart(active: other) ?? []
        XCTAssertFalse(retried.contains("other-core-0"), "a failed start's restored queue is screened again")
    }

    func testAScreenedHandOffThatLeavesNothingKeepsTheQueueAndRebuilds() async {
        let f = StationQueueFeed<String>(resolver: CatalogStationSeedResolver(catalog: RatingFeedCatalog()),
                                         materialize: { $0.prefix(1).map(\.id) }, options: .init(limit: 12),
                                         day: { Self.today },
                                         ratings: { [unowned self] in self.book.bias(recipeID: nil, configuration: Self.station, today: Self.today) })
        _ = await f.prepare(Self.station)
        XCTAssertEqual(f.stagedCount, 1)
        never("first-core-0")
        XCTAssertNil(f.takeForIdleStart(active: Self.station), "nothing allowed is left: today's not-ready path")
    }

    func testExcludedUpcomingFindsOnlyLaterExcludedSongs() async {
        let f = feed()
        never("q1"); never("q3")
        XCTAssertEqual(f.excludedUpcoming(in: ["q0", "q1", "q2", "q3"], after: 0, active: Self.station), [1, 3])
        XCTAssertEqual(f.excludedUpcoming(in: ["q0", "q1", "q2", "q3"], after: 1, active: Self.station), [3],
                       "the playing song is never reported")
        XCTAssertEqual(f.excludedUpcoming(in: ["q0", "q1"], after: 0, active: StationConfiguration(genres: ["jazz"])), [],
                       "a tags-only station has no ratings")
    }

    private struct Song: Identifiable, Sendable { let id: String }
    private struct Numbered: Identifiable, Sendable { let id: Int }

    func testTheDefaultSongIDReadsStringsAndStringIdentifiables() {
        XCTAssertEqual(StationQueueSongID.of("s1"), "s1")
        XCTAssertEqual(StationQueueSongID.of(Song(id: "s2")), "s2", "the app's Track is Identifiable by its song ID")
        XCTAssertNil(StationQueueSongID.of(Numbered(id: 3)))
        XCTAssertNil(StationQueueSongID.of(3))
    }

    func testAnInjectedSongIDScreensAnyItem() async {
        let f = StationQueueFeed<Song>(resolver: CatalogStationSeedResolver(catalog: RatingFeedCatalog()),
                                       materialize: { $0.map { Song(id: "x:" + $0.id) } }, options: .init(limit: 12),
                                       day: { Self.today },
                                       ratings: { [unowned self] in self.book.bias(recipeID: nil, configuration: Self.station, today: Self.today) },
                                       songID: { String($0.id.dropFirst(2)) })
        _ = await f.prepare(Self.station)
        never("first-core-5")
        let items = f.takeForIdleStart(active: Self.station) ?? []
        XCTAssertEqual(items.count, 11)
        XCTAssertFalse(items.map(\.id).contains("x:first-core-5"))
        XCTAssertTrue(items.map(\.id).contains("x:first-core-4"))
    }

    /// The scenario that failed on 3 of 5 seeds before the ruling: the refill comes while the rating's
    /// rebuild may still be running (locally it is still stale on all 5). No wait: the hand-off is screened, so the never song is gone on
    /// every seed, no planned break names it (Echo), and nothing re-greets.
    func testARefillDuringTheRebuildNeverPlaysOrNamesTheNeverSong() async {
        for seed in UInt64(0)..<5 {
            book = StationRatingBook()
            let label = "seed \(seed)"
            let p = await rig(seed: seed)
            await p.tap(Self.mine(12))
            let playing = (openers(p).first ?? 0) + 1
            await p.session.songStarted(index: playing, remaining: .seconds(1))
            let scope = StationRatingScope(recipeID: nil, configuration: p.station.committedDisplayed)!
            book.rate(StationRatingEntry(songID: "first-core-1", artistName: "first-core-artist-1", rating: .never,
                                         ratedDay: 42, origin: .catalog), in: scope, today: 42)
            book.rate(StationRatingEntry(songID: "first-related-5", artistName: "first-related-artist-5",
                                         artistID: "first-related-aid-5", rating: .love, ratedDay: 42, origin: .catalog),
                      in: scope, today: 42)
            p.feed.ratingsChanged(p.station.committedDisplayed)
            let handedOff = await p.boundary(after: playing)
            XCTAssertFalse(handedOff, "\(label): a rating is not a station change")

            let k = p.queue.count - 2
            await p.session.songStarted(index: k, remaining: .seconds(1))
            let refilled = await p.boundary(after: k)
            XCTAssertTrue(refilled, "\(label): the station refills, never stranded")
            XCTAssertFalse(p.queue.contains("first-core-1"), "\(label): the never song is not handed over")
            let named = p.session.testPlannedBreaks.values.flatMap(\.cues).filter { $0.text.contains("first-core-1") }
            XCTAssertEqual(named.count, 0, "\(label): no planned break names the screened song")
            XCTAssertEqual(openers(p), [], "\(label): the refill does not re-greet")
            await p.session.stop()
        }
    }

    // MARK: Privacy (Sentinel): personal context under mayLeaveDevice

    /// Ratings are personal context: a cue carrying their attribution never leaves the device, even
    /// a plain transition that `.presenter` would let through.
    func testRatingsAttributionIsPersonalContextThatMayNotLeaveTheDevice() {
        let cue = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "That was Song 1 by Artist 1.",
                               estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        XCTAssertTrue(VoiceRenderer.mayLeaveDevice(cue, attribution: .presenter), "control: the same cue as presenter may")
        let attribution = StationRatingBias.narrationAttribution(itemID: UUID())
        guard case .personalContext = attribution else { return XCTFail("ratings are personal context") }
        XCTAssertFalse(VoiceRenderer.mayLeaveDevice(cue, attribution: attribution))
    }

    /// No path from ratings into the DJ script or a voice: DJ/ and Voice/ never name the types.
    func testDJAndVoiceNeverReferenceRatings() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AeroDJCore")
        var scanned = 0
        for folder in ["DJ", "Voice"] {
            let dir = sources.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                for type in ["StationRating", "SongRating", "StationAffinityArtist"] {
                    XCTAssertFalse(text.contains(type), "\(folder)/\(name) must not reference \(type)")
                }
                scanned += 1
            }
        }
        XCTAssertGreaterThan(scanned, 5, "the scan found the folders")
    }

    /// A break planned with a populated rating store is byte-for-byte the break planned without one.
    func testBreaksAreIdenticalWithAndWithoutRatings() async {
        func plan(populated: Bool) async -> [String] {
            book = StationRatingBook()
            if populated {
                let scope = StationRatingScope(recipeID: nil, configuration: Self.station)!
                for (i, rating) in [SongRating.love, .never, .like, .tired].enumerated() {
                    book.rate(StationRatingEntry(songID: "mine-\(i)", artistName: "Artist mine-\(i)", artistID: "aid-\(i)",
                                                 rating: rating, ratedDay: 42, origin: .catalog), in: scope, today: 42)
                }
            }
            let p = await rig(seed: 3)
            await p.tap(Self.mine(12))
            let breaks = p.session.testPlannedBreaks
            let lines = breaks.keys.sorted().flatMap { k -> [String] in
                let b = breaks[k]!
                return b.cues.map { "\(k)|\($0.kind)|\($0.text)|\(String(describing: b.attributions[$0.id]))" }
            }
            await p.session.stop()
            return lines
        }
        let without = await plan(populated: false)
        let with = await plan(populated: true)
        XCTAssertFalse(without.isEmpty)
        XCTAssertEqual(with, without)
    }
}
