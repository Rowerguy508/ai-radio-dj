import Foundation
import XCTest
@testable import AeroDJCore

/// #387 follow-ups (-Nova). Sentinel N1: a "Clear all ratings" (or purge-all) whose file delete
/// fails says so, and the book still matches the file. Echo N1: a break withdrawn by a rating
/// counts the lines it did not air, by kind, for the P0 trace.
@MainActor
final class StationRatingsNitsTests: XCTestCase {
    private static let station = StationConfiguration(seeds: [StationSeed(kind: .artist, catalogID: "first", name: "First",
                                                                          source: .catalog)])
    private static var scope: StationRatingScope { StationRatingScope(recipeID: nil, configuration: station)! }

    /// Saves work; deleting fails until `failing` is turned off (a locked or read-only folder).
    private actor DeleteFailsStore: StationRatingStore {
        private(set) var book: StationRatingBook
        private(set) var deletes = 0
        private(set) var loads = 0
        private(set) var saves = 0
        /// The pending-purge flag as each delete saw it (when `flagSuite` is given).
        private(set) var flagDuringDelete: [Bool] = []
        var failing = true
        let loadError: StationRatingStoreError?
        private let probe: FlagProbe?

        init(book: StationRatingBook = StationRatingBook(), loadError: StationRatingStoreError? = nil,
             probe: FlagProbe? = nil) {
            self.book = book
            self.loadError = loadError
            self.probe = probe
        }

        func load() async throws -> StationRatingBook {
            loads += 1
            if let loadError { throw loadError }
            return book
        }
        func save(_ book: StationRatingBook) async throws {
            saves += 1
            self.book = book
        }
        func deleteAll() async throws {
            deletes += 1
            if let probe { flagDuringDelete.append(await probe.read()) }
            if failing { throw StationRatingStoreError.deleteFailed }
            book = StationRatingBook()
        }
        func setFailing(_ on: Bool) { failing = on }
    }

    /// Reads the model's defaults from inside a store call.
    @MainActor private final class FlagProbe {
        let defaults: UserDefaults
        init(_ defaults: UserDefaults) { self.defaults = defaults }
        func read() -> Bool { defaults.bool(forKey: StationRatingsModel.purgePendingKey) }
    }

    private static func song(_ id: String) -> StationRatedSong {
        StationRatedSong(songID: id, artistName: "Artist \(id)", artistID: "aid-\(id)", origin: .catalog)
    }

    private static func savedBook() -> StationRatingBook {
        var book = StationRatingBook()
        book.rate(StationRatingEntry(songID: "x", artistName: "Artist x", artistID: nil, rating: .never, ratedDay: 42,
                                     origin: .catalog), in: scope, today: 42)
        return book
    }

    // MARK: Sentinel N1

    func testAClearAllWhoseDeleteFailsKeepsTheRatingsAndSaysSo() async {
        let store = DeleteFailsStore(book: Self.savedBook())
        let m = StationRatingsModel(store: store, today: { 42 })
        await m.load()
        m.rate(.love, song: Self.song("y"), in: Self.scope)   // a save still queued
        let cleared = await m.clearAll()
        XCTAssertFalse(cleared, "a failed delete is not reported as cleared")
        XCTAssertEqual(m.rating(for: "x", in: Self.scope), .never)
        XCTAssertEqual(m.rating(for: "y", in: Self.scope), .love)
        XCTAssertEqual(m.bias(recipeID: nil, configuration: Self.station).excludedSongIDs, ["x"], "still in effect")
        let saved = await store.book
        XCTAssertEqual(m.book, saved, "the book in memory is the one in the file")
        XCTAssertEqual(m.loadState, .loaded)
        XCTAssertTrue(m.canRate)
        let deletes = await store.deletes
        XCTAssertEqual(deletes, 1)

        await store.setFailing(false)
        let retried = await m.clearAll()
        XCTAssertTrue(retried, "trying again works once the file can be deleted")
        XCTAssertNil(m.rating(for: "x", in: Self.scope))
        XCTAssertNil(m.rating(for: "y", in: Self.scope))
        let after = await store.book
        XCTAssertEqual(after, StationRatingBook())
    }

