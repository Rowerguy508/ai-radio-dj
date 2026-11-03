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
        var failing = true
        let loadError: StationRatingStoreError?

        init(book: StationRatingBook = StationRatingBook(), loadError: StationRatingStoreError? = nil) {
            self.book = book
            self.loadError = loadError
        }

        func load() async throws -> StationRatingBook {
            if let loadError { throw loadError }
            return book
        }
        func save(_ book: StationRatingBook) async throws { self.book = book }
        func deleteAll() async throws {
            deletes += 1
            if failing { throw StationRatingStoreError.deleteFailed }
            book = StationRatingBook()
        }
        func setFailing(_ on: Bool) { failing = on }
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

    func testAPurgeAllWhoseDeleteFailsKeepsTheBookMatchingTheFile() async throws {
        let store = DeleteFailsStore(book: Self.savedBook())
        let m = StationRatingsModel(store: store, today: { 42 })
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
        let deletes = await store.deletes
        XCTAssertEqual(deletes, 1, "the purge tried to delete the file")
        XCTAssertEqual(m.rating(for: "x", in: Self.scope), .never, "not shown as cleared while the file still has it")
        let saved = await store.book
        XCTAssertEqual(m.book, saved)
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
        XCTAssertEqual(row.detail, "kind=breakDropped reason=ratingWithdrawn after=4 line=1 dropped=3 timeChecks=2 otherCues=1")
        let unknown = trace.breakInterruptionWithdrawn(StationRatingWithdrawnLines(line: 0, timeChecks: 0, other: 2),
                                                       afterTrack: nil, at: 3)
        XCTAssertEqual(unknown.detail, "kind=breakDropped reason=ratingWithdrawn after=- line=0 dropped=2 timeChecks=0 otherCues=2")
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
