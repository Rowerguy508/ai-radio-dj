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
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false

    func setFailing(_ value: Bool) { failing = value }
    func holdNextCall() { holdNext = true }
    func release() { gate?.resume(); gate = nil }
    var isHolding: Bool { gate != nil }

    private func songs(_ seed: StationSeed, _ tier: String, _ limit: Int) async throws -> [StationCandidate] {
        asked.append("\(tier):\(seed.source.rawValue)")
        if holdNext { holdNext = false; await withCheckedContinuation { gate = $0 } }
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
        options: .init(limit: limit),
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
