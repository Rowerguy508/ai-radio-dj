import XCTest
@testable import AeroDJCore

/// #362 P1 (lead, 13:37Z): the show opener replays only when the live path really starts a new
/// station queue. A committed station edit goes through `StationQueueFeed` (prepare, then the
/// natural-boundary `queueForNextSong`) into `DJBreakSession`, wired the way the app's
/// `StationQueuePlayer` wires them: a hand-off starts with `reserveQueueSetup` +
/// `beginQueueInBackground`, a tap reports `feed.queueStarted(for:)` too. No test here calls
/// `DJBreakSession.queueStarted` directly. Deterministic: song starts sit inside the boundary
/// margin (nothing renders), station edits are awaited through `testOnStationChangeHandled`, and
/// the feed's build is awaited through `prepare` (the call `follow` makes on a key change). -Fry
private struct FeedCatalog: StationSeedCatalog {
    private func songs(_ seed: StationSeed, _ tier: String) -> [StationCandidate] {
        (0..<6).map { StationCandidate(track: TrackInfo(id: "\(seed.catalogID)-\(tier)-\($0)", title: "Title \($0)",
                                                         artistName: "\(seed.catalogID)-artist-\($0)")) }
    }
    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "core") }
    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "related") }
    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "broad") }
}

private struct QuietVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 1, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class OpenerThroughStationQueueFeedTests: XCTestCase {
    /// The app's player glue (`StationQueuePlayer`), minus MusicKit: same calls, same order.
    @MainActor
    private final class Player {
        let station: StationConfigurationModel
        let session: DJBreakSession
        let feed: StationQueueFeed<String>
        private(set) var queue: [String] = []
        private(set) var queueStarts = 0

        init(station: StationConfigurationModel, session: DJBreakSession) {
            self.station = station
            self.session = session
            feed = StationQueueFeed<String>(resolver: CatalogStationSeedResolver(catalog: FeedCatalog()),
                                            materialize: { $0.map(\.id) }, options: .init(limit: 12), day: { 42 })
        }

        /// A song tap (`PlaybackActions`): reserve, play (MusicKit reports `onQueueReplaced`, so the
        /// feed records the committed station), then break prep in the background.
        func tap(_ songs: [String]) async {
            let reservation = session.reserveQueueSetup()
            queue = songs
            feed.queueStarted(for: station.committedDisplayed, songCount: songs.count)
            await session.beginQueueInBackground(reservation, Self.tracks(songs)).value
            queueStarts += 1
        }

        /// `stationQueueAtBoundary`: after the break, the feed decides; a returned queue starts like
        /// `StationQueuePlayer.start` (own queue: no `feed.queueStarted`), then `handOffFinished`.
        @discardableResult
        func boundary(after k: Int) async -> Bool {
            _ = await session.naturalBoundary(afterTrack: k)
            guard let next = feed.queueForNextSong(after: k, in: queue, active: station.active,
                                                   playbackMayStart: true, sameSong: ==) else { return false }
            let reservation = session.reserveQueueSetup()
            queue = next
            await session.beginQueueInBackground(reservation, Self.tracks(next)).value
            feed.handOffFinished(.started)
            queueStarts += 1
            return true
        }

        /// What `follow` does on a committed change, awaited.
        func feedFollows() async { _ = await feed.prepare(station.committedDisplayed) }

        static func tracks(_ ids: [String]) -> [DJTrack] {
            ids.map { DJTrack(id: $0, title: "Song \($0)", artist: "Artist \($0)") }
        }
    }

    private static func seeds(_ id: String) -> [StationSeed] {
        [StationSeed(kind: .artist, catalogID: id, name: "Artist \(id)", source: .catalog)]
    }

    private static func mine(_ n: Int) -> [String] { (0..<n).map { "mine-\($0)" } }

