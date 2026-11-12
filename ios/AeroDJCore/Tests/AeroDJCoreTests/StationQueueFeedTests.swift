import XCTest
@testable import AeroDJCore

// Station queue feed (-Atlas): the built pool becomes the live queue at a natural boundary.

private struct Offline: Error {}

private func seed(_ kind: StationSeedKind, _ id: String, _ source: StationSeedSource = .catalog) -> StationSeed {
    StationSeed(kind: kind, catalogID: id, name: "Secret \(id)", source: source)
}

private func station(_ seeds: [StationSeed], reach: StationReach = .related, discovery: Double = 0.3) -> StationConfiguration {
    var c = StationConfiguration.default
    c.seeds = seeds
    c.reach = reach
    c.discovery = discovery
    return c.validated()
}

/// Songs are "<seed>-<tier>-<n>" by artist "<seed>-artist-<tier>-<n % 3>". Records what was asked.
private actor QueueFakeCatalog: StationSeedCatalog {
    var failing = false
    private(set) var asked: [String] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var holdNext = false
    /// #454: hold every call until `release()` (nothing resolves, not even a first song).
    private var holdAll = false

    func setFailing(_ value: Bool) { failing = value }
    func holdNextCall() { holdNext = true }
    func holdAllCalls() { holdAll = true }
    /// #454: hold every call for one tier ("core", "related", "broad"), e.g. the full build behind
    /// a station's first song, which needs only "core".
    func holdTier(_ tier: String) { heldTiers.insert(tier) }
    /// #454: hold every call for one seed (by catalog id).
    func holdSeed(_ id: String) { heldSeeds.insert(id) }
    func release() {
        holdAll = false
        heldTiers = []
        heldSeeds = []
        let held = gates
        gates = []
        held.forEach { $0.resume() }
    }
    var isHolding: Bool { !gates.isEmpty }
    private var heldTiers: Set<String> = []
    private var heldSeeds: Set<String> = []

    private func songs(_ seed: StationSeed, _ tier: String, _ limit: Int) async throws -> [StationCandidate] {
        asked.append("\(tier):\(seed.source.rawValue)")
        if holdNext || holdAll || heldTiers.contains(tier) || heldSeeds.contains(seed.catalogID) {
            holdNext = false
            await withCheckedContinuation { gates.append($0) }
        }
        if failing { throw Offline() }
        return (0..<min(limit, 8)).map { n in
            StationCandidate(track: TrackInfo(id: "\(seed.catalogID)-\(tier)-\(n)", title: "Title \(n)",
                                              artistName: "\(seed.catalogID)-artist-\(tier)-\(n % 3)"))
        }
    }

    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { try await songs(seed, "core", limit) }
    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { try await songs(seed, "related", limit) }
    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { try await songs(seed, "broad", limit) }
}

@MainActor
private final class QueueEventRecorder {
    var events: [StationQueueEvent] = []
}

@MainActor
private func makeFeed(_ catalog: QueueFakeCatalog, recorder: QueueEventRecorder = QueueEventRecorder(), limit: Int = 10,
                      playable: @escaping @Sendable (StationCandidate) -> Bool = { _ in true },
                      refillLead: Int = 3,
                      recentlyPlayed: @escaping @MainActor () -> Set<String> = { [] }) -> StationQueueFeed<String> {
    StationQueueFeed<String>(
        resolver: CatalogStationSeedResolver(catalog: catalog),
        materialize: { picks in picks.filter(playable).map(\.id) },
        options: .init(limit: limit, seedSource: .perDay),
        day: { 42 },
        recentlyPlayed: recentlyPlayed,
        refillLead: refillLead,
        log: { recorder.events.append($0) })
}

// No class-level @MainActor: Linux XCTest discovery (Swift 6.2) aborts casting a @MainActor sync test.
// Sync tests run on the main thread and assume isolation; async tests are @MainActor per test. -Atlas
final class StationQueueKeyTests: XCTestCase {
    func testNoSeedsIsNotAStation() {
        MainActor.assumeIsolated {
            XCTAssertNil(StationQueueKey(.default))
        }
    }

    func testNamesAndFloatNoiseDoNotCountButMusicSettingsDo() {
        MainActor.assumeIsolated {
            let a = station([seed(.artist, "1")])
            var renamed = a
            renamed.seeds[0].name = "Other"
            var noisy = a
            noisy.discovery = 0.3000000001
            XCTAssertEqual(StationQueueKey(a), StationQueueKey(renamed))
            XCTAssertEqual(StationQueueKey(a), StationQueueKey(noisy))
            XCTAssertNotEqual(StationQueueKey(a), StationQueueKey(station([seed(.artist, "1")], reach: .broad)))
            XCTAssertNotEqual(StationQueueKey(a), StationQueueKey(station([seed(.artist, "1")], discovery: 0.7)))
            XCTAssertNotEqual(StationQueueKey(a), StationQueueKey(station([seed(.artist, "2")])))
            var talk = a
            talk.commentary = .chatty
            XCTAssertEqual(StationQueueKey(a), StationQueueKey(talk), "DJ tuning never rebuilds the queue")
        }
    }

    func testLibrarySeedKeyUsesTheClampedReach() throws {
        try MainActor.assumeIsolated {
            let lib = try XCTUnwrap(StationQueueKey(station([seed(.playlist, "p", .library)], reach: .broad)))
            XCTAssertEqual(lib.reach, .only)
        }
    }

    func testShuffleSeedIsStablePerStationAndDay() throws {
        try MainActor.assumeIsolated {
            let key = try XCTUnwrap(StationQueueKey(station([seed(.artist, "1")])))
            let again = try XCTUnwrap(StationQueueKey(station([seed(.artist, "1")])))
            XCTAssertEqual(key.shuffleSeed(day: 1), again.shuffleSeed(day: 1))
            XCTAssertNotEqual(key.shuffleSeed(day: 1), key.shuffleSeed(day: 2))
            let other = try XCTUnwrap(StationQueueKey(station([seed(.artist, "2")])))
            XCTAssertNotEqual(key.shuffleSeed(day: 1), other.shuffleSeed(day: 1))
        }
    }
}

@MainActor
final class StationQueueFeedTests: XCTestCase {
    private let old = station([seed(.artist, "old")])
    private let new = station([seed(.artist, "a"), seed(.artist, "b")])

    func testBuildsTheSameQueueAsThePoolBuilderAndHandsItOffAtTheBoundary() async throws {
        let catalog = QueueFakeCatalog()
        let feed = makeFeed(catalog)
        feed.queueStarted(for: old)
        let outcome1 = await feed.prepare(new)
        XCTAssertEqual(outcome1, .ready(songs: 10))

        let pool = await CatalogStationSeedResolver(catalog: QueueFakeCatalog()).resolve(seeds: new.seeds, reach: new.reach)
        let key = try XCTUnwrap(StationQueueKey(new))
        let expected = StationPoolBuilder.build(pool, configuration: new,
                                                options: .init(limit: 10, shuffleSeed: key.shuffleSeed(day: 42))).map(\.id)
        let queue = try XCTUnwrap(feed.takeForBoundary(active: new, playbackMayStart: true))
        XCTAssertEqual(queue, expected)
        XCTAssertEqual(feed.playingKey, key)
        XCTAssertNil(feed.stagedCount, "handed off once")
        XCTAssertNil(feed.takeForBoundary(active: new, playbackMayStart: true), "now the playing station")
    }

    func testOrderIsDeterministicAcrossFeeds() async throws {
        let one = makeFeed(QueueFakeCatalog())
        let two = makeFeed(QueueFakeCatalog())
        _ = await one.prepare(new)
        _ = await two.prepare(new)
        XCTAssertEqual(one.takeForIdleStart(active: new), two.takeForIdleStart(active: new))
    }

    func testAMixedQueueKeepsArtistsApartAndOpensWithEachSeed() async throws {
        let feed = makeFeed(QueueFakeCatalog(), limit: 12)
        _ = await feed.prepare(new)
        let queue = try XCTUnwrap(feed.takeForIdleStart(active: new))
        XCTAssertEqual(queue.count, 12)
        XCTAssertEqual(Set(queue).count, 12, "no repeats")
        XCTAssertTrue(queue.contains { $0.hasPrefix("a-") } && queue.contains { $0.hasPrefix("b-") })
    }

