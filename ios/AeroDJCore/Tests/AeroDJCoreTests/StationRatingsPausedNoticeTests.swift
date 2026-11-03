import Foundation
import XCTest
@testable import AeroDJCore

/// #388 (-Nova). Sentinel's #389 N1: while a purge-all still waits for its delete (ratings locked),
/// Settings says so next to "Clear all ratings" instead of staying silent. Fry's #387 Debug nit: the
/// Test Station and fixture ratings models never share the live pending-purge flag.
@MainActor
final class StationRatingsPausedNoticeTests: XCTestCase {
    private static let station = StationConfiguration(seeds: [StationSeed(kind: .artist, catalogID: "first", name: "First",
                                                                          source: .catalog)])
    private static var scope: StationRatingScope { StationRatingScope(recipeID: nil, configuration: station)! }

    /// Deleting fails until `failing` is turned off.
    private actor FlakyDeleteStore: StationRatingStore {
        private(set) var book = StationRatingBook()
        var failing = true
        func load() async throws -> StationRatingBook { book }
        func save(_ book: StationRatingBook) async throws { self.book = book }
        func deleteAll() async throws {
            if failing { throw StationRatingStoreError.deleteFailed }
            book = StationRatingBook()
        }
        func setFailing(_ on: Bool) { failing = on }
    }

    private func suite() -> UserDefaults { UserDefaults(suiteName: "ratings-\(UUID().uuidString)")! }

    private func notice(_ m: StationRatingsModel, failed: Bool = false) -> SongRatingPresentation.ClearAllNotice? {
        SongRatingPresentation.clearAllNotice(pausedUntilCleared: m.isPausedUntilCleared, clearFailed: failed)
    }

    func testALoadedBookIsNotPausedAndSettingsShowsNothing() async {
        let m = StationRatingsModel(store: FlakyDeleteStore(), today: { 42 }, defaults: suite())
        XCTAssertFalse(m.isPausedUntilCleared, "not loaded yet")
        await m.load()
        XCTAssertFalse(m.isPausedUntilCleared)
        XCTAssertNil(notice(m), "no new line: the Settings footer is unchanged")
    }

    func testAPurgeWhoseDeleteFailsIsPausedAcrossARelaunchUntilAClearWorks() async {
        let store = FlakyDeleteStore()
        let defaults = suite()
        let first = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        await first.load()
        let purged = await first.purgeAll()
        XCTAssertFalse(purged)
        XCTAssertTrue(first.isPausedUntilCleared)
        XCTAssertEqual(notice(first), .pending)

        // The launch retry fails too: still paused, and Settings says so.
        let relaunched = StationRatingsModel(store: store, today: { 42 }, defaults: defaults)
        await relaunched.load()
        XCTAssertTrue(relaunched.isPausedUntilCleared)
        XCTAssertEqual(notice(relaunched), .pending)
        XCTAssertFalse(relaunched.canRate)

        // A failed "Clear all" tap is that retry: one line, the paused one, not two.
        let cleared = await relaunched.clearAll()
        XCTAssertFalse(cleared)
        XCTAssertEqual(notice(relaunched, failed: !cleared), .pending)

        await store.setFailing(false)
        let retried = await relaunched.clearAll()
        XCTAssertTrue(retried)
        XCTAssertFalse(relaunched.isPausedUntilCleared)
        XCTAssertNil(notice(relaunched, failed: !retried), "gone once the delete works")
        XCTAssertTrue(relaunched.canRate)
    }

    func testAFailedSettingsClearIsNotPausedAndShowsTheFailedLine() async {
        let m = StationRatingsModel(store: FlakyDeleteStore(), today: { 42 }, defaults: suite())
        await m.load()
        let cleared = await m.clearAll()
        XCTAssertFalse(cleared)
        XCTAssertFalse(m.isPausedUntilCleared, "a Settings clear rolls back; nothing is locked")
        XCTAssertEqual(notice(m, failed: !cleared), .failed)
    }

    func testTheControllerExposesThePausedStateToSettings() async {
        let store = FlakyDeleteStore()
        let ratings = StationRatingsModel(store: store, today: { 42 }, defaults: suite())
        await ratings.load()
        let c = SongRatingController(ratings: ratings, hooks: .init(scope: { Self.scope }), defaults: suite())
        await ratings.purgeAll()
        XCTAssertTrue(c.ratings.isPausedUntilCleared)
        await store.setFailing(false)
        let cleared = await c.clearAll()
        XCTAssertTrue(cleared)
        XCTAssertFalse(c.ratings.isPausedUntilCleared)
    }

