#if DEBUG || AERODJ_P0_DIAG
import XCTest
@testable import AeroDJCore

/// P0 Direct Mode (-Fry): the "I hear it" mark and the song-set choice.
final class DirectModeHeardTests: XCTestCase {

    private func playing(at t: Double) -> DirectModeMachine {
        var m = DirectModeMachine(songCount: 2)
        m.request(.load, at: 0)
        m.finished(.load, error: nil, at: 0.1)
        XCTAssertTrue(m.request(.play, at: t))
        return m
    }

    func testHeardLatchesTheFirstTapAfterEachPlayOrResume() {
        var m = playing(at: 10)
        m.finished(.play, error: nil, at: 10.5)
        m.markHeard(at: 12)
        m.markHeard(at: 13)
        XCTAssertEqual(m.heardAfterPlay ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(m.log.filter { $0.kind == .heard }.count, 2, "every tap is logged")
        XCTAssertTrue(m.log.last?.description.hasSuffix("HEARD") ?? false)
        m.observe(status: .playing, position: 3, entryIndex: 0, at: 14)
        m.request(.pause, at: 15)
        m.finished(.pause, error: nil, at: 15)
        m.observe(status: .paused, position: 4, entryIndex: 0, at: 15.2)
        XCTAssertTrue(m.request(.resume, at: 100))
        XCTAssertNil(m.heardAfterPlay, "resume starts a new measurement")
        m.markHeard(at: 100.4)
        XCTAssertEqual(m.heardAfterPlay ?? -1, 0.4, accuracy: 0.001)
    }

    func testHeardBeforeAnyPlayIsLoggedButNotLatched() {
        var m = DirectModeMachine(songCount: 2)
        m.markHeard(at: 1)
        XCTAssertNil(m.heardAfterPlay)
        XCTAssertNil(m.playRequestedAt)
    }

    func testARefusedPlayDoesNotRestartTheMeasurement() {
        var m = playing(at: 10)
        XCTAssertFalse(m.request(.play, at: 11), "busy")
        XCTAssertEqual(m.playRequestedAt, 10)
    }

    func testSongSetCanOnlyChangeBeforeLoad() {
        var m = DirectModeMachine(songCount: 2)
        XCTAssertTrue(m.selectSongSet(.loudFirst, at: 0))
        XCTAssertEqual(m.songSet, .loudFirst)
        XCTAssertTrue(m.log.last?.description.hasSuffix("songSet=loudFirst") ?? false)
        m.request(.load, at: 1)
        XCTAssertFalse(m.selectSongSet(.standard, at: 1.1), "not while Load is in flight")
        m.finished(.load, error: nil, at: 2)
        XCTAssertFalse(m.selectSongSet(.standard, at: 3), "the queue is set exactly once")
        XCTAssertEqual(m.songSet, .loudFirst)
    }
}
#endif