    /// A read-only book (a file this build cannot read) stays read-only when the delete fails, so
    /// that file is still never overwritten.
    func testAFailedClearAllOfAReadOnlyBookStaysReadOnly() async {
        let m = StationRatingsModel(store: DeleteFailsStore(loadError: .newerVersion), today: { 42 })
        await m.load()
        XCTAssertEqual(m.loadState, .readOnly)
        let cleared = await m.clearAll()
        XCTAssertFalse(cleared)
        XCTAssertEqual(m.loadState, .readOnly)
        XCTAssertNil(m.rate(.love, song: Self.song("y"), in: Self.scope), "still nothing saved over that file")
    }

    // MARK: Sentinel N1 follow-up: a purge-all always goes through

    private func suite() -> UserDefaults { UserDefaults(suiteName: "ratings-\(UUID().uuidString)")! }

    func testAFailedPurgeAllEmptiesAndLocksTheBookAndRefusesRating() async {
        let store = DeleteFailsStore(book: Self.savedBook())
        let defaults = suite()
        let m = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        await m.load()
        XCTAssertEqual(m.rating(for: "x", in: Self.scope), .never)
        let purged = await m.purgeAll()
        XCTAssertFalse(purged)
        XCTAssertEqual(m.book, StationRatingBook(), "the withdrawal goes through in memory")
        XCTAssertTrue(m.bias(recipeID: nil, configuration: Self.station).excludedSongIDs.isEmpty,
                      "ratings stop steering the queue at once")
        XCTAssertEqual(m.loadState, .purgePending)
        XCTAssertFalse(m.canRate)
        XCTAssertTrue(m.purgePending)
        XCTAssertTrue(defaults.bool(forKey: StationRatingsModel.purgePendingKey))
        XCTAssertNil(m.rate(.love, song: Self.song("y"), in: Self.scope), "rating is refused")
        m.clearStation(Self.scope)
        await m.flush()
        let saved = await store.book
        XCTAssertEqual(saved, Self.savedBook(), "nothing saved while pending (the file is never rewritten)")
        let saves = await store.saves
        XCTAssertEqual(saves, 0)
    }

    func testAPurgeAllFromTheFeedNeverRollsBack() async throws {
        let store = DeleteFailsStore(book: Self.savedBook())
        let m = StationRatingsModel(store: store, today: { 42 }, defaults: suite())
        await m.load()
        let feed = NarrationPurgeFeed()
        m.listen(to: feed)
        for _ in 0..<50 { await Task.yield() }
        feed.publish(.all)
        for _ in 0..<500 where await store.deletes == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        await m.flush()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(m.rating(for: "x", in: Self.scope), "not put back: the purge stands")
        XCTAssertEqual(m.loadState, .purgePending)
        XCTAssertTrue(m.purgePending)
    }

    func testARelaunchWhoseDeleteStillFailsStaysLockedAndNeverLoadsTheOldRatings() async {
        let store = DeleteFailsStore(book: Self.savedBook())
        let defaults = suite()
        let first = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        await first.load()
        await first.purgeAll()
        let loadsBefore = await store.loads

        let relaunched = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        await relaunched.load()
        let loads = await store.loads
        XCTAssertEqual(loads, loadsBefore, "the old file is never read")
        let deletes = await store.deletes
        XCTAssertEqual(deletes, 2, "the delete was retried at load")
        XCTAssertEqual(relaunched.loadState, .purgePending)
        XCTAssertEqual(relaunched.book, StationRatingBook())
        XCTAssertNil(relaunched.rating(for: "x", in: Self.scope))
        XCTAssertNil(relaunched.rate(.love, song: Self.song("y"), in: Self.scope))
        XCTAssertTrue(defaults.bool(forKey: StationRatingsModel.purgePendingKey))

        // Settings "Clear all" while pending is a retry too, and stays locked while it fails.
        let cleared = await relaunched.clearAll()
        XCTAssertFalse(cleared)
        XCTAssertEqual(relaunched.loadState, .purgePending)
        XCTAssertEqual(relaunched.book, StationRatingBook(), "no rollback to the old ratings")
        XCTAssertTrue(relaunched.purgePending)
    }