    func testTheNoticeCopyAndIdentifiers() {
        XCTAssertEqual(SongRatingPresentation.clearAllPending,
                       "Ratings are paused until they finish clearing. Try Clear all again.")
        XCTAssertFalse(SongRatingPresentation.clearAllPending.contains("\n"))
        XCTAssertEqual(SongRatingPresentation.ClearAllNotice.pending.text, SongRatingPresentation.clearAllPending)
        XCTAssertEqual(SongRatingPresentation.ClearAllNotice.failed.text, SongRatingPresentation.clearAllFailed)
        XCTAssertEqual(SongRatingPresentation.ClearAllNotice.pending.accessibilityIdentifier,
                       "settings.clearAllRatings.pending")
        XCTAssertEqual(SongRatingPresentation.ClearAllNotice.failed.accessibilityIdentifier,
                       "settings.clearAllRatings.failed")
        XCTAssertNil(SongRatingPresentation.clearAllNotice(pausedUntilCleared: false, clearFailed: false))
        XCTAssertEqual(SongRatingPresentation.clearAllNotice(pausedUntilCleared: false, clearFailed: true), .failed)
        XCTAssertEqual(SongRatingPresentation.clearAllNotice(pausedUntilCleared: true, clearFailed: false), .pending)
        XCTAssertEqual(SongRatingPresentation.clearAllNotice(pausedUntilCleared: true, clearFailed: true), .pending)
    }

    // MARK: Source scans (the app draws what the pure types decide)

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSettingsDrawsTheNoticeFromTheModel() throws {
        let source = try appSource("SongRatingControl.swift")
        XCTAssertTrue(source.contains("pausedUntilCleared: controller.ratings.isPausedUntilCleared"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(notice.accessibilityIdentifier)"))
        XCTAssertFalse(source.contains("Text(SongRatingPresentation.clearAllFailed)"), "one line, chosen by clearAllNotice")
    }

    func testDebugRatingsModelsUseTheirOwnDefaultsSuite() throws {
        let deps = try appSource("AppDependencies.swift")
        XCTAssertTrue(deps.contains("StationRatingsModel(store: InMemoryStationRatingStore(), defaults: ratingsDefaults)"))
        XCTAssertTrue(deps.contains("UserDefaults(suiteName: \"AeroDJRatingsTestStation\")"))
        let fixture = try appSource("SongRatingControl.swift")
        XCTAssertTrue(fixture.contains("StationRatingsModel(store: InMemoryStationRatingStore(), today: { 20_000 }, defaults: defaults)"))
        XCTAssertTrue(fixture.contains("UserDefaults(suiteName: \"AeroDJRatingsFixture\")"))
        let inMemory = (deps + fixture).components(separatedBy: "StationRatingsModel(store: InMemoryStationRatingStore()")
        for call in inMemory.dropFirst() {
            let args = call.prefix { $0 != "\n" }
            XCTAssertTrue(args.contains("defaults:"), "an in-memory ratings model must not use .standard: \(args)")
        }
    }

    /// Sentinel's #396 N1: the live app resets the DJ session and staged queue on purge-all.
    func testTheLiveAppWiresThePurgeReset() async throws {
        let deps = try appSource("AppDependencies.swift")
        XCTAssertTrue(deps.contains("ratings.resetOnPurge(session: djSession, rebuildQueue: { [weak stationQueue] in stationQueue?.ratingsPurged() })"))
        let queue = try appSource("StationQueuePlayer.swift")
        guard let start = queue.range(of: "func ratingsPurged() {") else { return XCTFail("ratingsPurged is gone") }
        let body = queue[start.upperBound...].prefix { $0 != "}" }
        XCTAssertTrue(body.contains("feed.ratingsChanged(station.committedDisplayed)"))
    }

    /// Sentinel's #396 N2: the talk-over rating log lines never reach a Release os_log, and carry
    /// codes and counts only.
    func testTheTalkoverRatingLogLinesAreDebugOnly() async throws {
        let source = try appSource("TalkoverCoordinator.swift")
        let lines = source.components(separatedBy: "\n")
        let markers = ["dj talkover faded, break dropped", "dj talkover lines dropped"]
        for marker in markers {
            let at = try XCTUnwrap(lines.firstIndex { $0.contains(marker) }, marker)
            XCTAssertEqual(lines.filter { $0.contains(marker) }.count, 1, marker)
            var depth = 0
            for line in lines[..<at] {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "#if DEBUG" { depth += 1 } else if t == "#endif", depth > 0 { depth -= 1 }
            }
            XCTAssertEqual(depth, 1, "\(marker) is inside #if DEBUG")
            let line = lines[at]
            for forbidden in ["title", "artist", "song", "rating", "id:", "ID"] {
                XCTAssertFalse(line.lowercased().contains(forbidden.lowercased()), "\(marker): \(forbidden)")
            }
        }
    }
}
