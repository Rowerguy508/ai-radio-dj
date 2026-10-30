import XCTest
@testable import AeroDJCore

final class StationArtTests: XCTestCase {
    let station = StationRef(id: "morning-calm", name: "Morning Calm")

    #if DEBUG // PlaybackFixtures is Debug-only; `swift test -c release` builds this file too.
    func testDeterministicAcrossCalls() {
        let t = PlaybackFixtures.songs[0]
        XCTAssertEqual(StationArtStyle.track(t, on: station), StationArtStyle.track(t, on: station))
        XCTAssertEqual(StationArtStyle.station(station), StationArtStyle.station(station))
        // Pinned value: FNV-1a is stable, so the palette must not drift between releases.
        XCTAssertEqual(StationArtStyle.fnv1a("a"), 0xaf63_dc4c_8601_ec8c)
    }
    #endif

    #if DEBUG // PlaybackFixtures is Debug-only; `swift test -c release` builds this file too.
    func testTracksDifferButStayInStationFamily() {
        let base = StationArtStyle.station(station)
        let styles = PlaybackFixtures.songs.map { StationArtStyle.track($0, on: station) }
        XCTAssertEqual(Set(styles.map(\.monogram)).count, styles.count)
        for s in styles {
            let d = abs(s.hues[0] - base.hues[0])
            XCTAssertLessThanOrEqual(min(d, 1 - d), 0.081, "track hue stays near the station hue")
            XCTAssertTrue(s.hues.allSatisfy { (0..<1).contains($0) })
            XCTAssertTrue((2...4).contains(s.rings))
            XCTAssertEqual(s.angle % 45, 0)
        }
    }
    #endif

    func testDifferentStationsGetDifferentRooms() {
        let other = StationArtStyle.station(StationRef(id: "late-night", name: "Late Night"))
        XCTAssertNotEqual(other.hues[0], StationArtStyle.station(station).hues[0])
    }

    func testMonogram() {
        XCTAssertEqual(StationArtStyle.monogram("Bakery Lights on Fennimore"), "BL")
        XCTAssertEqual(StationArtStyle.monogram("golden"), "G")
        XCTAssertEqual(StationArtStyle.monogram("(I Can't Get No) Satisfaction"), "IC")
        XCTAssertEqual(StationArtStyle.monogram("   "), "♪")
        XCTAssertEqual(StationArtStyle.monogram("99 Problems"), "9P")
    }

    func testLegibleRanges() {
        for id in ["a", "b", "morning-calm", "late-night", "x-y-z", "🎧"] {
            let s = StationArtStyle.make(seed: id, label: id)
            XCTAssertTrue((0.55...0.75).contains(s.saturation))
            XCTAssertTrue((0.70...0.85).contains(s.brightness))
        }
    }
}
