// PlaybackFixtures is Debug-only (#if DEBUG); `swift test -c release` builds this file too.
#if DEBUG
import XCTest
@testable import AeroDJCore

final class PlaybackFixturesTests: XCTestCase {
    private var all: [PlaybackSnapshot] {
        [PlaybackFixtures.playing, PlaybackFixtures.djSpeaking, PlaybackFixtures.paused,
         PlaybackFixtures.recoverableError, PlaybackFixtures.stopped]
    }

    func testEveryFixtureIsInternallyConsistent() {
        for snapshot in all {
            // Up next never repeats the song playing.
            if let now = snapshot.nowPlaying {
                XCTAssertFalse(snapshot.upNext.contains(now))
            } else {
                XCTAssertEqual(snapshot.upNext, [], "nothing playing means nothing queued")
            }
            // A stopped show has no track, and playing shows have one.
            if snapshot.transport == .stopped {
                XCTAssertNil(snapshot.nowPlaying)
            }
        }
    }

    func testEveryFixtureBelongsToOneStation() {
        for snapshot in all {
            XCTAssertEqual(snapshot.station, PlaybackFixtures.station)
        }
    }

    func testDJSpeakingFixtureKeepsShowPlaying() {
        XCTAssertEqual(PlaybackFixtures.djSpeaking.transport, .playing)
        if case .speaking = PlaybackFixtures.djSpeaking.dj {} else { XCTFail("expected speaking") }
    }
}
#endif
