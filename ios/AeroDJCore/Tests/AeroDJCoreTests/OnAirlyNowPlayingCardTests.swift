import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

    /// Atlas: Next follows `RemoteNextCommand`, the MediaPlayer path's rule, from the service's own
    /// queue position, so lock-screen Next matches on both paths (during a load and a DJ break too).
    func testNextUsesTheRemoteNextCommandRule() {
        let transports: [TransportState] = [.preparing, .playing, .paused]
        let djs: [DJStudioState] = [.idle, .ready(includesBriefing: false, seconds: 20), .speaking(includesBriefing: true)]
        for transport in transports {
            for dj in djs {
                for (index, count) in [(0, 0), (0, 1), (0, 2), (1, 2), (2, 2), (-1, 3), (3, 5), (4, 5)] {
                    let card = OnAirlyNowPlayingCard.make(snapshot: snapshot(transport), dj: dj,
                                                          queueIndex: index, queueCount: count)
                    XCTAssertEqual(card?.nextEnabled, RemoteNextCommand.isEnabled(queueIndex: index, queueCount: count),
                                   "\(transport) \(dj) \(index)/\(count)")
                    XCTAssertEqual(card?.nextEnabled,
                                   RemoteNextCommand.decide(queueIndex: index, queueCount: count) == .skip)
                }
            }
        }
        // The snapshot's up-next list does not decide it: the service's queue position does.
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: snapshot(upNext: false), dj: .idle,
                                                  queueIndex: 0, queueCount: 2)?.nextEnabled, true)
        XCTAssertEqual(OnAirlyNowPlayingCard.make(snapshot: snapshot(upNext: true), dj: .idle,
                                                  queueIndex: 1, queueCount: 2)?.nextEnabled, false)
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

    // MARK: Remote kill switch (`onAirlyNowPlayingSession` in GET /api/flags)

    private final class FlagTransport: HTTPTransport, @unchecked Sendable {
        let status: Int, body: String, error: Bool
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { seen } }
        init(status: Int = 200, body: String = "", error: Bool = false) { self.status = status; self.body = body; self.error = error }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { seen.append(request) }
            if error { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private let flagBase = URL(string: "https://proxy.invalid")!

    /// An in-memory stand-in for the app's `UserDefaults` cache.
    private final class MemoryFlagCache: OnAirlySessionFlagCache, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        init(_ value: Bool? = nil) { stored = value }
        func cachedValue() -> Bool? { lock.withLock { stored } }
        func setCachedValue(_ value: Bool?) { lock.withLock { stored = value } }
    }

    func testFlagKeyAndDefault() {
        XCTAssertEqual(OnAirlySessionFlag.jsonKey, "onAirlyNowPlayingSession")
        XCTAssertTrue(OnAirlySessionFlag.defaultValue)
    }

    func testFlagDecoding() {
        func parse(_ s: String) -> OnAirlySessionFlag.Answer { OnAirlySessionFlag.parse(Data(s.utf8)) }
        XCTAssertEqual(parse(#"{"onAirlyNowPlayingSession":false}"#), .value(false))
        XCTAssertEqual(parse(#"{"onAirlyNowPlayingSession":true}"#), .value(true))
        XCTAssertEqual(parse(#"{"djAirPlayLongForm":true,"onAirlyNowPlayingSession":false}"#), .value(false))
        XCTAssertEqual(parse(#"{"djAirPlayLongForm":false}"#), .missing)
        XCTAssertEqual(parse(#"{}"#), .missing)
        XCTAssertEqual(parse(#"{"onAirlyNowPlayingSession":"false"}"#), .unreadable)
        XCTAssertEqual(parse(#"{"onAirlyNowPlayingSession":null}"#), .unreadable)
        XCTAssertEqual(parse("nope"), .unreadable)
        XCTAssertEqual(parse("[false]"), .unreadable)
        XCTAssertEqual(parse(""), .unreadable)
        XCTAssertEqual(parse(#"{"onAirlyNowPlayingSession":false,"pad":""# + String(repeating: "x", count: 1100) + #""}"#),
                       .unreadable)
    }

    /// Atlas: the launch uses the CACHED value; no cache means on; cached false means off.
    func testLaunchValueComesFromTheCache() {
        XCTAssertTrue(OnAirlySessionFlag.launchValue(cache: MemoryFlagCache()), "no cache: on")
        XCTAssertTrue(OnAirlySessionFlag.launchValue(cache: MemoryFlagCache(true)))
        XCTAssertFalse(OnAirlySessionFlag.launchValue(cache: MemoryFlagCache(false)), "cached false: off this launch")
        XCTAssertFalse(OnAirlyNowPlayingPolicy.usesSession(
            osMajor: 27, enabled: OnAirlySessionFlag.launchValue(cache: MemoryFlagCache(false))))
        XCTAssertTrue(OnAirlyNowPlayingPolicy.usesSession(
            osMajor: 27, enabled: OnAirlySessionFlag.launchValue(cache: MemoryFlagCache())))
    }

    /// Atlas: a fetch changes only the cache (the next launch), never the value this launch read.
    func testAFetchOnlyUpdatesTheCacheForTheNextLaunch() async throws {
        let cache = MemoryFlagCache()
        let thisLaunch = OnAirlySessionFlag.launchValue(cache: cache)
        XCTAssertTrue(thisLaunch)
        let kill = FlagTransport(body: #"{"djAirPlayLongForm":true,"onAirlyNowPlayingSession":false}"#)
        let next = await OnAirlySessionFlag.refresh(transport: kill, baseURL: flagBase, cache: cache)
        XCTAssertFalse(next, "the next launch starts off")
        XCTAssertEqual(cache.cachedValue(), false)
        XCTAssertTrue(thisLaunch, "this launch's value was read once and is not re-read")
        XCTAssertFalse(OnAirlySessionFlag.launchValue(cache: cache), "next launch: off")
        // An explicit true turns it back on for the launch after.
        let back = await OnAirlySessionFlag.refresh(transport: FlagTransport(body: #"{"onAirlyNowPlayingSession":true}"#),
                                                    baseURL: flagBase, cache: cache)
        XCTAssertTrue(back)
        XCTAssertEqual(cache.cachedValue(), true)
        // The same bare GET as the #525 flag: no body, token or cookies.
        let request = try XCTUnwrap(kill.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://proxy.invalid/api/flags")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.allHTTPHeaderFields ?? [:], [:])
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testFailuresLeaveTheCacheAndMissingKeyMeansOn() async {
        // Failure, non-200, unreadable, offline: the cache stays exactly as it was.
        for start in [nil, true, false] as [Bool?] {
            for t in [FlagTransport(status: 503, body: #"{"onAirlyNowPlayingSession":false}"#),
                      FlagTransport(status: 200, body: "<html>"),
                      FlagTransport(status: 200, body: #"{"onAirlyNowPlayingSession":"no"}"#),
                      FlagTransport(error: true)] {
                let cache = MemoryFlagCache(start)
                let next = await OnAirlySessionFlag.refresh(transport: t, baseURL: flagBase, cache: cache)
                XCTAssertEqual(cache.cachedValue(), start, "failure keeps the cache")
                XCTAssertEqual(next, start ?? true, "never fetched: on")
            }
        }
        // A 200 object without the key clears a cached false: the next launch is on.
        let cache = MemoryFlagCache(false)
        let next = await OnAirlySessionFlag.refresh(transport: FlagTransport(body: #"{"djAirPlayLongForm":true}"#),
                                                    baseURL: flagBase, cache: cache)
        XCTAssertTrue(next)
        XCTAssertNil(cache.cachedValue())
        XCTAssertTrue(OnAirlySessionFlag.launchValue(cache: cache))
    }

    func testUserDefaultsCacheStoresOneBool() throws {
        let suite = "OnAirlySessionFlagTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserDefaultsOnAirlySessionFlagCache(defaults: defaults)
        XCTAssertNil(cache.cachedValue())
        XCTAssertTrue(OnAirlySessionFlag.launchValue(cache: cache), "no cache: on")
        cache.setCachedValue(false)
        XCTAssertEqual(defaults.object(forKey: UserDefaultsOnAirlySessionFlagCache.key) as? Bool, false)
        XCTAssertFalse(OnAirlySessionFlag.launchValue(cache: UserDefaultsOnAirlySessionFlagCache(defaults: defaults)),
                       "a new launch reads the cached false")
        cache.setCachedValue(nil)
        XCTAssertNil(defaults.object(forKey: UserDefaultsOnAirlySessionFlagCache.key))
        XCTAssertEqual(UserDefaultsOnAirlySessionFlagCache.key, "onAirlyNowPlayingSessionFlag")
    }

    func testPolicyReadsTheLaunchValue() {
        XCTAssertEqual(OnAirlyNowPlayingPolicy.sessionEnabled, OnAirlySessionFlag.launchValue)
    }
}

/// The pre-existing content tests: the service queue mirrors the snapshot (current song plus up next).
private extension OnAirlyNowPlayingCard {
    static func make(snapshot: PlaybackSnapshot, dj: DJStudioState, duration: TimeInterval? = nil) -> OnAirlyNowPlayingCard? {
        make(snapshot: snapshot, dj: dj, duration: duration, queueIndex: 0,
             queueCount: snapshot.nowPlaying == nil ? 0 : 1 + snapshot.upNext.count)
    }
}
