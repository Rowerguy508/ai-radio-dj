import XCTest
@testable import AeroDJCore

/// PR B (-Nova): the on-device file, the app's ratings model, the break drop, and the button copy.
@MainActor
final class StationRatingsInAppTests: XCTestCase {
    private static let today = 42
    private static let station = StationConfiguration(seeds: [StationSeed(kind: .artist, catalogID: "first", name: "First",
                                                                          source: .catalog)])
    private static var scope: StationRatingScope { StationRatingScope(recipeID: nil, configuration: station)! }
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ratings-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var fileURL: URL { FileStationRatingStore.defaultURL(applicationSupport: folder) }
    private func store(today: Int = today) -> FileStationRatingStore {
        FileStationRatingStore(fileURL: fileURL, today: { today })
    }
    private static func song(_ id: String, origin: TrackOrigin = .catalog) -> StationRatedSong {
        StationRatedSong(songID: id, artistName: "Artist \(id)", artistID: "aid-\(id)", origin: origin)
    }
    private func model(_ store: any StationRatingStore) -> StationRatingsModel {
        StationRatingsModel(store: store, today: { Self.today })
    }

    // MARK: FileStationRatingStore

    func testTheFileLivesInRatingsUnderApplicationSupport() {
        XCTAssertEqual(fileURL.lastPathComponent, "ratings.json")
        XCTAssertEqual(fileURL.deletingLastPathComponent().lastPathComponent, "Ratings")
        XCTAssertEqual(fileURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                       folder.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// Sentinel §5: atomic, protected until first unlock on iOS, excluded from backup by default.
    func testFileAttributes() {
        XCTAssertTrue(FileStationRatingStore.writingOptions.contains(.atomic))
        #if os(iOS)
        XCTAssertTrue(FileStationRatingStore.writingOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        #endif
        XCTAssertTrue(FileStationRatingStore.excludedFromBackup)
    }

    func testAMissingFileLoadsAnEmptyBook() async throws {
        let loaded = try await store().load()
        XCTAssertEqual(loaded, StationRatingBook())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "loading never creates the file")
    }

    func testRoundTripCreatesTheFolderAndKeepsEveryLevel() async throws {
        var book = StationRatingBook()
        for (i, level) in SongRating.allCases.enumerated() {
            book.rate(StationRatingEntry(songID: "s\(i)", artistName: "A\(i)", artistID: i == 3 ? "aid" : nil, rating: level,
                                         ratedDay: Self.today, origin: i == 0 ? .library : .catalog),
                      in: Self.scope, today: Self.today)
        }
        try await store().save(book)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let loaded = try await store().load()
        XCTAssertEqual(loaded, book)
        XCTAssertEqual(loaded.ratings(for: Self.scope).entries["s0"]?.origin, .library)
        XCTAssertEqual(loaded.ratings(for: Self.scope).entries["s3"]?.artistID, "aid")
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\":1"), "versioned file")
    }

    func testTheSavedFileIsStable() async throws {
        var book = StationRatingBook()
        for id in ["b", "a", "c"] {
            book.rate(StationRatingEntry(songID: id, artistName: id, rating: .like, ratedDay: Self.today, origin: .catalog),
                      in: Self.scope, today: Self.today)
        }
        try await store().save(book)
        let first = try Data(contentsOf: fileURL)
        try await store().save(try await store().load())
        XCTAssertEqual(try Data(contentsOf: fileURL), first, "same book, same bytes (sorted keys, sorted entries)")
    }

    /// The decoder gets `StationRatingBook.todayKey`: an over-full station is trimmed for the store's
    /// today, not the newest rating's day (here: the tired entries have expired by `today`).
    func testLoadTrimsWithTheStoresToday() async throws {
        let cap = StationRatingTuning.maxEntriesPerStation
        let entries = (0..<cap).map { StationRatingEntry(songID: "t\($0)", artistName: "a", rating: .tired, ratedDay: 0,
                                                         origin: .catalog) }
            + [StationRatingEntry(songID: "like", artistName: "b", rating: .like, ratedDay: 0, origin: .catalog)]
        struct File: Encodable { let version: Int; let stations: [String: StationRatingsFile] }
        struct StationRatingsFile: Encodable { let entries: [StationRatingEntry] }
        let data = try JSONEncoder().encode(File(version: 1, stations: [Self.scope.storageKey: .init(entries: entries)]))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)

        let early = try await store(today: 1).load().ratings(for: Self.scope)
        XCTAssertEqual(early.count, cap)
        XCTAssertNil(early.rating(for: "like"), "day 1: active tired outrank like, so the like is evicted")

