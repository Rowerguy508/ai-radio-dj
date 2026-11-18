import XCTest
@testable import AeroDJCore

/// #454 (-Nova): every station tap (list row, carousel card, Duo grid card, Duo dial stop or Tune)
/// takes one route. It selects the tapped station and starts that station's id, and Now Playing
/// shows that station starting, never the search screen. `StationSplitRoot.userTapped` and the
/// dials in `FoldedPlayer` / `TentPosePlayer` call exactly these functions.
// Fixtures at file scope, so the main-actor tests below capture no test-case instance.
private let morningCalm = BuiltInStations.morningCalm.id
private let lateNight = BuiltInStations.lateNight.id
private let created = UUID(uuidString: "0A1B2C3D-4E5F-4061-8273-9A0B1C2D3E4F")!
private let available: [UUID] = [morningCalm, lateNight, created]
private let song = TrackInfo(id: "song-1", title: "Morning Light", artistName: "Harbor")

// No class-level @MainActor: Linux XCTest discovery (Swift 6.2) aborts casting a @MainActor sync
// test. `StationTapRoute` is not isolated; only `StationStartStatus` needs the main actor, so those
// tests assume it (same as StationStartNoticeTests).
final class StationTapRouteTests: XCTestCase {

    /// The split's tap path, as `StationSplitRoot.userTapped` runs it: route, then start the id.
    private struct Split {
        var navigation = StationSplitNavigation<UUID>()
        var started: [UUID] = []

        mutating func tap(_ id: UUID?, available: [UUID]) {
            guard let picked = StationTapRoute.tap(id, navigation: &navigation, available: available) else { return }
            started.append(picked)
        }
    }

    /// What Now Playing shows for the split's opened station after `status` was set by a tap.
    private static func content(_ split: Split, state: StationStartState?, snapshot: PlaybackSnapshot) -> NowPlayingContent {
        let start = StationStartStatus.shown(state, openedStationID: split.navigation.selectedID?.uuidString,
                                             nowPlaying: snapshot.nowPlaying)
        return NowPlayingContent.resolve(access: .authorized, snapshot: snapshot, start: start)
    }

    // MARK: Row, card and grid taps

    func testARowTapStartsThatStationAndOpensIt() {
        for id in available {
            var split = Split()
            split.tap(id, available: available)
            XCTAssertEqual(split.started, [id], "a tap starts the tapped station's id")
            XCTAssertEqual(split.navigation.selectedID, id, "and opens that station")
            XCTAssertEqual(split.navigation.compactColumn, .detail, "the phone shows Now Playing, not the list")
        }
    }

    func testATapFromIdleShowsStartingNotSearch() {
        MainActor.assumeIsolated {
            var split = Split()
            let status = StationStartStatus()
            split.tap(lateNight, available: available)
            status.begin(stationID: lateNight.uuidString, stationName: "Late Night", songAtTap: nil)
            let shown = Self.content(split, state: status.state, snapshot: PlaybackSnapshot())
            XCTAssertEqual(shown, .starting(stationName: "Late Night"))
            // Search (the button that opens it) appears only on `.nothingPlaying`.
            XCTAssertNotEqual(shown, .nothingPlaying, "a station tap never lands on the search screen")
            XCTAssertTrue(shown.isStationStart)
        }
    }

    func testNoIdOrAnUnknownIdStartsNothingAndKeepsTheOpenStation() {
        var split = Split()
        split.tap(morningCalm, available: available)
        split.tap(nil, available: available)
        split.tap(UUID(), available: available)
        XCTAssertEqual(split.started, [morningCalm], "the split clearing its binding starts nothing")
        XCTAssertEqual(split.navigation.selectedID, morningCalm)
    }

    func testRestoreNeverStarts() {
        var split = Split()
        split.navigation.restore(lateNight, available: available)
        XCTAssertEqual(split.navigation.selectedID, lateNight)
        XCTAssertTrue(split.started.isEmpty, "a relaunch only reopens the station; it never starts one")
    }

    // MARK: Duo dial

    func testADialStopIdIsTheStationsID() {
        XCTAssertEqual(StationTapRoute.stationID(forStop: lateNight.uuidString, in: available), lateNight)
        XCTAssertEqual(StationTapRoute.stationID(forStop: created.uuidString, in: available), created)
        XCTAssertNil(StationTapRoute.stationID(forStop: "late-night", in: available), "not a station id")
        XCTAssertNil(StationTapRoute.stationID(forStop: UUID().uuidString, in: available), "a station no longer listed")
    }

