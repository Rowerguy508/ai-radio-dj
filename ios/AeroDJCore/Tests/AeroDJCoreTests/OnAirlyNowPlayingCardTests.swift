import XCTest
@testable import AeroDJCore

/// #539 follow-up: the OnAirly Now Playing session (iOS 27 NowPlaying framework). What it says,
/// which commands it offers, and the one-API-per-launch rule. Not device evidence.
final class OnAirlyNowPlayingCardTests: XCTestCase {
    private let station = StationRef(id: "st-1", name: "Morning Calm")
    private let song = TrackInfo(id: "song-1", title: "Tidewater", artistName: "Lumen Harbor",
                                 artworkURL: URL(string: "https://example.invalid/art.jpg"))
    private let next = TrackInfo(id: "song-2", title: "Paper Satellites", artistName: "Velvet Orchard")
    private let script = "That was Lumen Harbor. Fog's lifting off the water."

    private let allDJStates: [DJStudioState] = [
        .idle, .preparing(includesBriefing: true), .ready(includesBriefing: true, seconds: 30),
        .speaking(includesBriefing: true), .speaking(includesBriefing: false),
        .failed(.voiceFailed), .failed(.budgetReached), .failed(.consentReviewRequired(pendingCount: 2)),
    ]

    private func snapshot(_ transport: TransportState = .playing, track: Bool = true, station: Bool = true,
                          upNext: Bool = true, canSeek: Bool = true) -> PlaybackSnapshot {
        PlaybackSnapshot(station: station ? self.station : nil, nowPlaying: track ? song : nil,
                         upNext: upNext ? [next] : [], transport: transport,
                         dj: .speaking(line: script),
                         error: PlaybackError(kind: .speechFailed, message: "voice failed", isRecoverable: true),
                         canSeek: canSeek)
    }

    // MARK: Content