    private func rig(seed: UInt64, tagsOnly: Bool = false) async -> Player {
        var config = StationConfiguration(genres: ["jazz", "soul"], moods: ["mellow"], commentary: .frequent)
        if !tagsOnly { config.seeds = Self.seeds("first") }
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: QuietVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: seed, hour: { 14 })
        await session.start()
        let player = Player(station: station, session: session)
        await player.feedFollows()
        return player
    }

    private func openers(_ p: Player) -> [Int] {
        p.session.testPlannedBreaks.filter { $0.value.shape == .showOpener }.keys.sorted()
    }

    /// Starts on the station with a tap; its opener airs (song 1 is playing).
    private func tapAndAirTheOpener(_ p: Player, _ label: String, file: StaticString = #filePath, line: UInt = #line) async {
        await p.tap(Self.mine(12))
        XCTAssertEqual(openers(p), [p.session.plannedBoundaries.first ?? -1], "\(label): the station opens the show",
                       file: file, line: line)
        await p.session.songStarted(index: (openers(p).first ?? 0) + 1, remaining: .seconds(1))
    }

    /// Saves `edit` (committed now: no song is holding) and waits for the session to handle it.
    private func save(_ p: Player, _ edit: () async -> Void) async {
        await edit()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            p.session.testOnStationChangeHandled = { _ in
                p.session.testOnStationChangeHandled = nil
                done.resume()
            }
            Task { @MainActor in await p.station.saveChanges() }
        }
        XCTAssertFalse(p.station.hasPendingChanges)
        await p.feedFollows()
    }

    /// Plays on to the boundary before the queue's last song: the feed refills the same station.
    @discardableResult
    private func refill(_ p: Player, _ label: String, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let k = p.queue.count - 2
        await p.session.songStarted(index: k, remaining: .seconds(1))
        _ = await p.feed.prepare(p.station.active)
        let starts = p.queueStarts
        let handedOff = await p.boundary(after: k)
        if StationQueueKey(p.station.active) != nil {
            XCTAssertTrue(handedOff, "\(label): a seeded station refills", file: file, line: line)
            XCTAssertEqual(p.feed.pendingHandOffTrigger, nil, file: file, line: line)
            XCTAssertEqual(p.queueStarts, starts + 1, file: file, line: line)
        } else {
            XCTAssertFalse(handedOff, "\(label): no key, no refill (the feed's fallback)", file: file, line: line)
        }
        return handedOff
    }

    // A seeds change: the feed hands off the new station's queue at the next boundary, and that
    // queue opens the show, once. Also from a tags-only station to a seeded one.
    func testASeedsChangeThroughTheFeedReGreetsOnce() async {
        for tagsOnly in [false, true] {
            for seed in UInt64(0)..<5 {
                let label = "seed \(seed) tagsOnly \(tagsOnly)"
                let p = await rig(seed: seed, tagsOnly: tagsOnly)
                await tapAndAirTheOpener(p, label)
                let playing = (openers(p).first ?? 0) + 1

                await save(p) { await p.station.setSeeds(Self.seeds("second")) }
                let handedOff = await p.boundary(after: playing)
                XCTAssertTrue(handedOff, "\(label): the feed starts the new station's queue")
                XCTAssertTrue(p.session.testQueueTrackIDs.allSatisfy { $0.hasPrefix("second-") }, label)
                XCTAssertEqual(openers(p).count, 1, "\(label): the new station opens the show once")
                XCTAssertEqual(openers(p).first, p.session.plannedBoundaries.first, "\(label): as its first break")

                // Its opener airs; a re-queue on the same station does not open it again.
                await p.session.songStarted(index: (openers(p).first ?? 0) + 1, remaining: .seconds(1))
                await p.tap(Self.mine(12))
                XCTAssertEqual(openers(p), [], "\(label): a same-station re-queue does not re-greet")
                await p.session.stop()
            }
        }
    }

    // A genre-only edit: genres are not in the feed's key, so the feed starts no new queue at the
    // boundary, and neither its refill (seeded) nor the next tap re-greets. Seeded and tags-only.
    func testAGenreEditThroughTheFeedNeverReGreets() async {
        for tagsOnly in [false, true] {
            for seed in UInt64(0)..<5 {
                let label = "seed \(seed) tagsOnly \(tagsOnly)"
                let p = await rig(seed: seed, tagsOnly: tagsOnly)
                await tapAndAirTheOpener(p, label)
                let playing = (openers(p).first ?? 0) + 1
                let kept = openers(p)

                await save(p) { await p.station.setGenres(["house", "disco"]) }
                XCTAssertEqual(p.station.committedDisplayed.genres, ["house", "disco"])
                let handedOff = await p.boundary(after: playing)
                XCTAssertFalse(handedOff, "\(label): the feed keeps the playing queue")
                XCTAssertEqual(p.queueStarts, 1, label)
                XCTAssertEqual(openers(p), kept, "\(label): no new opener in the kept plan")

                let refilled = await refill(p, label)
                XCTAssertEqual(openers(p), refilled ? [] : kept, "\(label): the refill does not re-greet")
                await p.tap(Self.mine(12))
                XCTAssertEqual(openers(p), [], "\(label): nor does the next tap")
                await p.session.stop()
            }
        }
    }

    // A mood-only edit: same as genres, the feed's key is unchanged and nothing re-greets.
    func testAMoodEditThroughTheFeedNeverReGreets() async {
        for tagsOnly in [false, true] {
            for seed in UInt64(0)..<5 {
                let label = "seed \(seed) tagsOnly \(tagsOnly)"
                let p = await rig(seed: seed, tagsOnly: tagsOnly)
                await tapAndAirTheOpener(p, label)
                let playing = (openers(p).first ?? 0) + 1
                let kept = openers(p)

                await save(p) { await p.station.setMoods(["upbeat", "late night"]) }
                XCTAssertEqual(p.station.committedDisplayed.moods, ["upbeat", "late night"])
                let handedOff = await p.boundary(after: playing)
                XCTAssertFalse(handedOff, "\(label): the feed keeps the playing queue")
                let refilled = await refill(p, label)
                XCTAssertEqual(openers(p), refilled ? [] : kept, "\(label): the refill does not re-greet")
                await p.tap(Self.mine(12))
                XCTAssertEqual(openers(p), [], "\(label): nor does the next tap")
                await p.session.stop()
            }
        }
    }
}