    /// The dial used to start the station without opening it: the header stayed on the old station,
    /// its start state never showed, and a song tap queued from the old one. Now it opens it too.
    func testADialTapWhilePlayingOpensAndStartsTheTappedStation() {
        MainActor.assumeIsolated {
            var split = Split()
            let status = StationStartStatus()
            split.tap(morningCalm, available: available)
            let playing = PlaybackSnapshot(station: StationRef(id: morningCalm.uuidString, name: "Morning Calm"),
                                           nowPlaying: song, transport: .playing)
            var flight = DuoStationSwitch.Flight(highlightID: morningCalm.uuidString)
            let token = flight.receive(.tap(lateNight.uuidString), playingID: StationTapRoute.dialPlayingID(playing))
            XCTAssertNotNil(token)
            XCTAssertTrue(flight.accepts(token!))
            let stop = StationTapRoute.stationID(forStop: lateNight.uuidString, in: available)
            split.tap(stop, available: available)
            status.begin(stationID: lateNight.uuidString, stationName: "Late Night", songAtTap: song.id)

            XCTAssertEqual(split.started, [morningCalm, lateNight], "the dial starts the tapped station's id")
            XCTAssertEqual(split.navigation.selectedID, lateNight, "and opens it, like a row tap")
            XCTAssertEqual(Self.content(split, state: status.state, snapshot: playing), .starting(stationName: "Late Night"),
                           "Now Playing shows the tapped station starting over the old song")
            let heading = StationHeading(opened: StationRef(id: lateNight.uuidString, name: "Late Night"),
                                         playing: playing.station)
            XCTAssertEqual(heading.header.name, "Late Night")

            // The old route left the split on Morning Calm, so the start state never showed.
            let stale = StationStartStatus.shown(status.state, openedStationID: morningCalm.uuidString,
                                                 nowPlaying: playing.nowPlaying)
            XCTAssertNil(stale)
        }
    }

    func testTheDialSkipsOnlyTheStationThatIsPlaying() {
        let calm = StationRef(id: morningCalm.uuidString, name: "Morning Calm")
        XCTAssertEqual(StationTapRoute.dialPlayingID(PlaybackSnapshot(station: calm, nowPlaying: song, transport: .playing)),
                       morningCalm.uuidString)
        XCTAssertEqual(StationTapRoute.dialPlayingID(PlaybackSnapshot(station: calm, transport: .preparing)),
                       morningCalm.uuidString, "a start already on its way is not restarted")
        XCTAssertEqual(StationTapRoute.dialPlayingID(PlaybackSnapshot(station: calm, nowPlaying: song, transport: .paused)), "",
                       "a paused station's stop resumes it through the start path")
        XCTAssertEqual(StationTapRoute.dialPlayingID(PlaybackSnapshot(station: calm, transport: .stopped)), "")
        XCTAssertEqual(StationTapRoute.dialPlayingID(PlaybackSnapshot()), "")

        var playingFlight = DuoStationSwitch.Flight(highlightID: morningCalm.uuidString)
        XCTAssertNil(playingFlight.receive(.tap(morningCalm.uuidString),
                                           playingID: StationTapRoute.dialPlayingID(
                                               PlaybackSnapshot(station: calm, nowPlaying: song, transport: .playing))),
                     "tapping the playing station is a no-op")
    }

    /// After a restore the opened station is idle. Its own stop used to do nothing (the dial treated
    /// the opened station as playing); now it starts it.
    func testTheOpenedStationsStopStartsItFromIdle() {
        MainActor.assumeIsolated {
            var split = Split()
            split.navigation.restore(morningCalm, available: available)
            var flight = DuoStationSwitch.Flight(highlightID: morningCalm.uuidString)
            let token = flight.receive(.tap(morningCalm.uuidString), playingID: StationTapRoute.dialPlayingID(PlaybackSnapshot()))
            XCTAssertNotNil(token, "an idle opened station's stop starts it")
            split.tap(StationTapRoute.stationID(forStop: morningCalm.uuidString, in: available), available: available)
            XCTAssertEqual(split.started, [morningCalm])

            let status = StationStartStatus()
            status.begin(stationID: morningCalm.uuidString, stationName: "Morning Calm", songAtTap: nil)
            XCTAssertEqual(Self.content(split, state: status.state, snapshot: PlaybackSnapshot()), .starting(stationName: "Morning Calm"))
        }
    }
}