    func testPlayingSongReadsAsSongArtistAndStation() throws {
        let card = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(), dj: .idle, duration: 200))
        XCTAssertEqual(card.title, "Tidewater")
        XCTAssertEqual(card.subtitle, "Lumen Harbor · Morning Calm")
        XCTAssertEqual(card.artworkURL, song.artworkURL)
        XCTAssertEqual(card.transport, .playing)
        XCTAssertEqual(card.duration, 200)
        XCTAssertEqual(card.contentID, "track:song-1")
        XCTAssertFalse(card.djOnAir)
    }

    func testDJStatusReplacesStationInSubtitle() throws {
        let onAir = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(), dj: .speaking(includesBriefing: false)))
        XCTAssertEqual(onAir.subtitle, "Lumen Harbor · DJ on air")
        XCTAssertTrue(onAir.djOnAir)
        let ready = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(),
                                                             dj: .ready(includesBriefing: false, seconds: 20)))
        XCTAssertEqual(ready.subtitle, "Lumen Harbor · DJ break after this song")
        XCTAssertFalse(ready.djOnAir)
    }

    func testQuietDJStatesShowStationNotAStatus() throws {
        let quiet: [DJStudioState] = [.idle, .preparing(includesBriefing: true), .failed(.voiceFailed),
                                      .failed(.budgetReached), .failed(.consentReviewRequired(pendingCount: 1))]
        for dj in quiet {
            let card = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(), dj: dj))
            XCTAssertEqual(card.subtitle, "Lumen Harbor · Morning Calm", "\(dj)")
        }
    }

    func testUnknownStationFallsBackToAppName() throws {
        let card = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(station: false), dj: .idle))
        XCTAssertEqual(card.subtitle, "Lumen Harbor · \(AppName.display)")
        let blank = PlaybackSnapshot(station: StationRef(id: "x", name: "  "), nowPlaying: song, transport: .playing)
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: blank, dj: .idle)?.subtitle, "Lumen Harbor · OnAirly")
    }

    func testStationOnlyBeforeFirstSong() throws {
        let card = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(.preparing, track: false), dj: .idle,
                                                            duration: 200))
        XCTAssertEqual(card.title, "Morning Calm")
        XCTAssertEqual(card.subtitle, "Morning Calm")
        XCTAssertEqual(card.transport, .buffering)
        XCTAssertNil(card.artworkURL)
        XCTAssertNil(card.duration, "no song, no duration")
        XCTAssertFalse(card.canSeek)
        XCTAssertFalse(card.nextEnabled)
        XCTAssertEqual(card.contentID, "station:st-1")
    }

    func testNoSessionWhenStoppedOrEmpty() {
        XCTAssertNil(OnAirlyNowPlayingCard.make(snapshot: snapshot(.stopped), dj: .speaking(includesBriefing: true)))
        XCTAssertNil(OnAirlyNowPlayingCard.make(snapshot: snapshot(.playing, track: false, station: false), dj: .idle))
        XCTAssertNil(OnAirlyNowPlayingCard.make(snapshot: PlaybackSnapshot(), dj: .idle))
    }

    func testTransportMapping() {
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: snapshot(.playing), dj: .idle)?.transport, .playing)
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: snapshot(.paused), dj: .idle)?.transport, .paused)
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: snapshot(.preparing), dj: .idle)?.transport, .buffering)
    }

    func testInvalidDurationsAreDropped() {
        for bad in [0, -1, .infinity, .nan] as [TimeInterval] {
            XCTAssertNil(OnAirlyNowPlayingCard.make(snapshot: snapshot(), dj: .idle, duration: bad)?.duration, "\(bad)")
        }
    }

    // MARK: Privacy

    func testNoScriptErrorOrDetailTextEverReachesTheCard() throws {
        for dj in allDJStates {
            for transport in [TransportState.preparing, .playing, .paused] {
                let card = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(transport), dj: dj))
                for text in [card.title, card.subtitle] {
                    XCTAssertFalse(text.contains("Fog"), "script leaked: \(dj)")
                    XCTAssertFalse(text.contains("voice failed"), "error leaked: \(dj)")
                    XCTAssertFalse(text.contains(dj.detail) && !dj.detail.isEmpty, "detail leaked: \(dj)")
                    XCTAssertFalse(text.contains("Paper Satellites"), "up next leaked: \(dj)")
                }
            }
        }
    }

    // MARK: Commands

    func testNextOnlyWithAQueuedSong() {
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: snapshot(upNext: true), dj: .idle)?.nextEnabled, true)
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: snapshot(upNext: false), dj: .idle)?.nextEnabled, false)
    }

    func testSeekFollowsCanSeekAndNeverWhileDJOnAir() {
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: snapshot(canSeek: true), dj: .idle)?.canSeek, true)
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: snapshot(canSeek: false), dj: .idle)?.canSeek, false)
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: snapshot(canSeek: true),
                                                  dj: .speaking(includesBriefing: false))?.canSeek, false)
    }

    func testElapsedOnlyWhileTheSongIsAudible() throws {
        let playing = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(), dj: .idle, duration: 200))
        XCTAssertEqual(playing.publishedElapsed(42), 42)
        XCTAssertEqual(playing.publishedElapsed(500), 200, "clamped to the duration")
        XCTAssertNil(playing.publishedElapsed(-1))
        XCTAssertNil(playing.publishedElapsed(.nan))
        let onAir = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(), dj: .speaking(includesBriefing: false),
                                                             duration: 200))
        XCTAssertNil(onAir.publishedElapsed(42))
        let noDuration = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(), dj: .idle))
        XCTAssertNil(noDuration.publishedElapsed(42))
        let buffering = try XCTUnwrap(OnAirlyNowPlayingCard.make(snapshot: snapshot(.preparing), dj: .idle, duration: 200))
        XCTAssertNil(buffering.publishedElapsed(42))
    }

    // MARK: Policy

    func testSessionOnlyOnIOS27AndLaterAndOnlyWhenEnabled() {
        XCTAssertFalse(OnAirlyNowPlayingPolicy.usesSession(osMajor: 26, enabled: true))
        XCTAssertTrue(OnAirlyNowPlayingPolicy.usesSession(osMajor: 27, enabled: true))
        XCTAssertTrue(OnAirlyNowPlayingPolicy.usesSession(osMajor: 28, enabled: true))
        XCTAssertFalse(OnAirlyNowPlayingPolicy.usesSession(osMajor: 27, enabled: false))
    }

    func testExactlyOneNowPlayingAPIPerLaunch() {
        for uses in [true, false] {
            XCTAssertEqual(OnAirlyNowPlayingPolicy.installsMediaPlayerRemoteCommands(usesSession: uses), !uses)
            XCTAssertEqual(OnAirlyNowPlayingPolicy.carPlayBridgeWrites(usesSession: uses), !uses)
        }
    }

    func testSystemPrimaryRequestedOnlyFromForegroundWhilePlaying() throws {
        let playing = OnAirlyNowPlayingCard.make(snapshot: snapshot(.playing), dj: .idle)
        let paused = OnAirlyNowPlayingCard.make(snapshot: snapshot(.paused), dj: .idle)
        let buffering = OnAirlyNowPlayingCard.make(snapshot: snapshot(.preparing), dj: .idle)
        XCTAssertTrue(OnAirlyNowPlayingPolicy.shouldRequestSystemPrimary(card: playing, appInForeground: true,
                                                                         isSystemPrimary: false))
        XCTAssertFalse(OnAirlyNowPlayingPolicy.shouldRequestSystemPrimary(card: playing, appInForeground: false,
                                                                          isSystemPrimary: false))
        XCTAssertFalse(OnAirlyNowPlayingPolicy.shouldRequestSystemPrimary(card: playing, appInForeground: true,
                                                                          isSystemPrimary: true))
        XCTAssertFalse(OnAirlyNowPlayingPolicy.shouldRequestSystemPrimary(card: paused, appInForeground: true,
                                                                          isSystemPrimary: false))
        XCTAssertFalse(OnAirlyNowPlayingPolicy.shouldRequestSystemPrimary(card: buffering, appInForeground: true,
                                                                          isSystemPrimary: false))
        XCTAssertFalse(OnAirlyNowPlayingPolicy.shouldRequestSystemPrimary(card: nil, appInForeground: true,
                                                                          isSystemPrimary: false))
    }
}