    func testARelaunchWhoseDeleteWorksClearsTheFlagAndUnlocks() async {
        let store = DeleteFailsStore(book: Self.savedBook())
        let defaults = suite()
        let first = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        await first.load()
        await first.purgeAll()
        await store.setFailing(false)

        let relaunched = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        await relaunched.load()
        XCTAssertEqual(relaunched.loadState, .loaded)
        XCTAssertFalse(relaunched.purgePending)
        XCTAssertNil(defaults.object(forKey: StationRatingsModel.purgePendingKey))
        XCTAssertEqual(relaunched.book, StationRatingBook())
        let saved = await store.book
        XCTAssertEqual(saved, StationRatingBook(), "the old ratings are gone")
        XCTAssertNotNil(relaunched.rate(.love, song: Self.song("y"), in: Self.scope), "rating works again")
        await relaunched.flush()
        let after = await store.book
        XCTAssertEqual(after.rating(for: "y", in: Self.scope), .love)
    }

    func testALaterClearRetriesAPendingPurgeAndUnlocks() async {
        let store = DeleteFailsStore(book: Self.savedBook())
        let defaults = suite()
        let m = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        await m.load()
        await m.purgeAll()
        await store.setFailing(false)
        let cleared = await m.clearAll()
        XCTAssertTrue(cleared)
        XCTAssertEqual(m.loadState, .loaded)
        XCTAssertFalse(m.purgePending)
    }

    /// The flag is set before the delete starts and is still set while it runs (so a crash or a
    /// failure mid-delete retries), and is removed only once a delete has worked.
    func testThePendingFlagIsNeverClearedBeforeTheFileIsGone() async {
        let defaults = suite()
        let store = DeleteFailsStore(book: Self.savedBook(), probe: FlagProbe(defaults))
        let m = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        await m.load()
        await m.purgeAll()
        var seen = await store.flagDuringDelete
        XCTAssertEqual(seen, [true], "set before the failed delete")
        XCTAssertTrue(defaults.bool(forKey: StationRatingsModel.purgePendingKey), "kept after it failed")

        await store.setFailing(false)
        await m.purgeAll()
        seen = await store.flagDuringDelete
        XCTAssertEqual(seen, [true, true], "still set while the working delete ran")
        XCTAssertFalse(defaults.bool(forKey: StationRatingsModel.purgePendingKey), "removed after it")

        // A successful purge also sets it first.
        let fresh = DeleteFailsStore(probe: FlagProbe(defaults))
        await fresh.setFailing(false)
        let other = StationRatingsModel(store: fresh, today: { 42 }, defaults: defaults)
        await other.load()
        let purged = await other.purgeAll()
        XCTAssertTrue(purged)
        let freshSeen = await fresh.flagDuringDelete
        XCTAssertEqual(freshSeen, [true])
        XCTAssertFalse(other.purgePending)
    }

    /// Settings "Clear all" (not a purge) still rolls back, and never sets the flag.
    func testSettingsClearAllNeverSetsThePendingFlag() async {
        let defaults = suite()
        let m = StationRatingsModel(store: DeleteFailsStore(book: Self.savedBook()), today: { 42 }, defaults: defaults)
        await m.load()
        let cleared = await m.clearAll()
        XCTAssertFalse(cleared)
        XCTAssertEqual(m.rating(for: "x", in: Self.scope), .never)
        XCTAssertNil(defaults.object(forKey: StationRatingsModel.purgePendingKey))
    }