    func testNotReadyAtTheBoundaryKeepsTheCurrentQueueAndRetries() async throws {
        let catalog = QueueFakeCatalog()
        let recorder = QueueEventRecorder()
        let feed = makeFeed(catalog, recorder: recorder)
        feed.queueStarted(for: old)
        XCTAssertNil(feed.takeForBoundary(active: new, playbackMayStart: true))
        XCTAssertEqual(recorder.events.last, .keptCurrentQueue(.songBoundary, .notReady))
        // The retry builds in the background for the next boundary.
        for _ in 0..<50 where feed.stagedCount == nil { await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(feed.stagedCount, 10)
        XCTAssertNotNil(feed.takeForBoundary(active: new, playbackMayStart: true))
    }

    func testFailedCatalogFetchIsAnEmptyPoolAndNothingIsHandedOut() async {
        let catalog = QueueFakeCatalog()
        await catalog.setFailing(true)
        let recorder = QueueEventRecorder()
        let feed = makeFeed(catalog, recorder: recorder)
        feed.queueStarted(for: old)
        let outcome2 = await feed.prepare(new)
        XCTAssertEqual(outcome2, .skipped(.emptyPool))
        XCTAssertEqual(recorder.events, [.notBuilt(.emptyPool, failedLookups: 4)])
        XCTAssertNil(feed.stagedCount)
        XCTAssertNil(feed.takeForBoundary(active: new, playbackMayStart: true), "current queue keeps playing")
        XCTAssertNil(feed.takeForIdleStart(active: new), "Play keeps its existing message")
    }

    func testUnplayableSongsAreNeverAnEmptyQueue() async {
        let feed = makeFeed(QueueFakeCatalog(), playable: { _ in false })
        feed.queueStarted(for: old)
        let outcome3 = await feed.prepare(new)
        XCTAssertEqual(outcome3, .skipped(.unplayable))
        XCTAssertNil(feed.takeForBoundary(active: new, playbackMayStart: true))
    }

    func testPartlyPlayableKeepsOrderAndDropsTheRest() async throws {
        let feed = makeFeed(QueueFakeCatalog(), playable: { !$0.id.hasSuffix("-1") })
        _ = await feed.prepare(new)
        let queue = try XCTUnwrap(feed.takeForIdleStart(active: new))
        XCTAssertFalse(queue.contains { $0.hasSuffix("-1") })
        XCTAssertFalse(queue.isEmpty)
    }

    func testTagsOnlyStationHasNothingToBuild() async {
        let recorder = QueueEventRecorder()
        let feed = makeFeed(QueueFakeCatalog(), recorder: recorder)
        feed.queueStarted(for: old)
        let outcome4 = await feed.prepare(.default)
        XCTAssertEqual(outcome4, .skipped(.noSeeds))
        XCTAssertNil(feed.takeForBoundary(active: .default, playbackMayStart: true))
        XCTAssertEqual(recorder.events.last, .keptCurrentQueue(.songBoundary, .noStation))
    }

    func testTheListenersOwnQueueIsNotReplacedForTheSameStation() async {
        let feed = makeFeed(QueueFakeCatalog())
        _ = await feed.prepare(new)
        feed.queueStarted(for: new)   // a search tap while this station is on
        XCTAssertNil(feed.takeForBoundary(active: new, playbackMayStart: true))
        XCTAssertEqual(feed.stagedCount, 10, "kept for an idle Play later")
    }

    func testUnknownQueueStartIsNeverReplacedOnAGuess() async {
        let feed = makeFeed(QueueFakeCatalog())
        _ = await feed.prepare(new)
        XCTAssertNil(feed.takeForBoundary(active: new, playbackMayStart: true))
    }

    func testAHeldStartKeepsTheBoundaryRules() async {
        let recorder = QueueEventRecorder()
        let feed = makeFeed(QueueFakeCatalog(), recorder: recorder)
        feed.queueStarted(for: old)
        _ = await feed.prepare(new)
        XCTAssertNil(feed.takeForBoundary(active: new, playbackMayStart: false))
        XCTAssertEqual(recorder.events.last, .keptCurrentQueue(.songBoundary, .playbackHeld))
        XCTAssertNotNil(feed.takeForBoundary(active: new, playbackMayStart: true), "next boundary")
    }

    func testANewerStationWins() async throws {
        let catalog = QueueFakeCatalog()
        let feed = makeFeed(catalog)
        await catalog.holdNextCall()
        let first = Task { await feed.prepare(new) }
        for _ in 0..<200 where !(await catalog.isHolding) { await Task.yield() }
        let third = station([seed(.genre, "21")])
        let outcome5 = await feed.prepare(third)
        XCTAssertEqual(outcome5, .ready(songs: 10))
        await catalog.release()
        let outcome6 = await first.value
        XCTAssertEqual(outcome6, .skipped(.superseded))
        XCTAssertEqual(feed.stagedKey, StationQueueKey(third))
    }

    func testRecentlyPlayedSongsAreLeftOut() async throws {
        let feed = makeFeed(QueueFakeCatalog(), recentlyPlayed: { ["a-core-0", "b-core-0"] })
        _ = await feed.prepare(new)
        let queue = try XCTUnwrap(feed.takeForIdleStart(active: new))
        XCTAssertFalse(queue.contains("a-core-0") || queue.contains("b-core-0"))
    }

    func testLibrarySeedsPlayOnlyThemselves() async throws {
        let catalog = QueueFakeCatalog()
        let feed = makeFeed(catalog)
        let library = station([seed(.playlist, "mine", .library)], reach: .broad, discovery: 0.7)
        _ = await feed.prepare(library)
        let queue = try XCTUnwrap(feed.takeForIdleStart(active: library))
        XCTAssertTrue(queue.allSatisfy { $0.hasPrefix("mine-core-") }, "only the playlist's own songs")
        let asked = await catalog.asked
        XCTAssertEqual(asked, ["core:library"], "never expanded through related or broad lookups")
    }

    func testLogsCarryNoSeedSongOrArtistText() async throws {
        let recorder = QueueEventRecorder()
        let feed = makeFeed(QueueFakeCatalog(), recorder: recorder)
        feed.queueStarted(for: old)
        _ = await feed.prepare(new)
        _ = feed.takeForBoundary(active: new, playbackMayStart: true)
        _ = feed.takeForBoundary(active: new, playbackMayStart: true)
        let catalog = QueueFakeCatalog()
        await catalog.setFailing(true)
        let failing = makeFeed(catalog, recorder: recorder)
        _ = await failing.prepare(new)
        XCTAssertEqual(recorder.events.count, 4)
        for line in recorder.events.map(\.diagnostics) {
            for banned in ["Secret", "Title", "artist", "a-", "b-", "old"] {
                XCTAssertFalse(line.contains(banned), "\(line) contains \(banned)")
            }
        }
    }
}

/// The boundary rules come from `StationConfigurationModel`; the feed only follows them.
@MainActor
final class StationQueueFeedBoundaryTests: XCTestCase {
    private func makeStation(active: StationConfiguration) async -> StationConfigurationModel {
        let model = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: active))),
            consent: StaticIntegrationConsent([:]))
        await model.load()
        return model
    }

    private func waitForStaged(_ feed: StationQueueFeed<String>, _ key: StationQueueKey?) async throws {
        for _ in 0..<200 where feed.stagedKey != key { await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(feed.stagedKey, key)
    }

    func testAMidSongChangePlaysAfterThisSongNotBefore() async throws {
        let old = station([seed(.artist, "old")])
        let new = station([seed(.artist, "a")], reach: .broad, discovery: 0.7)
        let model = await makeStation(active: old)
        await model.setPlaybackActivity(.holdingSong)
        let feed = makeFeed(QueueFakeCatalog())
        feed.queueStarted(for: model.committedDisplayed)   // listener tapped a song on the old station
        feed.follow(model)
        await model.applyRecipe(StationRecipe(name: "New", configuration: new))
        XCTAssertTrue(model.hasPendingChanges, "mid-song: waits for the boundary")
        try await waitForStaged(feed, StationQueueKey(new))   // built ahead, from the committed (pending) station

        // Mid-song nothing changes: the active station is still the old one.
        XCTAssertNil(feed.takeForBoundary(active: model.active, playbackMayStart: true))

        await model.handle(.songBoundary(afterTrack: 0))
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["a"])
        let queue = try XCTUnwrap(feed.takeForBoundary(active: model.active, playbackMayStart: true))
        XCTAssertTrue(queue.allSatisfy { $0.hasPrefix("a-") })
    }

    func testAnIdleCreateIsReadyForPlay() async throws {
        let model = await makeStation(active: .default)
        let feed = makeFeed(QueueFakeCatalog())
        feed.follow(model)
        let created = station([seed(.genre, "21")])
        await model.applyRecipe(StationRecipe(name: "Rock", configuration: created))
        XCTAssertFalse(model.hasPendingChanges, "idle: applies now")
        try await waitForStaged(feed, StationQueueKey(created))
        XCTAssertEqual(feed.takeForIdleStart(active: model.active)?.count, 10)
    }

    // P0 build 25 (-Atlas): a queue tapped on a station with no seeds is a reported start, so the
    // first created station replaces it at the next boundary (it used to stay on "sameStation").
    func testP0FirstCreatedStationTakesOverAtTheBoundary() async throws {
        let model = await makeStation(active: .default)          // owner's station: no seeds
        await model.setPlaybackActivity(.holdingSong)
        let feed = makeFeed(QueueFakeCatalog())
        feed.queueStarted(for: model.committedDisplayed)        // search tap on the seedless station
        feed.follow(model)
        let created = station([seed(.artist, "a")])
        await model.applyRecipe(StationRecipe(name: "A Radio", configuration: created))
        try await waitForStaged(feed, StationQueueKey(created))
        await model.handle(.songBoundary(afterTrack: 0))
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["a"])
        XCTAssertNotNil(feed.takeForBoundary(active: model.active, playbackMayStart: true),
                        "P0: the created station should replace the seedless queue at the boundary")
    }

    func testATapAfterSavingAChangeKeepsTheTappedSongs() async throws {
        let old = station([seed(.artist, "old")])
        let new = station([seed(.artist, "a")])
        let model = await makeStation(active: old)
        await model.setPlaybackActivity(.holdingSong)
        let feed = makeFeed(QueueFakeCatalog())
        feed.follow(model)
        await model.applyRecipe(StationRecipe(name: "New", configuration: new))
        try await waitForStaged(feed, StationQueueKey(new))
        feed.queueStarted(for: model.committedDisplayed)   // tapped a search song after the save
        await model.handle(.songBoundary(afterTrack: 0))
        XCTAssertNil(feed.takeForBoundary(active: model.active, playbackMayStart: true))
    }

    func testDJOnlyEditsDoNotRebuild() async throws {
        let old = station([seed(.artist, "old")])
        let model = await makeStation(active: old)
        let catalog = QueueFakeCatalog()
        let feed = makeFeed(catalog)
        feed.follow(model)
        try await waitForStaged(feed, StationQueueKey(old))
        let before = await catalog.asked.count
        var chatty = old
        chatty.commentary = .chatty
        await model.applyRecipe(StationRecipe(name: "Chatty", configuration: chatty))
        for _ in 0..<20 { await Task.yield() }
        let after = await catalog.asked.count
        XCTAssertEqual(before, after)
    }
}

