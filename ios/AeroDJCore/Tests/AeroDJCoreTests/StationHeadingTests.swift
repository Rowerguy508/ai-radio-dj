import XCTest
@testable import AeroDJCore

/// Build 9 video: Morning Calm was playing, the owner opened Late Night from the list, and the
/// header still read "Morning Calm". The next song tap started the queue from Late Night, so
/// the header seemed to jump. The header must name the opened station the whole time.
final class StationHeadingTests: XCTestCase {
    private let morningCalm = StationRef(id: "7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D", name: "Morning Calm")
    private let lateNight = StationRef(id: "8D3B2C21-5F60-4B7C-9D0E-1F2A3B4C5D6E", name: "Late Night")

    func testOpeningAnotherStationWhileOneIsPlayingNamesTheOpenedStation() {
        let heading = StationHeading(opened: lateNight, playing: morningCalm)
        XCTAssertEqual(heading.header, lateNight, "header must not keep the playing station's name")
        XCTAssertEqual(heading.nowPlaying, morningCalm, "the playing track still belongs to Morning Calm")
        XCTAssertTrue(heading.isPlayingAnotherStation)
    }

    func testSongTapOnTheOpenedStationLeavesTheHeaderUnchanged() {
        // Before the tap: Late Night opened, Morning Calm playing.
        let before = StationHeading(opened: lateNight, playing: morningCalm)
        // The tap starts the queue from the opened station.
        let after = StationHeading(opened: lateNight, playing: lateNight)
        XCTAssertEqual(before.header, after.header, "a song tap must not change the header")
        XCTAssertFalse(after.isPlayingAnotherStation)
    }

    func testNothingPlayingUsesTheOpenedStation() {
        let heading = StationHeading(opened: morningCalm, playing: nil)
        XCTAssertEqual(heading.header, morningCalm)
        XCTAssertEqual(heading.nowPlaying, morningCalm)
        XCTAssertFalse(heading.isPlayingAnotherStation)
    }

    func testSameStationPlaying() {
        let heading = StationHeading(opened: morningCalm, playing: morningCalm)
        XCTAssertEqual(heading.header, morningCalm)
        XCTAssertFalse(heading.isPlayingAnotherStation)
    }
}