        let late = try await store(today: StationRatingTuning.tiredEndDay + 1).load().ratings(for: Self.scope)
        XCTAssertEqual(late.count, cap)
        XCTAssertEqual(late.rating(for: "like"), .like, "past tiredEndDay the expired tired go first: the like stays (without todayKey the like would go)")
    }

    func testANewerFileIsNotReadAndNeverOverwritten() async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"version":2,"stations":{},"future":true}"#.utf8)
        try newer.write(to: fileURL)
        do {
            _ = try await store().load()
            XCTFail("a newer file is refused")
        } catch {
            XCTAssertEqual(error as? StationRatingStoreError, .newerVersion)
        }
        let m = model(store())
        await m.load()
        XCTAssertEqual(m.loadState, .readOnly)
        XCTAssertNil(m.rate(.never, song: Self.song("x"), in: Self.scope), "read-only: no rating")
        m.clearStation(Self.scope)
        await m.flush()
        XCTAssertEqual(try Data(contentsOf: fileURL), newer, "the newer file is untouched")
    }

    func testACorruptFileLoadsEmptyAndIsReplacedAtTheNextSave() async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        do {
            _ = try await store().load()
            XCTFail("corrupt")
        } catch {
            XCTAssertEqual(error as? StationRatingStoreError, .corrupt)
        }
        let m = model(store())
        await m.load()
        XCTAssertEqual(m.loadState, .loaded)
        m.rate(.like, song: Self.song("x"), in: Self.scope)
        await m.flush()
        let reloaded = try await store().load()
        XCTAssertEqual(reloaded.rating(for: "x", in: Self.scope), .like)
    }

    // MARK: StationRatingsModel

    func testNothingIsRatedBeforeTheLoad() async {
        let m = model(InMemoryStationRatingStore())
        XCTAssertNil(m.rate(.love, song: Self.song("x"), in: Self.scope), "before load: a rating would be lost")
        await m.load()
        XCTAssertNotNil(m.rate(.love, song: Self.song("x"), in: Self.scope))
    }

    func testATagsOnlyStationCannotBeRated() async {
        let m = model(InMemoryStationRatingStore())
        await m.load()
        let tagsOnly = StationRatingScope(recipeID: nil, configuration: StationConfiguration(genres: ["jazz"]))
        XCTAssertNil(tagsOnly)
        XCTAssertNil(m.rate(.never, song: Self.song("x"), in: tagsOnly))
        XCTAssertNil(m.rating(for: "x", in: tagsOnly))
    }

    /// The UI reads the book, never the tapped level: the same level again clears (nil).
    func testTheSameLevelAgainClearsAndTheChangeSaysSo() async {
        let m = model(InMemoryStationRatingStore())
        await m.load()
        let first = m.rate(.like, song: Self.song("x"), in: Self.scope)
        XCTAssertEqual(first?.rating, .like)
        XCTAssertNil(first?.previous)
        let again = m.rate(.like, song: Self.song("x"), in: Self.scope)
        XCTAssertNotNil(again, "a change was made")
        XCTAssertNil(again?.rating, "toggled off")
        XCTAssertEqual(again?.previous?.rating, .like)
        XCTAssertNil(m.rating(for: "x", in: Self.scope))
    }

    /// A fresh rating the cap evicts at once comes back as a change with no rating, not a crash or a
    /// wrong state.
    func testAFreshRatingEvictedAtOnceReadsAsNotRated() async {
        let cap = StationRatingTuning.maxEntriesPerStation
        var book = StationRatingBook()
        for i in 0..<cap {
            book.rate(StationRatingEntry(songID: "l\(i)", artistName: "a", rating: .love, ratedDay: Self.today, origin: .catalog),
                      in: Self.scope, today: Self.today)
        }
        let m = model(InMemoryStationRatingStore(book: book))
        await m.load()
        let change = m.rate(.like, song: Self.song("fresh"), in: Self.scope)
        XCTAssertNotNil(change)
        XCTAssertNil(change?.rating, "evicted at once: the station is full of loves, a like goes first")
        XCTAssertNil(m.rating(for: "fresh", in: Self.scope))
        XCTAssertNil(SongRatingPresentation.toast(change!, skipped: false), "no toast for nothing")
    }

    func testUndoRestoresThePreviousRating() async {
        let m = model(InMemoryStationRatingStore())
        await m.load()
        let never = m.rate(.never, song: Self.song("x"), in: Self.scope)!
        m.undo(never)
        XCTAssertNil(m.rating(for: "x", in: Self.scope), "undo: not rated again")

        m.rate(.love, song: Self.song("y"), in: Self.scope)
        let change = m.rate(.never, song: Self.song("y"), in: Self.scope)!
        XCTAssertEqual(change.previous?.rating, .love)
        m.undo(change)
        XCTAssertEqual(m.rating(for: "y", in: Self.scope), .love, "undo: the love is back")
    }

    func testSavesLandInOrder() async throws {
        let m = model(store())
        await m.load()
        for level in [SongRating.love, .like, .tired, .never] { m.rate(level, song: Self.song("x"), in: Self.scope) }
        await m.flush()
        let saved = try await store().load()
        XCTAssertEqual(saved.rating(for: "x", in: Self.scope), .never, "the last edit wins on disk")
    }

    func testClearStationOnlyClearsThatStation() async throws {
        let other = StationRatingScope.recipe(UUID())
        let m = model(store())
        await m.load()
        m.rate(.like, song: Self.song("x"), in: Self.scope)
        m.rate(.like, song: Self.song("x"), in: other)
        m.clearStation(Self.scope)
        await m.flush()
        let saved = try await store().load()
        XCTAssertNil(saved.rating(for: "x", in: Self.scope))
        XCTAssertEqual(saved.rating(for: "x", in: other), .like)
    }

    /// Sentinel follow-up: both Settings "Clear all ratings" and a purge-all delete the file.
    func testClearAllDeletesTheFile() async throws {
        let m = model(store())
        await m.load()
        m.rate(.never, song: Self.song("x"), in: Self.scope)
        await m.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        m.rate(.love, song: Self.song("y"), in: Self.scope)   // a save still queued
        await m.clearAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "no file left, not even a queued save")
        XCTAssertNil(m.rating(for: "x", in: Self.scope))
        XCTAssertTrue(m.bias(recipeID: nil, configuration: Self.station).excludedSongIDs.isEmpty)
    }

    func testAPurgeAllDeletesTheFile() async throws {
        let feed = NarrationPurgeFeed()
        let m = model(store())
        await m.load()
        m.listen(to: feed)
        m.rate(.never, song: Self.song("x"), in: Self.scope)
        await m.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        feed.publish(.items([UUID()]))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(m.rating(for: "x", in: Self.scope), .never, "an item purge is not a purge-all")

        feed.publish(.all)
        for _ in 0..<500 where FileManager.default.fileExists(atPath: fileURL.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "purge-all deletes the file")
        XCTAssertNil(m.rating(for: "x", in: Self.scope))
    }

    func testTheModelsBiasIsTheFeedsInput() async {
        let m = model(InMemoryStationRatingStore())
        await m.load()
        m.rate(.never, song: Self.song("x"), in: Self.scope)
        XCTAssertEqual(m.bias(recipeID: nil, configuration: Self.station).excludedSongIDs, ["x"])
    }

    // MARK: Scope

    func testTheRecipeScopeIsUsedOnlyWhileTheRecipeStillMatches() {
        let recipe = StationRecipe(name: "Mine", configuration: Self.station)
        XCTAssertEqual(StationRatingScope.recipeID(lastApplied: recipe.id, recipes: [recipe], committed: Self.station),
                       recipe.id)
        XCTAssertNil(StationRatingScope.recipeID(lastApplied: nil, recipes: [recipe], committed: Self.station))
        XCTAssertNil(StationRatingScope.recipeID(lastApplied: recipe.id, recipes: [], committed: Self.station),
                     "deleted recipe: the seeds")
        let edited = StationConfiguration(seeds: [StationSeed(kind: .artist, catalogID: "other", name: "O", source: .catalog)])
        XCTAssertNil(StationRatingScope.recipeID(lastApplied: recipe.id, recipes: [recipe], committed: edited),
                     "seeds changed since the recipe: the seeds")
        XCTAssertNil(StationRatingScope.recipeID(lastApplied: recipe.id, recipes: [recipe],
                                                 committed: StationConfiguration(genres: ["jazz"])))
    }

    // MARK: Break drop

    func testABreakDropCoversBothBoundariesThatCanNameTheSong() {
        XCTAssertEqual(StationRatingBreakDrop.boundaries(forUpcoming: [5], playing: 2), [4, 5])
        XCTAssertEqual(StationRatingBreakDrop.boundaries(forUpcoming: [3, 4, 9], playing: 2), [2, 3, 4, 8, 9])
        XCTAssertEqual(StationRatingBreakDrop.boundaries(forUpcoming: [3], playing: 3), [3],
                       "the boundary before the playing song has passed")
        XCTAssertEqual(StationRatingBreakDrop.boundaries(forUpcoming: [0], playing: -1), [0])
        XCTAssertEqual(StationRatingBreakDrop.boundaries(forUpcoming: [], playing: 0), [])
    }

    // MARK: Presentation (scope §3)

    func testSymbolsAndCopy() {
        XCTAssertEqual(SongRatingPresentation.symbol(nil), "star")
        XCTAssertEqual(SongRatingPresentation.symbol(.tired), "moon.zzz")
        XCTAssertEqual(SongRatingPresentation.symbol(.never), "nosign")
        XCTAssertEqual(SongRatingPresentation.symbol(.like), "plus.circle")
        XCTAssertEqual(SongRatingPresentation.symbol(.love), "heart.fill")
        XCTAssertNotEqual(SongRatingPresentation.symbol(nil), SongRatingPresentation.symbol(.love))
        XCTAssertEqual(SongRatingPresentation.title(.tired), "Tired of it")
        XCTAssertEqual(SongRatingPresentation.title(.never), "Never play on this station")
        XCTAssertEqual(SongRatingPresentation.title(.like), "Like it")
        XCTAssertEqual(SongRatingPresentation.title(.love), "More like this")
        XCTAssertEqual(SongRatingPresentation.clearTitle, "Clear rating")
        XCTAssertEqual(SongRatingPresentation.accessibilityLabel(.like), "Rate song, current: Like it")
        XCTAssertEqual(SongRatingPresentation.accessibilityLabel(nil), "Rate song, current: not rated")
        XCTAssertEqual(SongRatingPresentation.firstTimeLabel, "Rate")
        XCTAssertEqual(Set(SongRatingPresentation.menuOrder), Set(SongRating.allCases))
    }

    func testOnlyANeverShowsTheUndoToast() {
        func change(_ r: SongRating?) -> StationRatingChange {
            StationRatingChange(scope: Self.scope, songID: "x", previous: nil, rating: r)
        }
        XCTAssertEqual(SongRatingPresentation.toast(change(.never), skipped: true), "Skipped. Won't play on this station again.")
        XCTAssertEqual(SongRatingPresentation.toast(change(.never), skipped: false), "Won't play on this station again.")
        for r in [SongRating.tired, .like, .love] { XCTAssertNil(SongRatingPresentation.toast(change(r), skipped: false)) }
        XCTAssertNil(SongRatingPresentation.toast(change(nil), skipped: false))
    }
}