// Refill at the queue's end (-Atlas). Echo's conditions, one suite each:
// (1) it lands before the last song starts, so the DJ plans that song's break via `queueStarted`;
// (2) on any failure nothing is handed out and today's stop path runs unchanged;
// (3) no break ever names a song that is not actually queued.

private let refillStation = station([seed(.artist, "1")])

@MainActor
private func until(_ condition: @MainActor () -> Bool, _ message: String = "",
                   file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), message, file: file, line: line)
}

@MainActor
private func refillFeed(_ catalog: QueueFakeCatalog = QueueFakeCatalog(),
                        recorder: QueueEventRecorder = QueueEventRecorder()) async -> StationQueueFeed<String> {
    let feed = makeFeed(catalog, recorder: recorder)
    feed.queueStarted(for: refillStation)
    _ = await feed.prepare(refillStation)
    return feed
}

@MainActor
private func next(_ feed: StationQueueFeed<String>, after finished: Int, in queue: [String],
                  active: StationConfiguration = refillStation, mayStart: Bool = true) -> [String]? {
    feed.queueForNextSong(after: finished, in: queue, active: active, playbackMayStart: mayStart, sameSong: ==)
}

/// Unique, non-overlapping titles so a break's text can be checked for every queued song.
private func djTrack(_ id: String) -> DJTrack { DJTrack(id: id, title: "Song <\(id)>", artist: "Artist <\(id)>") }

@MainActor
final class StationQueueRefillLandsBeforeTheLastSongTests: XCTestCase {
    func testTheRefillIsHandedOutOnlyAtTheBoundaryBeforeTheLastSong() async throws {
        let recorder = QueueEventRecorder()
        let feed = await refillFeed(recorder: recorder)
        let queue = ["mine-0", "mine-1", "mine-2"]
        XCTAssertNil(next(feed, after: 0, in: queue), "song 1 is not the last: it loads as today")
        XCTAssertGreaterThan(feed.stagedCount ?? 0, 0, "nothing was used up early")

        let refill = try XCTUnwrap(next(feed, after: 1, in: queue), "song 2 is last: refill before it starts")
        XCTAssertEqual(refill.first, "mine-2", "the last song still plays next, now as the refill's first song")
        XCTAssertGreaterThan(refill.count, 1, "the station continues after it")
        XCTAssertNil(feed.stagedCount, "used up")
        XCTAssertEqual(recorder.events.last, .handedOff(.refill, songs: refill.count))
    }

    func testOnceTheLastSongHasStartedThereIsNoRefill() async {
        let feed = await refillFeed()
        XCTAssertNil(next(feed, after: 2, in: ["a", "b", "c"]), "after the last song: today's stop path")
        XCTAssertGreaterThan(feed.stagedCount ?? 0, 0)
    }

    func testTheLastSongsBreakIsPlannedThroughTheNormalQueueStartedReplan() async throws {
        let feed = await refillFeed()
        let refill = try XCTUnwrap(next(feed, after: 1, in: ["a", "b", "c"]))
        let r = await djRig()
        // The tap path's queueStarted, exactly as for any new queue (StationQueuePlayer uses TapPlaySequence).
        await r.session.queueStarted(refill.map(djTrack))
        XCTAssertEqual(r.session.testQueueTrackIDs, refill, "the DJ plans the queue the player plays")
        XCTAssertEqual(r.session.plannedBoundaries.first, 0, "the old last song (now index 0) has its break planned")
    }

    func testAShortQueueStartsBuildingItsRefillWhenItBegins() async {
        let catalog = QueueFakeCatalog()
        let feed = makeFeed(catalog)
        feed.queueStarted(for: refillStation, songCount: 2)
        await until({ feed.stagedKey == StationQueueKey(refillStation) }, "built in the background")
        XCTAssertNotNil(next(feed, after: 0, in: ["a", "b"]), "ready before the last song")
    }

    func testTheNextRefillIsBuiltAsTheRefillNearsItsEnd() async throws {
        let feed = await refillFeed()
        let refill = try XCTUnwrap(next(feed, after: 1, in: ["a", "b", "c"]))
        XCTAssertNil(feed.stagedKey)
        XCTAssertNil(next(feed, after: refill.count - 4, in: refill), "three left to load: not the last yet")
        await until({ feed.stagedKey == StationQueueKey(refillStation) }, "the next refill is building")
    }
}

// No class-level @MainActor: Linux XCTest discovery (Swift 6.2) aborts casting a @MainActor sync test.
// Sync tests run on the main thread and assume isolation; async tests are @MainActor per test. -Atlas
final class StationQueueRefillFailureKeepsTodaysStopTests: XCTestCase {
    private let queue = ["a", "b", "c"]

    func testNothingBuiltYetHandsOutNothing() {
        let queue = queue
        MainActor.assumeIsolated {
            let recorder = QueueEventRecorder()
            let feed = makeFeed(QueueFakeCatalog(), recorder: recorder)
            feed.queueStarted(for: refillStation)
            XCTAssertNil(next(feed, after: 1, in: queue), "the last song loads and the station stops after it, as today")
            XCTAssertEqual(recorder.events.last, .keptCurrentQueue(.refill, .notReady))
        }
    }

    @MainActor func testAFailedCatalogFetchHandsOutNothing() async {
        let catalog = QueueFakeCatalog()
        await catalog.setFailing(true)
        let recorder = QueueEventRecorder()
        let feed = makeFeed(catalog, recorder: recorder)
        feed.queueStarted(for: refillStation)
        let outcome = await feed.prepare(refillStation)
        XCTAssertEqual(outcome, .skipped(.emptyPool))
        XCTAssertNil(next(feed, after: 1, in: queue))
        XCTAssertEqual(recorder.events.last, .keptCurrentQueue(.refill, .notReady))
    }

    @MainActor func testATagsOnlyStationHasNoRefill() async {
        let recorder = QueueEventRecorder()
        let feed = makeFeed(QueueFakeCatalog(), recorder: recorder)
        feed.queueStarted(for: .default)
        XCTAssertNil(next(feed, after: 1, in: queue, active: .default))
        XCTAssertEqual(recorder.events.last, .keptCurrentQueue(.refill, .noStation))
    }

    @MainActor func testAHeldStartHandsOutNothingAndKeepsTheBuiltQueue() async {
        let recorder = QueueEventRecorder()
        let feed = await refillFeed(recorder: recorder)
        XCTAssertNil(next(feed, after: 1, in: queue, mayStart: false))
        XCTAssertEqual(recorder.events.last, .keptCurrentQueue(.refill, .playbackHeld))
        XCTAssertGreaterThan(feed.stagedCount ?? 0, 0)
    }

    @MainActor func testStationSongsAllAlreadyQueuedHandOutNothing() async throws {
        let feed = await refillFeed()
        let builtCopy = try XCTUnwrap(next(feed, after: 1, in: queue)).dropFirst()
        let feed2 = await refillFeed()
        XCTAssertNil(next(feed2, after: builtCopy.count, in: ["x"] + builtCopy + ["last"]),
                     "nothing new to add: the last song loads as today")
    }

    @MainActor func testAOneSongQueueHasNoBoundaryBeforeItsLastSong() async {
        let feed = await refillFeed()
        XCTAssertNil(next(feed, after: 0, in: ["only"]), "documented: a single tapped song ends as today")
    }
}

@MainActor
final class StationQueueRefillNamesOnlyQueuedSongsTests: XCTestCase {
    func testEveryBreakNamesOnlyTheSongsAroundItInTheQueue() async throws {
        let feed = await refillFeed()
        let refill = try XCTUnwrap(next(feed, after: 1, in: ["a", "b", "c"]))
        XCTAssertEqual(Set(refill).count, refill.count, "no song is queued twice")
        let r = await djRig()
        let tracks = refill.map(djTrack)
        await r.session.queueStarted(tracks)
        let boundaries = r.session.plannedBoundaries
        XCTAssertFalse(boundaries.isEmpty)
        var introduced: [Int] = []
        for k in boundaries {
            await r.session.songStarted(index: k, remaining: .seconds(180))
            await until({ if case .ready = r.dj.studioState { true } else { false } }, "break \(k) ready")
            let handed = await r.session.naturalBoundary(afterTrack: k)
            let prepared = try XCTUnwrap(handed, "break \(k)")
            let text = prepared.cues.map(\.text).joined(separator: " ")
            let named = tracks.indices.filter { text.contains(tracks[$0].title) || text.contains(tracks[$0].artist) }
            XCTAssertTrue(Set(named).isSubset(of: [k, k + 1]), "break \(k) names only its own and the next queued song")
            XCTAssertLessThan(k + 1, tracks.count, "a break always has a queued next song")
            if named.contains(k + 1) { introduced.append(k) }
            r.session.playbackStarted(afterTrack: k)
            r.session.playbackFinished(afterTrack: k)
        }
        XCTAssertTrue(boundaries.contains(0), "including the old last song's break, naming the first station song")
        XCTAssertFalse(introduced.isEmpty, "the check is not vacuous: breaks do name the next queued song")
    }
}

@MainActor
private struct DJRig {
    let session: DJBreakSession
    let dj: DJPresentationStore
}

