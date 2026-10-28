#if DEBUG || AERODJ_P0_DIAG
import XCTest
@testable import AeroDJCore

/// P0 Experiment A (-Atlas): Direct Mode's state machine. Deterministic: time is passed in.
final class DirectModeMachineTests: XCTestCase {

    private func loaded() -> DirectModeMachine {
        var m = DirectModeMachine(songCount: 2)
        XCTAssertTrue(m.request(.load, at: 0))
        m.finished(.load, error: nil, at: 0.1)
        return m
    }

    func testNothingButLoadRunsBeforeTheQueueIsSet() {
        var m = DirectModeMachine(songCount: 2)
        for c in [DirectModeCommand.play, .resume, .next] {
            XCTAssertFalse(m.request(c, at: 0))
        }
        XCTAssertFalse(m.request(.pause, at: 0))
        XCTAssertNil(m.inFlight)
        XCTAssertTrue(m.request(.load, at: 0))
    }

    func testOnlyOneCommandInFlightAndTapsWhileBusyAreRefusedNotQueued() {
        var m = loaded()
        XCTAssertTrue(m.request(.play, at: 1))
        XCTAssertFalse(m.request(.play, at: 1.1), "a double tap is refused")
        XCTAssertFalse(m.request(.next, at: 1.2))
        XCTAssertEqual(m.inFlight, .play)
        m.finished(.play, error: nil, at: 1.5)
        XCTAssertNil(m.inFlight)
        XCTAssertTrue(m.log.contains { if case .refused(.play, "busy.play") = $0.kind { true } else { false } })
    }

    func testLoadIsOnceOnly() {
        var m = loaded()
        XCTAssertFalse(m.request(.load, at: 1), "the queue is set exactly once")
    }

    func testPlayingLatchAndPositionAdvance() {
        var m = loaded()
        m.request(.play, at: 1)
        m.observe(status: .paused, position: 0, entryIndex: 0, at: 1.2)
        XCTAssertFalse(m.everPlaying)
        m.observe(status: .playing, position: 0.2, entryIndex: 0, at: 1.4)
        XCTAssertTrue(m.everPlaying)
        XCTAssertFalse(m.positionEverAdvanced, "0.2 s is not past 0:00 yet")
        m.observe(status: .playing, position: 1.6, entryIndex: 0, at: 3)
        XCTAssertTrue(m.positionEverAdvanced)
        m.observe(status: .paused, position: 1.7, entryIndex: 0, at: 4)
        XCTAssertTrue(m.everPlaying, "the latch never clears")
    }

    func testPositionMovingWhilePausedDoesNotCountAsAdvanced() {
        var m = loaded()
        m.observe(status: .paused, position: 5, entryIndex: 0, at: 1)
        XCTAssertFalse(m.positionEverAdvanced)
        XCTAssertFalse(m.everPlaying)
    }

    func testPauseAndResumeFollowObservedStatusOnly() {
        var m = loaded()
        XCTAssertFalse(m.request(.pause, at: 1), "not playing yet")
        m.request(.play, at: 1); m.finished(.play, error: nil, at: 1.1)
        XCTAssertFalse(m.request(.pause, at: 1.2), "play() returned, but .playing not observed yet")
        m.observe(status: .playing, position: 0.5, entryIndex: 0, at: 1.3)
        XCTAssertTrue(m.request(.pause, at: 2)); m.finished(.pause, error: nil, at: 2.1)
        XCTAssertFalse(m.request(.resume, at: 2.2), "resume waits for observed .paused")
        m.observe(status: .paused, position: 1, entryIndex: 0, at: 2.3)
        XCTAssertTrue(m.request(.resume, at: 3))
    }

    func testNextOnlyFromTheFirstSong() {
        var m = loaded()
        XCTAssertTrue(m.request(.next, at: 1)); m.finished(.next, error: nil, at: 1.2)
        m.observe(status: .playing, position: 0.1, entryIndex: 1, at: 1.3)
        XCTAssertEqual(m.entryIndex, 1)
        XCTAssertFalse(m.request(.next, at: 2), "no third song")
        XCTAssertFalse(m.unexpectedQueueSeen)
    }

    func testForeignEntryIsFlaggedAsUnexpectedQueueReplacement() {
        var m = loaded()
        m.observe(status: .playing, position: 3, entryIndex: nil, at: 5)
        XCTAssertTrue(m.unexpectedQueueSeen)
        XCTAssertFalse(m.request(.next, at: 6))
    }