    func testTheControllerReportsAFailedClearAllForSettings() async {
        let store = DeleteFailsStore()
        let ratings = StationRatingsModel(store: store, today: { 42 })
        await ratings.load()
        var log: [String] = []
        let hooks = SongRatingController.Hooks(
            scope: { Self.scope }, playingSongID: { "now" }, origin: { _ in .catalog }, artistID: { "aid-\($0)" },
            skipPlaying: { log.append("skip") }, ratingsChanged: { log.append("changed") })
        let c = SongRatingController(ratings: ratings, hooks: hooks,
                                     defaults: UserDefaults(suiteName: "ratings-\(UUID().uuidString)")!)
        await c.rate(.love, songID: "z", artistName: "C")
        let cleared = await c.clearAll()
        XCTAssertFalse(cleared, "Settings shows the error, not success")
        XCTAssertEqual(c.rating(for: "z"), .love, "the rating is still there")
        XCTAssertNil(c.toast)
        XCTAssertEqual(log.last, "changed")

        await store.setFailing(false)
        let retried = await c.clearAll()
        XCTAssertTrue(retried)
        XCTAssertNil(c.rating(for: "z"))
    }

    func testTheFailedClearCopyIsShort() {
        XCTAssertEqual(SongRatingPresentation.clearAllFailed, "Couldn't clear ratings. Try again.")
        XCTAssertLessThanOrEqual(SongRatingPresentation.clearAllFailed.count, 40)
    }

    // MARK: Echo N1

    private func timeCheck() -> BreakResumeLine {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let check = DJPlannedTimeCheck(cueID: UUID(), plannedAt: Date(timeIntervalSince1970: 0),
                                       templates: [.on: "It's {time}."], calendar: calendar, style: .twentyFourHour)
        return BreakResumeLine(seconds: 2, sensitivity: .timeCheck(check, text: "It's 00:00.", airTime: nil))
    }

    func testAWithdrawnBreakCountsTheLinesItDidNotAirByKind() {
        let lines = [BreakResumeLine(seconds: 3), timeCheck(), BreakResumeLine(seconds: 4), timeCheck()]
        XCTAssertEqual(StationRatingWithdrawnLines.remaining(lines, from: 1),
                       StationRatingWithdrawnLines(line: 1, timeChecks: 2, other: 1))
        XCTAssertEqual(StationRatingWithdrawnLines.remaining(lines, from: 0).count, 4)
        XCTAssertEqual(StationRatingWithdrawnLines.remaining(lines, from: 3),
                       StationRatingWithdrawnLines(line: 3, timeChecks: 1, other: 0))
        XCTAssertEqual(StationRatingWithdrawnLines.remaining(lines, from: 4).count, 0, "past the end: nothing")
        XCTAssertEqual(StationRatingWithdrawnLines.remaining(lines, from: -1).count, 0)
    }

    #if DEBUG || AERODJ_P0_DIAG
    /// Same row as #379's `breakInterruptionDrop`: codes and counts only, never a title or ID.
    func testTheWithdrawnRowMatchesTheBreakInterruptionRows() {
        var trace = P0EventTrace()
        let row = trace.breakInterruptionWithdrawn(StationRatingWithdrawnLines(line: 1, timeChecks: 2, other: 1),
                                                   afterTrack: 4, at: 2)
        XCTAssertEqual(row.event, .breakInterruption)
        XCTAssertEqual(row.detail, "kind=breakDropped reason=ratingWithdrawn after=4 line=1 dropped=3 timeChecks=2 otherCues=1 briefingCues=0")
        let unknown = trace.breakInterruptionWithdrawn(StationRatingWithdrawnLines(line: 0, timeChecks: 0, other: 2),
                                                       afterTrack: nil, at: 3)
        XCTAssertEqual(unknown.detail, "kind=breakDropped reason=ratingWithdrawn after=- line=0 dropped=2 timeChecks=0 otherCues=2 briefingCues=0")
        let codes = Set(P0TraceCode.allCases.map(\.rawValue))
        for row in [row, unknown] {
            for pair in row.detail.split(separator: " ") {
                let value = String(pair.split(separator: "=", maxSplits: 1)[1])
                XCTAssertTrue(Int(value) != nil || value == "-" || codes.contains(value), "\(pair) is a number or a code")
            }
        }
        XCTAssertNil(BreakResumeDrop.Reason(rawValue: P0TraceCode.ratingWithdrawn.rawValue),
                     "its own code, never mistaken for a #379 drop reason")
    }
    #endif
}