@MainActor
private func djRig() async -> DJRig {
    var config = refillStation
    config.commentary = .frequent
    let station = StationConfigurationModel(
        store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config.validated()))),
        consent: StaticIntegrationConsent([:]))
    await station.load()
    let preparer = DJBreakPreparer(renderer: djRenderer(), userID: "u", stationID: "s", cadence: config.cadence())
    let dj = DJPresentationStore()
    let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
    await session.start()
    return DJRig(session: session, dj: dj)
}

// Created-station start (-Atlas, Orion's decision on #213, reworked for #454): a user tap starts
// the station at once on its first song (the rest is appended), switches now while something else
// plays, is a no-op on the station already playing, and restore never starts.
@MainActor
final class CreatedStationStartTests: XCTestCase {
    /// Stands in for the player: what is queued, what started, and whether authorization was asked.
    @MainActor private final class FakePlayer {
        var queue: [String] = [] { didSet { epoch += 1 } }
        var playing = false
        var authorizations = 0
        var applies = 0
        /// Stands in for `StudioPresentationModel.lastAppliedRecipeID`.
        var liveRecipe: UUID?
        var starts: [[String]] = []
        var appended: [[String]] = []
        /// #454: bumps whenever the queue is replaced (a start, or a song tapped meanwhile).
        private(set) var epoch = 0
        /// #454: the station whose queue the starter played.
        var station: StationQueueKey?
        var nothingQueued: Bool { queue.isEmpty && !playing }
        /// How many times `open()` has read `nothingQueued`. The first read is the pre-loop idle
        /// check, so a count of 1 or more means `open()` is past it and in the wait loop.
        var nothingQueuedReads = 0
    }

    private func makeStation(active: StationConfiguration) async -> StationConfigurationModel {
        let model = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: active))),
            consent: StaticIntegrationConsent([:]))
        await model.load()
        return model
    }

    private let created = station([seed(.artist, "a")])

    private func open(_ trigger: StationOpenTrigger, _ starter: CreatedStationStarter<String>,
                      _ model: StationConfigurationModel, _ player: FakePlayer,
                      recipe: StationConfiguration? = nil, id: UUID? = nil) async -> CreatedStationOpenOutcome {
        let config = recipe ?? created
        return await starter.open(trigger,
                                  recipeID: id,
                                  liveRecipeID: { player.liveRecipe },
                                  authorize: { player.authorizations += 1 },
                                  apply: {
                                      player.applies += 1
                                      await model.applyRecipe(StationRecipe(name: "A Radio", configuration: config))
                                      player.liveRecipe = id
                                      return true
                                  },
                                  active: { model.active },
                                  nothingQueued: {
                                      player.nothingQueuedReads += 1
                                      return player.nothingQueued
                                  },
                                  playingStation: { player.station },
                                  switchNow: { await model.applyPendingForStationSwitch() },
                                  queueEpoch: { player.epoch },
                                  start: { items in
                                      player.starts.append(items)
                                      player.queue = items
                                      player.station = StationQueueKey(model.active)
                                      player.playing = true
                                  },
                                  append: { first, songs in
                                      guard player.queue.first == first else { return false }
                                      player.appended.append(songs)
                                      player.queue += songs
                                      return true
                                  })
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testAnIdleTapWithNothingQueuedStartsTheCreatedStation() async throws {
        let model = await makeStation(active: .default)
        let feed = makeFeed(QueueFakeCatalog())
        feed.follow(model)
        let player = FakePlayer()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(2), pollInterval: .milliseconds(1))

        let outcome = await open(.userTap, starter, model, player)

        guard case .started = outcome else { return XCTFail("expected a start, got \(outcome)") }
        // #454: the start may be the whole staged queue or the first song with the rest appended;
        // either way the station's queue is there and was started exactly once.
        await waitFor { player.queue.count >= 10 }
        XCTAssertGreaterThanOrEqual(player.queue.count, 10)
        XCTAssertEqual(Set(player.queue).count, player.queue.count, "no song twice")
        XCTAssertEqual(player.starts.count, 1, "one start; the rest is appended, never a second queue")
        XCTAssertEqual(player.authorizations, 1)
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["a"])
        XCTAssertEqual(feed.playingKey, StationQueueKey(created))
    }

    // #454 reverses #213 for a row tap: a tap while playing switches now, not at the boundary.
    func testATapWhilePlayingSwitchesToTheStationNow() async throws {
        let model = await makeStation(active: .default)
        await model.setPlaybackActivity(.holdingSong)
        let feed = makeFeed(QueueFakeCatalog())
        feed.queueStarted(for: model.committedDisplayed)       // a song tapped on the seedless station
        feed.follow(model)
        let player = FakePlayer()
        player.queue = ["tapped"]
        player.playing = true
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(2), pollInterval: .milliseconds(1))

        let outcome = await open(.userTap, starter, model, player)
        guard case .started = outcome else { return XCTFail("switches now, got \(outcome)") }
        XCTAssertEqual(player.starts.count, 1, "the station starts now, mid-song")
        XCTAssertFalse(player.queue.contains("tapped"), "the old queue is replaced")
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["a"], "a row tap applies now, not at the boundary")
        XCTAssertEqual(feed.playingKey, StationQueueKey(created))
    }

    func testRestoreNeverAuthorizesAppliesOrStarts() async throws {
        let model = await makeStation(active: .default)
        let feed = makeFeed(QueueFakeCatalog())
        feed.follow(model)
        let player = FakePlayer()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(2), pollInterval: .milliseconds(1))

        let outcome = await open(.restore, starter, model, player)
        XCTAssertEqual(outcome, .restoredOnly)
        XCTAssertEqual(player.authorizations, 0)
        XCTAssertEqual(player.starts, [])
        XCTAssertEqual(model.active.seeds, [], "restore applies nothing")
    }

    // #454: the first song no longer waits for the whole queue (this test used to assert that
    // nothing starts before the queue exists). While every catalog call is held nothing can start;
    // once the calls run, the tap starts, at most one start.
    func testATapBeforeAnythingResolvesStartsOnceASongIsReadyIfStillIdle() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdAllCalls()
        let model = await makeStation(active: .default)
        let feed = makeFeed(catalog)
        feed.follow(model)
        let player = FakePlayer()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(5), pollInterval: .milliseconds(1))

        let tap = Task { await open(.userTap, starter, model, player) }
        for _ in 0..<500 { if await catalog.isHolding { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let holding = await catalog.isHolding
        XCTAssertTrue(holding, "the catalog is held")
        XCTAssertEqual(player.starts, [], "nothing starts before any song exists")
        await catalog.release()

        let outcome = await tap.value
        guard case .started(_, let waited) = outcome else { return XCTFail("expected a start, got \(outcome)") }
        XCTAssertTrue(waited)
        XCTAssertEqual(player.starts.count, 1)
    }

    func testATapBeforeTheQueueIsBuiltDoesNotStartIfTheListenerBeganSomethingElse() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdAllCalls()
        let model = await makeStation(active: .default)
        let feed = makeFeed(catalog)
        feed.follow(model)
        let player = FakePlayer()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(5), pollInterval: .milliseconds(1))

        let tap = Task { await open(.userTap, starter, model, player) }
        // Wait for the hold and open()'s first nothingQueued read, so the listener's song tap lands
        // while open() is waiting in its loop, which is what this test covers.
        for _ in 0..<500 {
            if await catalog.isHolding, player.nothingQueuedReads >= 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let holding = await catalog.isHolding
        XCTAssertTrue(holding, "the build is waiting on the catalog")
        XCTAssertGreaterThanOrEqual(player.nothingQueuedReads, 1, "open() passed its pre-loop idle check and is waiting")
        player.queue = ["searched"]                             // listener tapped a search result meanwhile
        player.playing = true
        await catalog.release()

        let outcome = await tap.value
        XCTAssertEqual(outcome, .notStarted(.playbackBegan))
        XCTAssertEqual(player.starts, [])
        XCTAssertEqual(player.queue, ["searched"])
    }

    func testANewerTapSupersedesAWaitingOne() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdAllCalls()
        let model = await makeStation(active: .default)
        let feed = makeFeed(catalog)
        feed.follow(model)
        let player = FakePlayer()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(5), pollInterval: .milliseconds(1))

        let first = Task { await open(.userTap, starter, model, player) }
        for _ in 0..<500 { if await catalog.isHolding { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let other = station([seed(.artist, "b")])
        let second = Task { await open(.userTap, starter, model, player, recipe: other) }
        for _ in 0..<5 { await Task.yield() }
        await catalog.release()

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .notStarted(.superseded))
        guard case .started = secondOutcome else { return XCTFail("the newer tap starts") }
        XCTAssertEqual(player.starts.count, 1, "only one tap ever starts playback")
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["b"])
    }

    // Fry #213 nit 4: the same station tapped twice while it starts. The keys match, so only
    // the tap generation tells the older tap it was replaced; only the latest tap may start.
    func testTheSameCreatedStationTappedTwiceWhileWaitingStartsOnlyTheLatestTap() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdAllCalls()
        let model = await makeStation(active: .default)
        let feed = makeFeed(catalog)
        feed.follow(model)
        let player = FakePlayer()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(5), pollInterval: .milliseconds(1))
        let id = UUID()

        let first = Task { await open(.userTap, starter, model, player, id: id) }
        for _ in 0..<500 { if await catalog.isHolding { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let holding = await catalog.isHolding
        XCTAssertTrue(holding, "the first tap is waiting")
        let second = Task { await open(.userTap, starter, model, player, id: id) }
        for _ in 0..<5 { await Task.yield() }
        await catalog.release()

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .notStarted(.superseded), "the older tap is dropped")
        guard case .started = secondOutcome else { return XCTFail("the latest tap starts, got \(secondOutcome)") }
        XCTAssertEqual(player.starts.count, 1, "only one tap ever starts playback")
        await waitFor { player.queue.count >= 10 }
        XCTAssertGreaterThanOrEqual(player.queue.count, 10, "the station's queue fills in")
    }

    // Fry #213 nit 2: another tap path cancels a waiting start.
    func testABuiltInTapCancelsAWaitingCreatedStationStart() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdAllCalls()
        let model = await makeStation(active: .default)
        let feed = makeFeed(catalog)
        feed.follow(model)
        let player = FakePlayer()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(5), pollInterval: .milliseconds(1))
        let id = UUID()

        let tap = Task { await open(.userTap, starter, model, player, id: id) }
        for _ in 0..<500 { if await catalog.isHolding { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let holding = await catalog.isHolding
        XCTAssertTrue(holding, "the tap is waiting")
        starter.cancelPending()
        XCTAssertNil(starter.currentRecipeID, "the created station is no longer current")
        await catalog.release()

        let outcome = await tap.value
        XCTAssertEqual(outcome, .notStarted(.superseded))
        XCTAssertEqual(player.starts, [], "the cancelled tap never starts playback")
    }

    // Fry #213 nit 3: tapping the created station that is already current does not apply its recipe
    // again, so unsaved Tune edits stay. #454: and it changes nothing while it plays.
    func testTappingTheCurrentCreatedStationAgainKeepsUnsavedTuneEdits() async throws {
        let model = await makeStation(active: .default)
        let feed = makeFeed(QueueFakeCatalog())
        feed.follow(model)
        let player = FakePlayer()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(2), pollInterval: .milliseconds(1))
        let id = UUID()

        guard case .started = await open(.userTap, starter, model, player, id: id) else { return XCTFail("the first tap starts") }
        XCTAssertEqual(player.applies, 1)
        XCTAssertEqual(starter.currentRecipeID, id)
        await model.setEnergy(0.9)                               // an unsaved Tune edit
        XCTAssertTrue(model.hasUnsavedChanges)

        let again = await open(.userTap, starter, model, player, id: id)
        XCTAssertEqual(again, .alreadyPlaying, "playing: nothing new starts")
        XCTAssertEqual(player.applies, 1, "the current station's recipe is not applied again")
        XCTAssertTrue(model.hasUnsavedChanges, "unsaved Tune edits stay")
        XCTAssertEqual(player.starts.count, 1)

        let other = await open(.userTap, starter, model, player, id: UUID())
        XCTAssertEqual(other, .alreadyPlaying, "a different recipe with the same music is the station already playing")
        XCTAssertEqual(player.applies, 2, "a different created station still applies")
        XCTAssertEqual(player.starts.count, 1)
    }

    // Fry #218: Tune applied another recipe after the tap, so the cached id is stale. Tapping the
    // created station again must re-apply it, not leave the station on the other recipe.
    func testTappingACreatedStationAfterTuneAppliedAnotherRecipeAppliesItAgain() async throws {
        let model = await makeStation(active: .default)
        let feed = makeFeed(QueueFakeCatalog())
        feed.follow(model)
        let player = FakePlayer()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(2), pollInterval: .milliseconds(1))
        let a = UUID()

        guard case .started = await open(.userTap, starter, model, player, id: a) else { return XCTFail("the first tap starts") }
        XCTAssertEqual(player.applies, 1)

        let b = station([seed(.artist, "b")])                   // Tune > Recipes applies B (not via the starter)
        await model.applyRecipe(StationRecipe(name: "B Radio", configuration: b))
        player.liveRecipe = UUID()
        XCTAssertEqual(starter.currentRecipeID, a, "the starter's cached id is now stale")

        let again = await open(.userTap, starter, model, player, id: a)
        XCTAssertEqual(again, .alreadyPlaying, "A's queue is still the one playing")
        XCTAssertEqual(player.applies, 2, "A is applied again over B")
        XCTAssertEqual(player.liveRecipe, a)
        XCTAssertEqual(model.displayed.seeds, created.seeds, "the station is A again, not B")
    }

    func testATapThatCannotBeBuiltDoesNotStartOrWaitForever() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.setFailing(true)
        let model = await makeStation(active: .default)
        let feed = makeFeed(catalog)
        let player = FakePlayer()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .milliseconds(50), pollInterval: .milliseconds(1))

        let outcome = await open(.userTap, starter, model, player)
        XCTAssertEqual(outcome, .notStarted(.buildFailed))
        XCTAssertEqual(player.starts, [])
    }
}

