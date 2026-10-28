import XCTest
@testable import AeroDJCore

/// Silent play-tap exits that used to swallow a song-row tap (P0 build 7 / #109 tip).
final class PlayTapResolverTests: XCTestCase {
    func testOrderedSliceSurvivesSecondLiveConstruction() {
        // MusicSearch.live used to allocate a new cache per body render. The app-scoped
        // cache is the same instance across two "live" constructions; store once, resolve twice.
        let ordered = ["a", "b", "c"]
        let available = Set(ordered)
        let first = PlayTapResolver.resolveIDs(
            allResultIDs: ordered, startIndex: 1, orderedIDs: ordered, available: available)
        let second = PlayTapResolver.resolveIDs(
            allResultIDs: ordered, startIndex: 1, orderedIDs: ordered, available: available)
        XCTAssertEqual(first, .success(["b", "c"]))
        XCTAssertEqual(second, .success(["b", "c"]), "a re-render must not clear an app-scoped cache")
    }

    func testOutOfRangeStartIndexFails() {
        let ids = ["a", "b"]
        let result = PlayTapResolver.resolveIDs(
            allResultIDs: ids, startIndex: 2, orderedIDs: ids, available: Set(ids))
        XCTAssertEqual(result, .failure(.startIndexOutOfRange))
    }

    func testEmptyResolveWhenCacheMissesFails() {
        let shown = ["a", "b", "c"]
        // A later search replaced the cache: ordered/available no longer match the UI rows.
        let result = PlayTapResolver.resolveIDs(
            allResultIDs: shown, startIndex: 0, orderedIDs: ["x", "y"], available: ["x", "y"])
        XCTAssertEqual(result, .failure(.tracksUnavailable))
    }

    func testFallbackCompactMapWhenOrderedDivergesButIDsRemain() {
        let shown = ["a", "b", "c"]
        let available: Set<String> = ["b", "c", "z"]
        let result = PlayTapResolver.resolveIDs(
            allResultIDs: shown, startIndex: 1, orderedIDs: ["z"], available: available)
        XCTAssertEqual(result, .success(["b", "c"]))
    }

    func testTappedSongMissingFailsEvenIfLaterRowsResolve() {
        // Sentinel P2: a stale cache must never start a different song than the one tapped.
        let shown = ["a", "b", "c"]
        let result = PlayTapResolver.resolveIDs(
            allResultIDs: shown, startIndex: 0, orderedIDs: ["b", "c"], available: ["b", "c"])
        XCTAssertEqual(result, .failure(.tracksUnavailable))
    }

    func testEmptyQueueStartedDoesNotClaimPreparing() {
        // Defense: even if a caller wrongly forwards [], the engine must not show .preparing.
        var e = PlaybackEngine()
        e.apply(.queueStarted(tracks: [], startIndex: 0, station: nil))
        XCTAssertEqual(e.snapshot.transport, .stopped)
        XCTAssertNil(e.snapshot.nowPlaying)
        e.apply(.errorRaised(PlaybackError(
            kind: .playbackFailed,
            message: PlaybackFailureCopy.message(for: .nothingToPlay),
            isRecoverable: true)))
        XCTAssertEqual(e.snapshot.error?.kind, .playbackFailed)
        XCTAssertEqual(e.snapshot.error?.message, "There's nothing to play yet. Pick a song to start listening.")
    }

    func testResumeWithNothingQueuedSurfacesRecoverableError() {
        // Mirrors MusicKitService.resume on an empty queue: raise before any prepare/play.
        var e = PlaybackEngine()
        XCTAssertEqual(e.snapshot.transport, .stopped)
        e.apply(.errorRaised(PlaybackError(
            kind: .resumeFailed,
            message: PlaybackFailureCopy.message(for: .nothingToResume),
            isRecoverable: true)))
        XCTAssertEqual(e.snapshot.error?.kind, .resumeFailed)
        XCTAssertEqual(e.snapshot.transport, .stopped, "resume must not leave a preparing spinner")
        XCTAssertEqual(e.snapshot.error?.message, "Nothing is queued. Pick a song to start listening.")
    }
}