    func testFailureIsRecordedWithCodeOnlyAndFreesTheController() {
        var m = loaded()
        m.request(.play, at: 1)
        let code = PlaybackErrorCode(typeName: "MusicPlayer.Error", domain: "MPErrorDomain", code: 4)
        m.finished(.play, error: code, at: 1.4)
        XCTAssertNil(m.inFlight)
        XCTAssertEqual(m.lastError, code)
        XCTAssertEqual(m.log.last?.description, "+1.40s pos=0.0 stopped cmd.play.threw MusicPlayer.Error MPErrorDomain code 4")
        XCTAssertTrue(m.request(.play, at: 2), "the user can retry")
    }

    func testFailedLoadLeavesQueueUnloaded() {
        var m = DirectModeMachine(songCount: 2)
        m.request(.load, at: 0)
        m.finished(.load, error: PlaybackErrorCode(typeName: "E", domain: "D", code: 1), at: 0.1)
        XCTAssertFalse(m.queueLoaded)
        XCTAssertTrue(m.request(.load, at: 1))
    }

    func testStaleFinishForAnotherCommandIsIgnored() {
        var m = loaded()
        m.request(.play, at: 1)
        m.finished(.pause, error: nil, at: 1.1)
        XCTAssertEqual(m.inFlight, .play)
    }

    func testStatusTransitionsAreLoggedOncePerChange() {
        var m = loaded()
        let before = m.log.count
        m.observe(status: .playing, position: 0.1, entryIndex: 0, at: 1)
        m.observe(status: .playing, position: 0.6, entryIndex: 0, at: 1.5)
        m.observe(status: .playing, position: 1.1, entryIndex: 0, at: 2)
        let kinds = m.log.dropFirst(before).map(\.description)
        XCTAssertEqual(kinds.filter { $0.hasSuffix("status=playing") }.count, 1)
        XCTAssertEqual(kinds.filter { $0.hasSuffix("PLAYING.reached") }.count, 1)
        XCTAssertEqual(kinds.filter { $0.hasSuffix("position.advanced") }.count, 1)
    }

    func testEnvironmentReadingsLogOnlyOnChange() {
        var m = DirectModeMachine(songCount: 2)
        m.observeAuthorization(.authorized, at: 0)
        m.observeAuthorization(.authorized, at: 1)
        m.observeCanPlayCatalog(true, at: 0)
        m.observeCanPlayCatalog(true, at: 1)
        m.observeRoute(.speaker, at: 0)
        m.observeRoute(.bluetoothA2DP, at: 2)
        XCTAssertEqual(m.log.map(\.description), [
            "+0.00s pos=0.0 stopped auth=authorized",
            "+0.00s pos=0.0 stopped canPlayCatalogContent=true",
            "+0.00s pos=0.0 stopped route=speaker",
            "+2.00s pos=0.0 stopped route=bluetoothA2DP",
        ])
    }

    func testLogIsBounded() {
        var m = loaded()
        for i in 0..<(DirectModeMachine.logCapacity + 50) {
            m.request(.pause, at: Double(i))   // refused, still logged
        }
        XCTAssertEqual(m.log.count, DirectModeMachine.logCapacity)
    }

    func testATransientNilItemNeverLatchesUnexpectedQueue() {
        var m = loaded()
        m.observe(status: .playing, position: 0.2,
                  entryIndex: DirectModeEntrySighting.song(loadedIndex: 0).entryIndex(keeping: m.entryIndex), at: 1)
        XCTAssertEqual(m.entryIndex, 0)
        for sighting in [DirectModeEntrySighting.itemPending, .noEntry, .itemPending] {
            m.observe(status: .playing, position: 0.4, entryIndex: sighting.entryIndex(keeping: m.entryIndex), at: 1.2)
        }
        XCTAssertEqual(m.entryIndex, 0)
        XCTAssertFalse(m.unexpectedQueueSeen)
        m.observe(status: .playing, position: 0.1,
                  entryIndex: DirectModeEntrySighting.song(loadedIndex: 1).entryIndex(keeping: m.entryIndex), at: 2)
        XCTAssertEqual(m.entryIndex, 1)
        XCTAssertFalse(m.unexpectedQueueSeen)
    }

    func testAForeignSongOrNonSongItemStillLatchesUnexpectedQueue() {
        for sighting in [DirectModeEntrySighting.song(loadedIndex: nil), .notSong] {
            var m = loaded()
            m.observe(status: .playing, position: 0.2, entryIndex: 0, at: 1)
            m.observe(status: .playing, position: 0.3, entryIndex: sighting.entryIndex(keeping: m.entryIndex), at: 1.2)
            XCTAssertTrue(m.unexpectedQueueSeen, "\(sighting)")
        }
    }
}
#endif