/// #204 (-Atlas): a handed-out station queue whose MusicKit start fails is put back: the playing
/// queue keeps its station, the songs are staged again, and the next boundary or Play retries.
@MainActor
final class StationHandOffFailureTests: XCTestCase {
    private let old = station([seed(.artist, "old")])
    private let new = station([seed(.artist, "a"), seed(.artist, "b")])

    private func switchFeed(_ recorder: QueueEventRecorder = QueueEventRecorder()) async -> StationQueueFeed<String> {
        let feed = makeFeed(QueueFakeCatalog(), recorder: recorder)
        feed.queueStarted(for: old)
        _ = await feed.prepare(new)
        return feed
    }

    func testFailedStationSwitchKeepsTheOldStationAndRetriesAtTheNextBoundary() async throws {
        let recorder = QueueEventRecorder()
        let feed = await switchFeed(recorder)
        let first = try XCTUnwrap(feed.takeForBoundary(active: new, playbackMayStart: true))
        feed.handOffFinished(.failed)
        XCTAssertEqual(feed.playingKey, StationQueueKey(old), "the queue that still plays belongs to the old station")
        XCTAssertEqual(feed.stagedCount, first.count, "the station's songs are staged again")
        XCTAssertEqual(recorder.events.last, .handOffFailed(.songBoundary))
        let retry = try XCTUnwrap(feed.takeForBoundary(active: new, playbackMayStart: true), "next boundary retries")
        XCTAssertEqual(retry, first)
    }

    func testFailedLastSongRefillIsStagedAgainForTheNextTry() async throws {
        let recorder = QueueEventRecorder()
        let feed = await refillFeed(recorder: recorder)
        let queue = ["mine-0", "mine-1", "mine-2"]
        let refill = try XCTUnwrap(next(feed, after: 1, in: queue))
        feed.handOffFinished(.failed)
        XCTAssertEqual(recorder.events.last, .handOffFailed(.refill))
        XCTAssertNotNil(feed.stagedCount)
        XCTAssertEqual(feed.playingKey, StationQueueKey(refillStation))
        XCTAssertEqual(next(feed, after: 1, in: queue), refill, "the same refill can be tried again")
    }

    func testFailedIdlePlayLetsTheNextPlayRetry() async throws {
        let feed = makeFeed(QueueFakeCatalog())
        _ = await feed.prepare(new)
        let first = try XCTUnwrap(feed.takeForIdleStart(active: new))
        feed.handOffFinished(.failed)
        XCTAssertNil(feed.playingKey, "nothing started: no station owns a playing queue")
        XCTAssertFalse(feed.queueStartReported)
        XCTAssertEqual(feed.takeForIdleStart(active: new), first, "Play again retries")
    }

    func testStartedAndSupersededKeepTheHandOff() async throws {
        for result in [StationHandOffResult.started, .superseded] {
            let feed = await switchFeed()
            _ = try XCTUnwrap(feed.takeForBoundary(active: new, playbackMayStart: true))
            feed.handOffFinished(result)
            XCTAssertEqual(feed.playingKey, StationQueueKey(new), "\(result)")
            XCTAssertNil(feed.stagedCount, "\(result): not put back")
            XCTAssertNil(feed.takeForBoundary(active: new, playbackMayStart: true), "\(result): no repeat hand-off")
        }
    }

    func testATapAfterTheHandOffWinsOverItsLateFailure() async throws {
        let feed = await switchFeed()
        _ = try XCTUnwrap(feed.takeForBoundary(active: new, playbackMayStart: true))
        let tapped = station([seed(.artist, "tap")])
        feed.queueStarted(for: tapped)
        feed.handOffFinished(.failed)
        XCTAssertEqual(feed.playingKey, StationQueueKey(tapped), "the old queue is never resurrected over a newer tap")
        XCTAssertNil(feed.stagedCount)
    }

    func testAFailureReportsOnceAndNeverOverwritesANewerBuild() async throws {
        let recorder = QueueEventRecorder()
        let feed = await switchFeed(recorder)
        _ = try XCTUnwrap(feed.takeForBoundary(active: new, playbackMayStart: true))
        let newer = station([seed(.artist, "newer")])
        _ = await feed.prepare(newer)
        feed.handOffFinished(.failed)
        XCTAssertEqual(feed.stagedKey, StationQueueKey(newer), "a newer staged build is kept")
        XCTAssertEqual(feed.playingKey, StationQueueKey(old))
        let count = recorder.events.count
        feed.handOffFinished(.failed)
        XCTAssertEqual(recorder.events.count, count, "a second report changes nothing")
    }
}

