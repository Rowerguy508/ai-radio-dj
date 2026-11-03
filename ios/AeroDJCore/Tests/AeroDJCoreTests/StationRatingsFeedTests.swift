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

    /// Echo (PR B): the refill's last song is the playing queue's next song. The break at this boundary
    /// has already introduced it, so it is kept even when marked never since; only the staged
    /// station songs are screened. (Before PR B it was dropped, and a different song played.)
    func testTheLastSongOfThePlayingQueueIsKeptForItsIntro() async {
        let f = feed()
        _ = await f.prepare(Self.station)
        f.queueStarted(for: Self.station, songCount: 2)
        never("q1")
        never("first-core-3")
        let refill = f.queueForNextSong(after: 0, in: ["q0", "q1"], active: Self.station, playbackMayStart: true, sameSong: ==)
        XCTAssertEqual(refill?.first, "q1", "the introduced song plays: the break and the song agree")
        XCTAssertEqual(refill?.count, 12, "[q1] + 11 staged songs")
        XCTAssertEqual(refill?.contains("first-core-3"), false, "the staged station songs are still screened")
    }

    // MARK: Fry nit 1 (PR B): a failed hand-off restores the screened list

    func testAFailedRefillRestoresTheScreenedList() async {
        let f = feed()
        _ = await f.prepare(Self.station)
        f.queueStarted(for: Self.station, songCount: 2)
        never("first-core-2")
        let refill = f.queueForNextSong(after: 0, in: ["q0", "q1"], active: Self.station, playbackMayStart: true, sameSong: ==)
        XCTAssertEqual(refill?.count, 12)
        f.handOffFinished(.failed)
        XCTAssertEqual(f.stagedCount, 11, "restored without the never song, not the unscreened build of 12")
        let retried = f.takeForIdleStart(active: Self.station) ?? []
        XCTAssertFalse(retried.contains("first-core-2"))
    }

    func testAFailedStartRestoresTheScreenedList() async {
        let f = feed()
        _ = await f.prepare(Self.station)
        never("first-core-4")
        let items = f.takeForIdleStart(active: Self.station) ?? []
        XCTAssertEqual(items.count, 11)
        f.handOffFinished(.failed)
        XCTAssertEqual(f.stagedCount, 11, "restored without the never song, not the unscreened build of 12")
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

    // MARK: Fry nit 2 (PR B): a queued song rated never is never named or aired by a break

    /// True when `text` names `mine-<j>` (not `mine-<j>0`).
    private static func names(_ text: String, _ j: Int) -> Bool {
        let needle = "mine-\(j)"
        var rest = text[...]
        while let r = rest.range(of: needle) {
            if r.upperBound == rest.endIndex || !rest[r.upperBound].isNumber { return true }
            rest = rest[r.upperBound...]
        }
        return false
    }

    /// The player's rating path (`StationQueuePlayer.ratingChanged`, PR B) through the real feed and
    /// DJ session: `excludedUpcoming` finds the queued never song, `StationRatingBreakDrop` gives the
    /// boundaries on both sides of it, and `songCut` drops them (the skip path). Then the queue plays
    /// out: no break that airs names the song, and no break still planned to air names it.
    func testARatedQueuedSongIsNeverNamedOrAiredByABreak() async {
        var covered = 0
        for seed in UInt64(0)..<5 {
            book = StationRatingBook()
            let label = "seed \(seed)"
            let p = await rig(seed: seed)
            await p.tap(Self.mine(12))
            let playing = (openers(p).first ?? 0) + 1
            await p.session.songStarted(index: playing, remaining: .seconds(1))
            // A later break that introduces its next song ("up next"): that song is the one rated.
            guard let b = p.session.testPlannedBreaks.keys.sorted().first(where: { k in
                k > playing && k + 1 < 12
                    && p.session.testPlannedBreaks[k]!.cues.contains { Self.names($0.text, k + 1) }
            }) else { continue }
            let j = b + 1
            covered += 1

            let scope = StationRatingScope(recipeID: nil, configuration: p.station.committedDisplayed)!
            book.rate(StationRatingEntry(songID: "mine-\(j)", artistName: "Artist mine-\(j)", rating: .never,
                                         ratedDay: 42, origin: .catalog), in: scope, today: 42)
            p.feed.ratingsChanged(p.station.committedDisplayed)
            let upcoming = p.feed.excludedUpcoming(in: p.queue, after: playing, active: p.station.active)
            XCTAssertEqual(upcoming, [j], label)
            let dropped = StationRatingBreakDrop.boundaries(forUpcoming: upcoming, playing: playing)
            XCTAssertEqual(dropped, [j - 1, j], label)
            for k in dropped { await p.session.songCut(afterTrack: k) }

            // Play the queue out, letting every planned break render before its boundary.
            var aired = 0
            for k in (playing + 1)..<11 {
                await p.session.songStarted(index: k, remaining: .seconds(240))
                // Dropped ones too (they never become ready), so the test fails if the drop is removed.
                if p.session.testPlannedBreaks[k] != nil {
                    for _ in 0..<200 {
                        if await p.session.breakIsReady(afterTrack: k) { break }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }
                let handed = await p.session.naturalBoundary(afterTrack: k)
                if dropped.contains(k) { XCTAssertNil(handed, "\(label): the break at \(k) was dropped") }
                guard let handed else { continue }
                aired += 1
                let spoken = handed.clips.map { String(decoding: $0.audio.data, as: UTF8.self) }.joined(separator: " ")
                XCTAssertFalse(Self.names(spoken, j), "\(label): the break at \(k) names the never song")
            }
            XCTAssertGreaterThan(aired, 0, "\(label): other breaks still air")
            let stillPlanned = p.session.testPlannedBreaks.filter { !dropped.contains($0.key) && $0.key > playing }
            let naming = stillPlanned.values.flatMap(\.cues).filter { Self.names($0.text, j) }
            XCTAssertEqual(naming.count, 0, "\(label): no break left to air names the never song")
            await p.session.stop()
        }
        XCTAssertGreaterThan(covered, 0, "at least one seed plans an intro for a later song")
    }

    /// #388 (Echo's #387 N2, -Nova): the rating path narrows instead of cutting. With the queued
    /// never song excluded (`DJBreakSession.songsExcluded`), the breaks on both sides of it still
    /// air, minus exactly the cues attributed to it; no cue that airs names it, and no briefing or
    /// other cue is lost. An Undo (an empty set) puts the cues back.
    func testAnExcludedQueuedSongLosesOnlyTheCuesThatNameIt() async {
        var covered = 0
        var keptAround = 0
        var undone = 0
        var narrowedRows = 0
        for seed in UInt64(0)..<24 {
            book = StationRatingBook()
            let label = "seed \(seed)"
            let p = await rig(seed: seed)
            await p.tap(Self.mine(12))
            let playing = (openers(p).first ?? 0) + 1
            await p.session.songStarted(index: playing, remaining: .seconds(1))
            guard let b = p.session.testPlannedBreaks.keys.sorted().first(where: { k in
                k > playing && k + 1 < 12
                    && p.session.testPlannedBreaks[k]!.cues.contains { Self.names($0.text, k + 1) }
            }) else { continue }
            let j = b + 1
            covered += 1
            let undo = seed % 2 == 1
            var rows: [Int: ExcludedCueCounts] = [:]
            p.session.onExcludedCuesDropped = { k, counts in
                XCTAssertNil(rows[k], "\(label): one row per boundary")
                rows[k] = counts
            }
            p.session.songsExcluded(["mine-\(j)"])
            if undo { p.session.songsExcluded([]) }
            XCTAssertEqual(p.session.excludedSongIDs, undo ? [] : ["mine-\(j)"], label)
            for k in (playing + 1)..<11 {
                await p.session.songStarted(index: k, remaining: .seconds(240))
                if p.session.testPlannedBreaks[k] != nil {
                    for _ in 0..<200 {
                        if await p.session.breakIsReady(afterTrack: k) { break }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }
                let planned = p.session.testPlannedBreaks[k]
                let handed = await p.session.naturalBoundary(afterTrack: k)
                guard let handed else { continue }
                let spoken = handed.clips.map { String(decoding: $0.audio.data, as: UTF8.self) }.joined(separator: " ")
                if undo {
                    if k == b { XCTAssertTrue(Self.names(spoken, j), "\(label): Undo puts the intro back"); undone += 1 }
                    XCTAssertNil(rows[k], "\(label): nothing narrowed after an Undo, no row")
                    continue
                }
                XCTAssertFalse(Self.names(spoken, j), "\(label): the break at \(k) names the excluded song")
                if let planned, k == j - 1 || k == j {
                    // Exactly the cues attributed to the song went; every other planned cue that rendered airs.
                    let naming = Set(planned.cues.filter { cue in
                        guard case .trackMetadata(let ids, _)? = planned.attributions[cue.id] else { return false }
                        return ids.contains("mine-\(j)")
                    }.map(\.id))
                    XCTAssertTrue(handed.cues.allSatisfy { !naming.contains($0.id) }, label)
                    XCTAssertEqual(handed.cues.filter(\.isContent).count, planned.cues.filter(\.isContent).count,
                                   "\(label): no briefing cue is omitted")
                    // Echo's #396 room N1: one counts-only row when (and only when) cues went.
                    if naming.isEmpty {
                        XCTAssertNil(rows[k], label)
                    } else if let row = rows[k] {
                        XCTAssertGreaterThan(row.dropped, 0, label)
                        XCTAssertLessThanOrEqual(row.dropped, naming.count, label)
                        XCTAssertEqual(row.briefing, 0, "\(label): a briefing item never names a song")
                        XCTAssertEqual(row.kept, handed.cues.count, label)
                        narrowedRows += 1
                    } else {
                        XCTFail("\(label): the break at \(k) lost cues without a row")
                    }
                    keptAround += 1
                }
            }
            await p.session.stop()
        }
        XCTAssertGreaterThan(covered, 1)
        XCTAssertGreaterThan(keptAround, 0, "a break next to the excluded song still airs")
        XCTAssertGreaterThan(undone, 0)
        XCTAssertGreaterThan(narrowedRows, 0, "a narrowed break leaves a counts-only row")
    }

    /// The exclusions belong to the queue they were set for: a new queue starts with none.
    func testANewQueueStartsWithNoExcludedSongs() async {
        book = StationRatingBook()
        let p = await rig(seed: 0)
        await p.tap(Self.mine(12))
        p.session.songsExcluded(["mine-4"])
        await p.tap(Self.mine(10))
        XCTAssertEqual(p.session.excludedSongIDs, [])
        await p.session.stop()
    }

    // MARK: Purge-all (Sentinel's #396 N1): nothing the old ratings steered outlives it

    /// Saves work; deleting fails while `failing` is on.
    private actor PurgeStore: StationRatingStore {
        private var book = StationRatingBook()
        private var failing: Bool
        init(failing: Bool) { self.failing = failing }
        func load() async throws -> StationRatingBook { book }
        func save(_ book: StationRatingBook) async throws { self.book = book }
        func deleteAll() async throws {
            if failing { throw StationRatingStoreError.deleteFailed }
            book = StationRatingBook()
        }
    }

    private func purgeRig(_ ratings: StationRatingsModel, rebuilds: @escaping @MainActor () -> Void = {}) async -> Player {
        let p = await rig(seed: 0)
        let station = p.station
        // The app's wiring: the same model steers the feed and is reset on purge.
        let player = Player(station: station, session: p.session) { [unowned station] in
            ratings.bias(recipeID: nil, configuration: station.committedDisplayed)
        }
        ratings.resetOnPurge(session: p.session) { [unowned player, unowned station] in
            rebuilds()
            player.feed.ratingsChanged(station.committedDisplayed)
        }
        _ = await player.feed.prepare(station.committedDisplayed)
        return player
    }

    private func revision(_ ratings: StationRatingsModel, _ p: Player) -> StationRatingRevision {
        ratings.bias(recipeID: nil, configuration: p.station.committedDisplayed).revision
    }

    private func settle(_ ratings: StationRatingsModel, _ p: Player) async {
        for _ in 0..<400 where p.feed.stagedRatingRevision != revision(ratings, p) { await Task.yield() }
    }

    func testAPurgeAllClearsTheExcludedSongsAndRebuildsTheStagedQueue() async {
        for failing in [false, true] {
            let label = failing ? "delete fails" : "delete works"
            let ratings = StationRatingsModel(store: PurgeStore(failing: failing), today: { 42 },
                                              defaults: UserDefaults(suiteName: "ratings-\(UUID().uuidString)")!)
            await ratings.load()
            let p = await purgeRig(ratings)
            let scope = StationRatingScope(recipeID: nil, configuration: p.station.committedDisplayed)!
            ratings.rate(.never, song: StationRatedSong(songID: "first-core-2", artistName: "someone"), in: scope)
            p.feed.ratingsChanged(p.station.committedDisplayed)
            await settle(ratings, p)
            XCTAssertEqual(p.feed.stagedCount, 11, label)
            p.session.songsExcluded(["first-core-2"])
            let staleRevision = p.feed.stagedRatingRevision

            let purged = await ratings.purgeAll()
            XCTAssertEqual(purged, !failing, label)
            XCTAssertEqual(p.session.excludedSongIDs, [], "\(label): the DJ session forgets the excluded song")
            await settle(ratings, p)
            XCTAssertNotEqual(p.feed.stagedRatingRevision, staleRevision, label)
            XCTAssertEqual(p.feed.stagedRatingRevision, revision(ratings, p), "\(label): rebuilt without the old ratings")
            XCTAssertEqual(p.feed.stagedCount, 12, "\(label): the never song is no longer screened out")
            await p.session.stop()
        }
    }

    func testALaunchWithAPendingPurgeClearsTheExcludedSongsBeforeItsRetry() async {
        let store = PurgeStore(failing: true)
        let defaults = UserDefaults(suiteName: "ratings-\(UUID().uuidString)")!
        let first = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        await first.load()
        await first.purgeAll()

        let relaunched = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        var rebuilds = 0
        let p = await purgeRig(relaunched) { rebuilds += 1 }
        p.session.songsExcluded(["first-core-2"])
        await relaunched.load()
        XCTAssertEqual(relaunched.loadState, .purgePending)
        XCTAssertEqual(p.session.excludedSongIDs, [])
        XCTAssertEqual(rebuilds, 1, "the pending-purge path rebuilds the staged queue too")
        await p.session.stop()
    }

    func testOnlyAPurgeRunsTheReset() async {
        let ratings = StationRatingsModel(store: PurgeStore(failing: false), today: { 42 },
                                          defaults: UserDefaults(suiteName: "ratings-\(UUID().uuidString)")!)
        var rebuilds = 0
        let p = await purgeRig(ratings) { rebuilds += 1 }
        await ratings.load()
        let scope = StationRatingScope(recipeID: nil, configuration: p.station.committedDisplayed)!
        ratings.rate(.never, song: StationRatedSong(songID: "first-core-2", artistName: "someone"), in: scope)
        await ratings.clearAll()   // Settings: SongRatingController calls ratingsChanged itself
        XCTAssertEqual(rebuilds, 0, "a plain load, rating or Settings clear is not a purge")
        await ratings.purgeAll()
        await ratings.purgeAll()
        XCTAssertEqual(rebuilds, 2, "once per purge-all")
        await p.session.stop()
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