/// The rating button's logic (`SongRatingController`), with recorded hooks.
@MainActor
final class SongRatingControllerTests: XCTestCase {
    private static let station = StationConfiguration(seeds: [StationSeed(kind: .artist, catalogID: "first", name: "First",
                                                                          source: .catalog)])
    private static var scope: StationRatingScope { StationRatingScope(recipeID: nil, configuration: station)! }

    @MainActor private final class Calls {
        var log: [String] = []
        var playing: String? = "now"
        var scope: StationRatingScope? = SongRatingControllerTests.scope
    }

    private func controller(_ calls: Calls, loaded: Bool = true) async -> (SongRatingController, UserDefaults) {
        let ratings = StationRatingsModel(store: InMemoryStationRatingStore(), today: { 42 })
        if loaded { await ratings.load() }
        let suite = "ratings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let hooks = SongRatingController.Hooks(
            scope: { calls.scope },
            playingSongID: { calls.playing },
            origin: { _ in .catalog },
            artistID: { "aid-\($0)" },
            skipPlaying: { calls.log.append("skip") },
            ratingsChanged: { calls.log.append("changed") })
        return (SongRatingController(ratings: ratings, hooks: hooks, defaults: defaults), defaults)
    }

    func testNeverOnThePlayingSongSkipsItAfterTheBreaksAreDroppedAndOffersUndo() async {
        let calls = Calls()
        let (c, _) = await controller(calls)
        let change = await c.rate(.never, songID: "now", artistName: "A")
        XCTAssertEqual(change?.rating, .never)
        XCTAssertEqual(calls.log, ["changed", "skip"], "breaks dropped (queue rebuilt) before the skip")
        XCTAssertEqual(c.toast?.message, "Skipped. Won't play on this station again.")
        XCTAssertEqual(c.rating(for: "now"), .never)
        XCTAssertEqual(c.ratings.book.ratings(for: Self.scope).entries["now"]?.artistID, "aid-now")
        XCTAssertEqual(c.ratings.book.ratings(for: Self.scope).entries["now"]?.origin, .catalog)

        await c.undo()
        XCTAssertNil(c.toast)
        XCTAssertNil(c.rating(for: "now"), "undo clears the rating")
        XCTAssertEqual(calls.log, ["changed", "skip", "changed"], "undo never skips back or again")
    }

    func testNeverOnAQueuedSongDoesNotSkipThePlayingOne() async {
        let calls = Calls()
        let (c, _) = await controller(calls)
        await c.rate(.never, songID: "later", artistName: "A")
        XCTAssertEqual(calls.log, ["changed"])
        XCTAssertEqual(c.toast?.message, "Won't play on this station again.")
    }

    func testTiredLikeAndLoveNeverSkipOrToast() async {
        let calls = Calls()
        let (c, _) = await controller(calls)
        for level in [SongRating.tired, .like, .love] {
            await c.rate(level, songID: "now", artistName: "A")
            XCTAssertEqual(c.rating(for: "now"), level)
        }
        XCTAssertFalse(calls.log.contains("skip"))
        XCTAssertNil(c.toast)
    }

    /// `rate` coming back with no rating (a toggle, an eviction) or nil (nothing changed) never
    /// skips and never shows a wrong state.
    func testATapThatClearsOrChangesNothingNeverSkips() async {
        let calls = Calls()
        let (c, _) = await controller(calls)
        await c.rate(.never, songID: "later", artistName: "A")
        calls.log = []
        calls.playing = "later"
        let again = await c.rate(.never, songID: "later", artistName: "A")
        XCTAssertNil(again?.rating, "toggled off")
        XCTAssertEqual(calls.log, ["changed"], "no skip for a cleared never")
        XCTAssertNil(c.rating(for: "later"))

        calls.scope = nil
        calls.log = []
        let none = await c.rate(.never, songID: "later", artistName: "A")
        XCTAssertNil(none)
        XCTAssertEqual(calls.log, [], "a tags-only station: nothing happens")
        XCTAssertFalse(c.isAvailable, "and no button")
    }

    func testTheButtonIsHiddenUntilRatingsLoad() async {
        let calls = Calls()
        let (c, _) = await controller(calls, loaded: false)
        XCTAssertFalse(c.isAvailable)
        let change = await c.rate(.never, songID: "now", artistName: "A")
        XCTAssertNil(change)
        XCTAssertEqual(calls.log, [])
        await c.ratings.load()
        XCTAssertTrue(c.isAvailable)
    }

    func testTheFirstTimeLabelGoesAfterTheFirstRatingAndStaysGone() async {
        let calls = Calls()
        let (c, defaults) = await controller(calls)
        XCTAssertFalse(c.labelSeen)
        await c.rate(.like, songID: "x", artistName: "A")
        XCTAssertTrue(c.labelSeen)
        XCTAssertTrue(defaults.bool(forKey: SongRatingPresentation.labelSeenKey))
        let again = SongRatingController(ratings: c.ratings, hooks: .init(scope: { Self.scope }), defaults: defaults)
        XCTAssertTrue(again.labelSeen, "remembered on this device")
    }

    func testAnOldToastsTimerNeverHidesANewerToast() async {
        let calls = Calls()
        let (c, _) = await controller(calls)
        await c.rate(.never, songID: "a", artistName: "A")
        let first = c.toast!.id
        await c.rate(.never, songID: "b", artistName: "B")
        c.dismissToast(id: first)
        XCTAssertNotNil(c.toast)
        c.dismissToast(id: c.toast!.id)
        XCTAssertNil(c.toast)
    }

    func testClearStationClearAllAndDeletingAStation() async {
        let calls = Calls()
        let (c, _) = await controller(calls)
        await c.rate(.love, songID: "x", artistName: "A")
        await c.clearStation()
        XCTAssertNil(c.rating(for: "x"))
        let recipe = UUID()
        c.ratings.rate(.never, song: StationRatedSong(songID: "y", artistName: "B"), in: .recipe(recipe))
        c.stationDeleted(recipeID: recipe)
        XCTAssertNil(c.ratings.rating(for: "y", in: .recipe(recipe)))
        await c.rate(.never, songID: "z", artistName: "C")
        await c.clearAll()
        XCTAssertNil(c.rating(for: "z"))
        XCTAssertNil(c.toast)
        XCTAssertEqual(calls.log.last, "changed", "the queue rebuilds after a clear")
    }
}