/// #204: the boundary fallback decision (pure, no actor).
final class StationHandOffFallbackTests: XCTestCase {
    func testBoundaryFallbackLoadsTheOldNextSongOnlyForAFailureWithNothingNewer() {
        XCTAssertTrue(StationHandOffFallback.loadsOldQueueNext(
            result: .failed, generationBefore: 4, generationNow: 5, next: 2, oldQueueCount: 3))
        XCTAssertFalse(StationHandOffFallback.loadsOldQueueNext(
            result: .superseded, generationBefore: 4, generationNow: 6, next: 2, oldQueueCount: 3))
        XCTAssertFalse(StationHandOffFallback.loadsOldQueueNext(
            result: .started, generationBefore: 4, generationNow: 5, next: 2, oldQueueCount: 3))
        XCTAssertFalse(StationHandOffFallback.loadsOldQueueNext(
            result: .failed, generationBefore: 4, generationNow: 6, next: 2, oldQueueCount: 3),
            "a tap or skip after the failed start owns the player")
        XCTAssertFalse(StationHandOffFallback.loadsOldQueueNext(
            result: .failed, generationBefore: 4, generationNow: 5, next: 3, oldQueueCount: 3),
            "no next song in the old queue: today's stop path")
    }
}

// #454 (-Atlas): instant start for every station type (built-in, library, created, a switch),
// the background fill (append, never replace), the same-station no-op, timeout and retry, and the
// station intro spend gate (Sentinel) and air rule (Echo).
@MainActor
final class StationStartInstantTests: XCTestCase {
    @MainActor private final class Player {
        var queue: [String] = [] { didSet { if !appending { epoch += 1 } } }
        var playing = false
        var applies = 0
        var starts: [[String]] = []
        var appended: [[String]] = []
        private(set) var epoch = 0
        private var appending = false
        var station: StationQueueKey?
        /// #456: what `start` leaves the transport at (a held or refused start stays `.preparing`).
        var transportAfterStart: TransportState = .playing
        var transport: TransportState = .stopped
        var resumes = 0
        var nothingQueued: Bool { queue.isEmpty && !playing }
        func append(_ songs: [String]) { appending = true; queue += songs; appending = false }
    }

    /// Stands in for Fry's `DJBreakSession` intro: a different id cancels the render in flight.
    @MainActor private final class FakeIntro: StationIntroHook {
        var begins: [String] = []
        var takes: [String] = []
        var cancelled = 0
        var live: String?
        var maxLive = 0
        /// Player starts at each begin, to prove the first song never waited on an intro.
        var startsAtBegin: [Int] = []
        var ready: PreparedDJBreak?
        weak var player: Player?
        func beginStationIntro(_ facts: StationIntroFacts) {
            if let live, live != facts.id { cancelled += 1 }
            live = facts.id
            maxLive = max(maxLive, live == nil ? 0 : 1)
            begins.append(facts.id)
            startsAtBegin.append(player?.starts.count ?? -1)
        }
        func takeStationIntroAtSongStart(id: String) async -> PreparedDJBreak? {
            takes.append(id)
            guard live == id else { return nil }
            live = nil
            return ready
        }
    }

    private func makeStation(active: StationConfiguration = .default) async -> StationConfigurationModel {
        let model = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: active))),
            consent: StaticIntegrationConsent([:]))
        await model.load()
        return model
    }

    private func starter(_ feed: StationQueueFeed<String>, timeout: Duration = .seconds(5),
                         introDelay: Duration = .milliseconds(5)) -> CreatedStationStarter<String> {
        CreatedStationStarter(feed: feed, readyTimeout: timeout, pollInterval: .milliseconds(1),
                              fillTimeout: .seconds(5), introDelay: introDelay)
    }

    private func open(_ starter: CreatedStationStarter<String>, _ model: StationConfigurationModel,
                      _ player: Player, _ config: StationConfiguration?, id: UUID = UUID(),
                      facts: StationIntroFacts? = nil) async -> CreatedStationOpenOutcome {
        await starter.open(.userTap,
                           recipeID: id,
                           available: config != nil,
                           introFacts: facts,
                           authorize: {},
                           apply: {
                               player.applies += 1
                               guard let config else { return false }
                               await model.applyRecipe(StationRecipe(id: id, name: "S", configuration: config))
                               return true
                           },
                           active: { model.active },
                           nothingQueued: { player.nothingQueued },
                           playingStation: { player.station },
                           switchNow: { await model.applyPendingForStationSwitch() },
                           queueEpoch: { player.epoch },
                           transport: { player.transport },
                           resume: {
                               player.resumes += 1
                               player.transport = .playing
                               player.playing = true
                           },
                           start: { items in
                               player.starts.append(items)
                               player.queue = items
                               player.station = StationQueueKey(model.active)
                               player.transport = player.transportAfterStart
                               player.playing = player.transportAfterStart == .playing
                           },
                           append: { first, songs in
                               guard player.queue.first == first else { return false }
                               player.appended.append(songs)
                               player.append(songs)
                               return true
                           })
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func rig(_ catalog: QueueFakeCatalog = QueueFakeCatalog()) async
        -> (StationConfigurationModel, StationQueueFeed<String>, Player) {
        let model = await makeStation()
        let feed = makeFeed(catalog)
        feed.follow(model)
        return (model, feed, Player())
    }

    // MARK: every station type starts on its first song, without the full queue

    func testABuiltInStationStartsOnItsFirstSongBeforeTheQueueIsBuilt() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdTier("related")                      // the full build cannot finish
        let (model, feed, player) = await rig(catalog)
        let builtIn = BuiltInStations.morningCalm
        let recipe = try XCTUnwrap(StationStartFacts.builtInRecipe(for: builtIn.id))
        XCTAssertEqual(recipe.configuration.seeds, builtIn.configuration.seeds, "the real built-in seeds")

        let outcome = await open(starter(feed), model, player, recipe.configuration, id: builtIn.id)

        XCTAssertEqual(outcome, .started(songs: 1, waited: true))
        XCTAssertEqual(player.starts.count, 1)
        XCTAssertEqual(player.queue.count, 1, "one song now; the rest is not waited for")
        XCTAssertEqual(model.active.seeds, builtIn.configuration.seeds)
        await catalog.release()
    }

    func testABuiltInWithATestFixtureRecipeStartsTheSameWay() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdTier("related")
        let (model, feed, player) = await rig(catalog)
        let fixture = station([seed(.song, "fixture-song")])  // test-local recipe, not shipped content

        let outcome = await open(starter(feed), model, player, fixture)
        XCTAssertEqual(outcome, .started(songs: 1, waited: true))
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertTrue(player.queue[0].hasPrefix("fixture-song-core-"), "the fixture seed's own song")
        await catalog.release()
    }

    func testAnUnknownBuiltInIdIsAnHonestCannotStartNotASearch() async throws {
        let (model, feed, player) = await rig()
        XCTAssertNil(StationStartFacts.builtInRecipe(for: UUID()))
        let outcome = await open(starter(feed), model, player, nil)
        XCTAssertEqual(outcome, .notStarted(.notAvailableYet))
        XCTAssertEqual(player.applies, 0)
        XCTAssertEqual(player.starts, [])
        XCTAssertEqual(StationStartStatus.phase(after: outcome), .unavailable)
    }

    func testALibraryStationStartsOnItsFirstSongWhileTheRestIsStillReading() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdSeed("lib-2")                        // the second library seed is slow
        let (model, feed, player) = await rig(catalog)
        let library = station([seed(.playlist, "lib-1", .library), seed(.playlist, "lib-2", .library)], reach: .only)

        let outcome = await open(starter(feed), model, player, library)
        XCTAssertEqual(outcome, .started(songs: 1, waited: true))
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertTrue(player.queue[0].hasPrefix("lib-1-core-"), "the first library seed's song")
        await catalog.release()
    }

    func testACreatedStationStartsOnOneSongThenTheRestIsAppendedNotReplaced() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdTier("related")
        let (model, feed, player) = await rig(catalog)
        let created = station([seed(.artist, "a")])
        let s = starter(feed)                                   // the app keeps one for the session

        let outcome = await open(s, model, player, created)
        XCTAssertEqual(outcome, .started(songs: 1, waited: true))
        let first = try XCTUnwrap(player.queue.first)
        let epochAfterStart = player.epoch
        XCTAssertEqual(player.appended, [], "nothing appended before the build")

        await catalog.release()
        await waitFor { !player.appended.isEmpty }
        XCTAssertEqual(player.appended.count, 1, "one background fill")
        XCTAssertEqual(player.starts.count, 1, "the fill never starts or replaces the queue")
        XCTAssertEqual(player.epoch, epochAfterStart, "the queue was never replaced")
        XCTAssertEqual(player.queue.first, first, "the playing song stays first")
        XCTAssertGreaterThanOrEqual(player.queue.count, 10)
        XCTAssertEqual(Set(player.queue).count, player.queue.count, "the first song is not appended again")
    }

    func testATapOnAnotherStationWhileOneIsPlayingSwitchesNowOnItsFirstSong() async throws {
        let catalog = QueueFakeCatalog()
        let (model, feed, player) = await rig(catalog)
        let s = starter(feed)
        let a = station([seed(.artist, "a")])
        guard case .started = await open(s, model, player, a) else { return XCTFail("A starts") }
        await waitFor { player.queue.count >= 10 }
        await model.setPlaybackActivity(.holdingSong)          // A's song is playing

        await catalog.holdTier("related")
        let b = station([seed(.artist, "b")])
        let outcome = await open(s, model, player, b)

        XCTAssertEqual(outcome, .started(songs: 1, waited: true), "B starts now, on one song")
        XCTAssertEqual(player.starts.count, 2)
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertTrue(player.queue[0].hasPrefix("b-core-"), "A's queue is gone, not appended to")
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["b"], "the row tap is not held for the boundary")
        XCTAssertEqual(feed.playingKey, StationQueueKey(b))
        await catalog.release()
        await waitFor { player.queue.count >= 10 }
        XCTAssertTrue(player.queue.allSatisfy { $0.hasPrefix("b-") }, "only B's songs are appended")
    }

    func testTappingTheStationAlreadyPlayingIsANoOp() async throws {
        let (model, feed, player) = await rig()
        let s = starter(feed)
        let intro = FakeIntro()
        s.intro = intro
        s.airIntro = { _ in }
        let a = station([seed(.artist, "a")])
        let id = UUID()
        let facts = StationIntroFacts(id: id.uuidString, name: "A")
        guard case .started = await open(s, model, player, a, id: id, facts: facts) else { return XCTFail("A starts") }
        await waitFor { intro.begins.count == 1 }
        let queue = player.queue

        let again = await open(s, model, player, a, id: id, facts: facts)
        XCTAssertEqual(again, .alreadyPlaying)
        XCTAssertEqual(player.starts.count, 1)
        XCTAssertEqual(player.queue, queue)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(intro.begins.count, 1, "no second intro for the station already playing")
    }

    func testATimedOutStartSaysSoAndTryAgainStarts() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdAllCalls()
        let (model, feed, player) = await rig(catalog)
        let s = starter(feed, timeout: .milliseconds(30))
        let a = station([seed(.artist, "a")])
        let status = StationStartStatus()
        var retried = 0
        let tap = status.begin(stationID: "a", stationName: "A", songAtTap: nil, retry: { retried += 1 })

        let outcome = await open(s, model, player, a)
        XCTAssertEqual(outcome, .notStarted(.notReadyInTime))
        status.finish(tap: tap, outcome: outcome)
        XCTAssertEqual(status.state?.phase, .failed)
        XCTAssertEqual(NowPlayingContent.resolve(access: .authorized, snapshot: PlaybackSnapshot(),
                                                 start: StationStartStatus.shown(status.state, openedStationID: "a", nowPlaying: nil)),
                       .startFailed(stationName: "A"))
        status.retry()
        XCTAssertEqual(retried, 1)

        await catalog.release()
        let retry = await open(s, model, player, a)
        guard case .started = retry else { return XCTFail("Try again starts, got \(retry)") }
        XCTAssertEqual(player.starts.count, 1)
    }

    // MARK: station intro: Sentinel's spend gate, Echo's air rule

    func testRapidTapsBeginOnlyTheFinalStationsIntroAfterItsFirstSongStarted() async throws {
        let catalog = QueueFakeCatalog()
        await catalog.holdAllCalls()
        let (model, feed, player) = await rig(catalog)
        let s = starter(feed)
        let intro = FakeIntro()
        intro.player = player
        s.intro = intro
        s.airIntro = { _ in }

        var taps: [Task<CreatedStationOpenOutcome, Never>] = []
        for n in 0..<5 {
            let config = station([seed(.artist, "s\(n)")])
            taps.append(Task { await open(s, model, player, config, facts: StationIntroFacts(id: "s\(n)", name: "S\(n)")) })
            for _ in 0..<5 { await Task.yield() }
        }
        XCTAssertEqual(intro.begins, [], "no intro before any start is confirmed")
        await catalog.release()
        var outcomes: [CreatedStationOpenOutcome] = []
        for t in taps { outcomes.append(await t.value) }
        await waitFor { !intro.begins.isEmpty }
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(outcomes.dropLast(), Array(repeating: .notStarted(.superseded), count: 4))
        XCTAssertEqual(player.starts.count, 1)
        XCTAssertEqual(intro.begins, ["s4"], "only the final station's intro begins")
        XCTAssertLessThanOrEqual(intro.maxLive, 1)
        XCTAssertEqual(intro.startsAtBegin, [1], "begun only after its first song started")
    }

    func testStartsThatEachConfirmStillBeginOneIntroAndAQuickSwitchBeginsNone() async throws {
        let (model, feed, player) = await rig()
        let s = starter(feed, introDelay: .milliseconds(200))   // the debounce
        let intro = FakeIntro()
        s.intro = intro
        s.airIntro = { _ in }
        guard case .started = await open(s, model, player, station([seed(.artist, "a")]),
                                         facts: StationIntroFacts(id: "a", name: "A")) else { return XCTFail() }
        guard case .started = await open(s, model, player, station([seed(.artist, "b")]),
                                         facts: StationIntroFacts(id: "b", name: "B")) else { return XCTFail() }
        await waitFor { !intro.begins.isEmpty }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(intro.begins, ["b"], "A was replaced inside the debounce: its intro never began")
        XCTAssertEqual(intro.cancelled, 0)
    }

    func testAStartWithNoIntroPlayerBeginsNoIntro() async throws {
        let (model, feed, player) = await rig()
        let s = starter(feed)
        let intro = FakeIntro()
        s.intro = intro                                         // no `airIntro`: nothing could air it
        guard case .started = await open(s, model, player, station([seed(.artist, "a")]),
                                         facts: StationIntroFacts(id: "a", name: "A")) else { return XCTFail() }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(intro.begins, [], "no render nobody can hear")
        let boundary = await s.songBoundary(queueEpoch: player.epoch)
        XCTAssertNil(boundary)
    }

    func testAReadyIntroAirsAtTheFirstBoundaryNeverAtTheFirstSongsStart() async throws {
        let (model, feed, player) = await rig()
        let s = starter(feed)
        let intro = FakeIntro()
        intro.player = player
        intro.ready = PreparedDJBreak(afterTrack: StationIntro.afterTrack, cues: [], clips: [], attributions: [:])
        s.intro = intro
        var aired: [PreparedDJBreak] = []
        s.airIntro = { aired.append($0) }

        guard case .started = await open(s, model, player, station([seed(.artist, "a")]),
                                         facts: StationIntroFacts(id: "a", name: "A")) else { return XCTFail() }
        XCTAssertEqual(intro.takes, [], "nothing is taken while the first song starts")
        await waitFor { !intro.begins.isEmpty }
        XCTAssertEqual(intro.startsAtBegin, [1], "the first song was already playing")
        XCTAssertEqual(aired, [], "never aired over the first song")

        let disposition = await s.songBoundary(queueEpoch: player.epoch)
        XCTAssertEqual(disposition, .aired)
        XCTAssertEqual(aired.count, 1, "aired once, at the boundary, through the break path")
        let again = await s.songBoundary(queueEpoch: player.epoch)
        XCTAssertNil(again, "only the first boundary")
    }

    func testAnIntroNotReadyAtTheBoundaryIsSkippedAndAQueueChangeDropsIt() async throws {
        let (model, feed, player) = await rig()
        let s = starter(feed)
        let intro = FakeIntro()
        s.intro = intro
        var aired = 0
        s.airIntro = { _ in aired += 1 }

        guard case .started = await open(s, model, player, station([seed(.artist, "a")]),
                                         facts: StationIntroFacts(id: "a", name: "A")) else { return XCTFail() }
        await waitFor { !intro.begins.isEmpty }
        let notReady = await s.songBoundary(queueEpoch: player.epoch)
        XCTAssertEqual(notReady, .notReady, "not ready: skipped, the song is never held")

        intro.ready = PreparedDJBreak(afterTrack: StationIntro.afterTrack, cues: [], clips: [], attributions: [:])
        guard case .started = await open(s, model, player, station([seed(.artist, "b")]),
                                         facts: StationIntroFacts(id: "b", name: "B")) else { return XCTFail() }
        await waitFor { intro.begins.count == 2 }
        player.queue = ["searched"]                              // the listener tapped a song
        let dropped = await s.songBoundary(queueEpoch: player.epoch)
        XCTAssertEqual(dropped, .droppedQueueChanged)
        XCTAssertEqual(aired, 0)
        XCTAssertEqual(intro.takes, ["a", "b"], "each intro is closed, so it stops rendering")
    }

    // MARK: Fry's #456 nits

    // N2: a start the player has not confirmed as playing (a hold, a call refusing play) begins no
    // intro; it begins once the transport really reports `.playing`.
    func testTheIntroBeginsOnlyOnceTheFirstSongIsReallyPlaying() async throws {
        let (model, feed, player) = await rig()
        let s = starter(feed)
        let intro = FakeIntro()
        s.intro = intro
        s.airIntro = { _ in }
        player.transportAfterStart = .preparing                 // queue set, MusicKit not playing yet

        guard case .started = await open(s, model, player, station([seed(.artist, "a")]),
                                         facts: StationIntroFacts(id: "a", name: "A")) else { return XCTFail() }
        try await Task.sleep(nanoseconds: 60_000_000)          // well past the 5 ms debounce
        XCTAssertEqual(intro.begins, [], "a queue that is set but not playing begins no intro")

        player.transport = .playing
        player.playing = true
        await waitFor { !intro.begins.isEmpty }
        XCTAssertEqual(intro.begins, ["a"], "begins once the first song is playing")
    }

    func testARefusedStartNeverBeginsTheIntro() async throws {
        let (model, feed, player) = await rig()
        let s = CreatedStationStarter(feed: feed, readyTimeout: .milliseconds(40), pollInterval: .milliseconds(1),
                                      fillTimeout: .seconds(5), introDelay: .milliseconds(5))
        let intro = FakeIntro()
        s.intro = intro
        s.airIntro = { _ in }
        player.transportAfterStart = .preparing                 // held by a call: never confirmed
        guard case .started = await open(s, model, player, station([seed(.artist, "a")]),
                                         facts: StationIntroFacts(id: "a", name: "A")) else { return XCTFail() }
        try await Task.sleep(nanoseconds: 150_000_000)
        player.transport = .playing                              // too late: the wait was bounded
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(intro.begins, [], "no render for a start that never played")
    }

    /// A test clock that only the starter's sleeps advance, each by `factor` times what was asked.
    @MainActor private final class OversleepClock {
        let origin = ContinuousClock.now
        var elapsed = Duration.zero
        var factor = 1
        var releaseAt: Duration?
        var now: ContinuousClock.Instant { origin + elapsed }
    }

    // #456 macOS: the confirmation wait is bounded by time, not by a count of polls. After the
    // start every 1 ms poll oversleeps to 5 ms (a loaded macOS runner), and the call releases the
    // song 150 ms in, well past the 40 ms bound. Counting 40 polls waited 200 ms and began a render
    // for a start that was refused; the time bound gives up at 40 ms. The starter reads this
    // test's clock, which only its own (oversleeping) polls advance, so the order is fixed.
    func testARefusedStartNeverBeginsTheIntroWhenPollsOversleep() async throws {
        let (model, feed, player) = await rig()
        let clock = OversleepClock()
        let s = CreatedStationStarter(feed: feed, readyTimeout: .milliseconds(40), pollInterval: .milliseconds(1),
                                      fillTimeout: .seconds(5), introDelay: .milliseconds(5),
                                      sleep: { requested in
                                          clock.elapsed += requested * clock.factor
                                          if let at = clock.releaseAt, clock.elapsed >= at { player.transport = .playing }
                                          try? await Task.sleep(for: requested)
                                      },
                                      now: { clock.now })
        let intro = FakeIntro()
        s.intro = intro
        s.airIntro = { _ in }
        player.transportAfterStart = .preparing                 // held by a call: never confirmed
        guard case .started = await open(s, model, player, station([seed(.artist, "a")]),
                                         facts: StationIntroFacts(id: "a", name: "A")) else { return XCTFail() }
        clock.factor = 5
        clock.releaseAt = clock.elapsed + .milliseconds(150)
        try await Task.sleep(nanoseconds: 300_000_000)          // every poll has run by now
        player.transport = .playing
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(intro.begins, [], "no render for a start that never played in time")
    }

    // N3: re-tapping the active built-in does not re-apply its recipe, so unsaved Tune edits stay
    // (the app's wiring: `applyBuiltInRecipe` records `lastAppliedRecipeID`).
    func testReTappingTheActiveBuiltInKeepsUnsavedTuneEdits() async throws {
        let studio = await makeCreationStudio()
        let feed = makeFeed(QueueFakeCatalog())
        feed.follow(studio.station)
        let player = Player()
        let s = starter(feed)
        let builtIn = BuiltInStations.lateNight
        let recipe = try XCTUnwrap(StationStartFacts.builtInRecipe(for: builtIn.id))
        func tap() async -> CreatedStationOpenOutcome {
            await s.open(.userTap, recipeID: builtIn.id, liveRecipeID: { studio.lastAppliedRecipeID },
                         authorize: {},
                         apply: { player.applies += 1; await studio.applyBuiltInRecipe(recipe); return true },
                         active: { studio.station.active },
                         nothingQueued: { player.nothingQueued },
                         playingStation: { player.station },
                         switchNow: { await studio.station.applyPendingForStationSwitch() },
                         queueEpoch: { player.epoch },
                         transport: { player.transport },
                         resume: { player.resumes += 1; player.transport = .playing },
                         start: { items in
                             player.starts.append(items)
                             player.queue = items
                             player.station = StationQueueKey(studio.station.active)
                             player.playing = true
                             player.transport = .playing
                         })
        }
        guard case .started = await tap() else { return XCTFail("the built-in starts") }
        XCTAssertEqual(studio.lastAppliedRecipeID, builtIn.id)
        XCTAssertEqual(player.applies, 1)
        await studio.station.setEnergy(0.9)                     // an unsaved Tune edit
        XCTAssertTrue(studio.station.hasUnsavedChanges)

        let again = await tap()
        XCTAssertEqual(again, .alreadyPlaying)
        XCTAssertEqual(player.applies, 1, "the active built-in's recipe is not applied again")
        XCTAssertTrue(studio.station.hasUnsavedChanges, "unsaved Tune edits stay")
        XCTAssertEqual(studio.station.displayed.energy, 0.9, accuracy: 0.001)
        XCTAssertEqual(player.starts.count, 1)
    }

    // N4: the active station, paused: a tap resumes it (as before #454); playing stays a no-op.
    func testTappingThePausedActiveStationResumesIt() async throws {
        let (model, feed, player) = await rig()
        let s = starter(feed)
        let a = station([seed(.artist, "a")])
        let id = UUID()
        guard case .started = await open(s, model, player, a, id: id) else { return XCTFail("A starts") }
        let queue = player.queue
        let epoch = player.epoch
        player.transport = .paused                               // the listener paused A
        player.playing = false

        let paused = await open(s, model, player, a, id: id)
        XCTAssertEqual(paused, .resumed)
        XCTAssertEqual(player.resumes, 1)
        XCTAssertEqual(player.transport, .playing)
        XCTAssertEqual(player.starts.count, 1, "resumed, not restarted")
        XCTAssertEqual(player.epoch, epoch)
        XCTAssertEqual(player.queue, queue)

        let playing = await open(s, model, player, a, id: id)
        XCTAssertEqual(playing, .alreadyPlaying, "playing: still a no-op")
        XCTAssertEqual(player.resumes, 1)
        XCTAssertNil(StationStartStatus.phase(after: .resumed), "no start screen after a resume")
        XCTAssertFalse(CreatedStationOpenOutcome.resumed.warrantsStartFailureNotice, "no toast")
    }

    // MARK: feed, engine and screen pieces

    func testTheFirstSongComesFromTheStationsLastBuildWithoutACatalogCall() async throws {
        let catalog = QueueFakeCatalog()
        let (model, feed, _) = await rig(catalog)
        let a = station([seed(.artist, "a")])
        _ = await feed.prepare(a)
        _ = feed.takeForIdleStart(active: a)                     // the staged queue is used up
        _ = model
        let asked = await catalog.asked.count
        let song = await feed.firstSong(for: a)
        XCTAssertNotNil(song)
        let after = await catalog.asked.count
        XCTAssertEqual(after, asked, "a cached opener needs no catalog call")
    }

    func testQueueExtendedAppendsBehindThePlayingSong() {
        var engine = PlaybackEngine()
        let one = TrackInfo(id: "1", title: "One", artistName: "A")
        engine.apply(.queueStarted(tracks: [one], startIndex: 0, station: nil))
        let playing = engine.snapshot.nowPlaying
        engine.apply(.queueExtended(tracks: [TrackInfo(id: "2", title: "Two", artistName: "A"),
                                             TrackInfo(id: "3", title: "Three", artistName: "A")]))
        XCTAssertEqual(engine.snapshot.nowPlaying, playing)
        XCTAssertEqual(engine.snapshot.upNext.map(\.id), ["2", "3"])

        var empty = PlaybackEngine()
        empty.apply(.queueExtended(tracks: [one]))
        XCTAssertNil(empty.snapshot.nowPlaying, "nothing queued: nothing to extend")
        XCTAssertEqual(empty.snapshot.upNext, [])
    }

    func testTheStartScreenShowsStartingUntilTheNewStationsSongIsOnScreen() {
        let old = TrackInfo(id: "old", title: "Old", artistName: "A")
        let new = TrackInfo(id: "new", title: "New", artistName: "B")
        let starting = StationStartState(stationID: "b", stationName: "B", phase: .starting, songAtTap: "old")
        XCTAssertEqual(StationStartStatus.shown(starting, openedStationID: "b", nowPlaying: old), starting)
        XCTAssertNil(StationStartStatus.shown(starting, openedStationID: "b", nowPlaying: new))
        XCTAssertNil(StationStartStatus.shown(starting, openedStationID: "a", nowPlaying: nil))
        let failed = StationStartState(stationID: "b", stationName: "B", phase: .failed, songAtTap: "old")
        XCTAssertNil(StationStartStatus.shown(failed, openedStationID: "b", nowPlaying: old), "a failed switch keeps the old song")

        let content = NowPlayingContent.resolve(access: .authorized, snapshot: PlaybackSnapshot(), start: starting)
        XCTAssertEqual(content, .starting(stationName: "B"))
        XCTAssertEqual(content.title, "Starting B…")
        XCTAssertTrue(content.showsStartSpinner)
        XCTAssertFalse(content.offersStartRetry)
        XCTAssertEqual(NowPlayingContent.startFailed(stationName: "B").title, "Couldn't start B")
        XCTAssertEqual(NowPlayingContent.startFailed(stationName: "B").detail, "Try again.")
        XCTAssertTrue(NowPlayingContent.startFailed(stationName: "B").offersStartRetry)
        XCTAssertEqual(NowPlayingContent.resolve(access: .authorized, snapshot: PlaybackSnapshot(), start: nil), .nothingPlaying)
    }

    func testStatusPhasesFollowTheOutcome() {
        XCTAssertNil(StationStartStatus.phase(after: .started(songs: 1, waited: true)))
        XCTAssertNil(StationStartStatus.phase(after: .alreadyPlaying))
        XCTAssertNil(StationStartStatus.phase(after: .notStarted(.superseded)))
        XCTAssertEqual(StationStartStatus.phase(after: .notStarted(.notReadyInTime)), .failed)
        XCTAssertEqual(StationStartStatus.phase(after: .notApplied), .failed)
        XCTAssertEqual(StationStartStatus.phase(after: .notStarted(.notAvailableYet)), .unavailable)
        XCTAssertEqual(StationStartFacts.builtIn(BuiltInStations.lateNight.id)?.name, "Late Night")
        XCTAssertEqual(StationStartFacts.builtIn(BuiltInStations.lateNight.id)?.seeds,
                       BuiltInStations.lateNight.configuration.seeds)
    }
}
