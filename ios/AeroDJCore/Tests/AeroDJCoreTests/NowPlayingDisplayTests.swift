import XCTest
@testable import AeroDJCore

/// #465 item 7: Echo's and Sentinel's privacy rules for StandBy, the widget and the Live
/// Activity. Everything those surfaces receive is a `NowPlayingDisplay`.
final class NowPlayingDisplayTests: XCTestCase {
    private let station = StationRef(id: "st-1", name: "Morning Calm")
    private let song = TrackInfo(id: "song-1", title: "Tidewater", artistName: "Lumen Harbor",
                                 artworkURL: URL(string: "https://example.invalid/art.jpg"))
    private let script = "That was Lumen Harbor. Fog's lifting off the water."

    private func snapshot(_ transport: TransportState = .playing, speaking: Bool = true) -> PlaybackSnapshot {
        PlaybackSnapshot(station: station, nowPlaying: song,
                         upNext: [TrackInfo(id: "n", title: "Paper Satellites", artistName: "Velvet Orchard")],
                         transport: transport, dj: speaking ? .speaking(line: script) : .idle,
                         error: PlaybackError(kind: .speechFailed, message: "voice failed", isRecoverable: true))
    }

    private let allDJStates: [DJStudioState] = [
        .idle, .preparing(includesBriefing: true), .ready(includesBriefing: true, seconds: 30),
        .speaking(includesBriefing: true), .speaking(includesBriefing: false),
        .failed(.voiceFailed), .failed(.budgetReached), .failed(.consentReviewRequired(pendingCount: 2)),
    ]

    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Display fields only

    func testEncodedKeysAreExactlyTheDisplayFields() throws {
        let speaking = NowPlayingDisplay.make(snapshot: snapshot(), dj: .speaking(includesBriefing: true))
        let ready = NowPlayingDisplay.make(snapshot: snapshot(), dj: .ready(includesBriefing: false, seconds: 30))
        let speakingKeys = Set(try jsonObject(speaking).keys)
        let readyKeys = Set(try jsonObject(ready).keys)
        // Nil optional labels are omitted, so one payload never has both keys.
        XCTAssertEqual(speakingKeys.union(readyKeys), NowPlayingDisplay.allowedKeys)
        XCTAssertEqual(speakingKeys, NowPlayingDisplay.allowedKeys.subtracting(["readyLabel"]))
        XCTAssertEqual(readyKeys, NowPlayingDisplay.allowedKeys.subtracting(["onAirLabel"]))
        XCTAssertEqual(NowPlayingDisplay.allowedKeys, ["station", "track", "artist", "art", "state", "onAirLabel", "readyLabel"])
        let art = try XCTUnwrap(try jsonObject(speaking)["art"] as? [String: Any])
        XCTAssertEqual(Set(art.keys), NowPlayingDisplay.allowedArtKeys)
    }

    /// Mirror check: adding a stored property without updating the allow-list fails here.
    func testStoredPropertiesMatchTheAllowList() {
        let display = NowPlayingDisplay.make(snapshot: snapshot(), dj: .idle)
        let names = Set(Mirror(reflecting: display).children.compactMap(\.label))
        XCTAssertEqual(names, NowPlayingDisplay.allowedKeys)
        let artNames = Set(Mirror(reflecting: display.art!).children.compactMap(\.label))
        XCTAssertEqual(artNames, NowPlayingDisplay.allowedArtKeys)
    }

    func testNoForbiddenNamesInTheKeySet() {
        let forbidden = ["token", "jws", "transaction", "appaccount", "user", "consent", "tester", "voice",
                         "script", "briefing", "line", "url", "id"]
        for key in NowPlayingDisplay.allowedKeys.union(NowPlayingDisplay.allowedArtKeys) {
            for word in forbidden {
                XCTAssertFalse(key.lowercased().contains(word), "\(key) contains \(word)")
            }
        }
    }

    func testNoScriptQueueErrorOrURLEverReachesThePayload() throws {
        for dj in allDJStates {
            for transport in [TransportState.playing, .paused, .preparing, .stopped] {
                let display = NowPlayingDisplay.make(snapshot: snapshot(transport), dj: dj)
                for data in [try JSONEncoder().encode(display), NowPlayingDisplayStore.encode(display)!] {
                    let text = String(decoding: data, as: UTF8.self)
                    XCTAssertFalse(text.contains("Fog"), "script text leaked")
                    XCTAssertFalse(text.contains("Paper Satellites"), "queue leaked")
                    XCTAssertFalse(text.contains("voice failed"), "error leaked")
                    XCTAssertFalse(text.contains("example.invalid"), "artwork URL leaked")
                    XCTAssertFalse(text.contains("st-1"), "station ID leaked")
                    XCTAssertFalse(text.contains("song-1"), "song ID leaked")
                    XCTAssertFalse(text.localizedCaseInsensitiveContains("briefing"), "briefing leaked")
                    XCTAssertFalse(text.localizedCaseInsensitiveContains("review"), "consent state leaked")
                }
            }
        }
    }

    func testMapsDisplayFields() {
        let display = NowPlayingDisplay.make(snapshot: snapshot(.paused, speaking: false), dj: .idle)
        XCTAssertEqual(display.station, "Morning Calm")
        XCTAssertEqual(display.track, "Tidewater")
        XCTAssertEqual(display.artist, "Lumen Harbor")
        XCTAssertEqual(display.state, .paused)
        XCTAssertEqual(display.art, .init(StationArtStyle.track(song, on: station)))
        XCTAssertEqual(NowPlayingDisplay.make(snapshot: PlaybackSnapshot(transport: .preparing), dj: .idle).state, .starting)
        let empty = NowPlayingDisplay.make(snapshot: PlaybackSnapshot(), dj: .idle)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.art)
    }

    // MARK: On Air only from confirmed .speaking

    func testOnAirComesOnlyFromDJStudioStateOnAirLabel() {
        for dj in allDJStates {
            for transport in [TransportState.playing, .paused, .preparing] {
                // The snapshot's own dj activity must not matter: only the studio state does.
                for speaking in [true, false] {
                    let display = NowPlayingDisplay.make(snapshot: snapshot(transport, speaking: speaking), dj: dj)
                    XCTAssertEqual(display.onAirLabel, dj.onAirLabel, "\(dj) \(transport)")
                    XCTAssertEqual(display.isOnAir, dj.isOnAir)
                }
            }
        }
    }

    func testStoppedIsNeverOnAir() {
        let display = NowPlayingDisplay.make(snapshot: snapshot(.stopped), dj: .speaking(includesBriefing: false))
        XCTAssertNil(display.onAirLabel)
    }

    func testWidgetCopyNeverCarriesTheTally() throws {
        let display = NowPlayingDisplay.make(snapshot: snapshot(), dj: .speaking(includesBriefing: false))
        XCTAssertTrue(display.isOnAir)
        XCTAssertNil(display.widgetCopy.onAirLabel)
        let stored = try XCTUnwrap(NowPlayingDisplayStore.decode(NowPlayingDisplayStore.encode(display)))
        XCTAssertNil(stored.onAirLabel)
        XCTAssertEqual(stored.track, "Tidewater")
    }

    // MARK: Ready line, Live Activity only

    func testReadyGivesTheLineAndIsNeverOnAir() {
        let display = NowPlayingDisplay.make(snapshot: snapshot(), dj: .ready(includesBriefing: true, seconds: 30))
        XCTAssertEqual(display.readyLabel, "DJ break after this song")
        XCTAssertEqual(display.readyLabel, NowPlayingDisplay.readyLineCopy)
        XCTAssertNil(display.onAirLabel)
        XCTAssertFalse(display.isOnAir)
        // Briefing must not change the copy or leak into the payload.
        let noBriefing = NowPlayingDisplay.make(snapshot: snapshot(), dj: .ready(includesBriefing: false, seconds: 12))
        XCTAssertEqual(noBriefing.readyLabel, NowPlayingDisplay.readyLineCopy)
    }

    func testSpeakingGivesOnAirWithoutTheReadyLine() {
        let display = NowPlayingDisplay.make(snapshot: snapshot(), dj: .speaking(includesBriefing: true))
        XCTAssertEqual(display.onAirLabel, "On Air")
        XCTAssertTrue(display.isOnAir)
        XCTAssertNil(display.readyLabel)
    }

    func testFailedAndIdleGiveNoReadyLine() {
        for dj in [DJStudioState.idle, .preparing(includesBriefing: true),
                   .failed(.voiceFailed), .failed(.budgetReached),
                   .failed(.consentReviewRequired(pendingCount: 2))] {
            let display = NowPlayingDisplay.make(snapshot: snapshot(), dj: dj)
            XCTAssertNil(display.readyLabel, "\(dj)")
            XCTAssertNil(display.onAirLabel, "\(dj)")
        }
        let stopped = NowPlayingDisplay.make(snapshot: snapshot(.stopped),
                                             dj: .ready(includesBriefing: false, seconds: 20))
        XCTAssertNil(stopped.readyLabel)
        XCTAssertNil(stopped.onAirLabel)
    }

    func testWidgetCopyNeverCarriesTheReadyLine() throws {
        let display = NowPlayingDisplay.make(snapshot: snapshot(), dj: .ready(includesBriefing: false, seconds: 30))
        XCTAssertEqual(display.readyLabel, NowPlayingDisplay.readyLineCopy)
        XCTAssertNil(display.widgetCopy.readyLabel)
        XCTAssertNil(display.widgetCopy.onAirLabel)
        let stored = try XCTUnwrap(NowPlayingDisplayStore.decode(NowPlayingDisplayStore.encode(display)))
        XCTAssertNil(stored.readyLabel)
        XCTAssertEqual(stored.track, "Tidewater")
        let playing = NowPlayingDisplay.make(snapshot: snapshot(), dj: .idle)
        XCTAssertFalse(NowPlayingDisplayStore.needsWidgetReload(from: playing, to: display),
                       "Ready alone must not reload the widget")
    }

    /// An #485 payload, written before `readyLabel` existed, decodes as not-ready.
    func testOldPayloadDecodesAsNotReady() throws {
        let old = Data("""
            {"artist":"Lumen Harbor","onAirLabel":null,"state":"playing","station":"Morning Calm","track":"Tidewater"}
            """.utf8)
        let decoded = try JSONDecoder().decode(NowPlayingDisplay.self, from: old)
        XCTAssertNil(decoded.readyLabel)
        XCTAssertNil(decoded.onAirLabel)
        XCTAssertEqual(decoded.track, "Tidewater")
        XCTAssertEqual(decoded.state, .playing)
    }

    // MARK: Redaction

    func testStationTrackArtistAndArtArePrivacySensitive() {
        XCTAssertEqual(NowPlayingDisplay.privacySensitiveFields, ["station", "track", "artist", "art"])
        XCTAssertTrue(NowPlayingDisplay.privacySensitiveFields.isSubset(of: NowPlayingDisplay.allowedKeys))
        XCTAssertFalse(NowPlayingDisplay.privacySensitiveFields.contains("onAirLabel"), "the dot stays visible (04b)")
        XCTAssertFalse(NowPlayingDisplay.privacySensitiveFields.contains("readyLabel"), "the ready line stays visible")
    }

    // MARK: Store

    func testStoreRoundTripsAndRejectsGarbage() {
        let display = NowPlayingDisplay.make(snapshot: snapshot(), dj: .idle)
        XCTAssertEqual(NowPlayingDisplayStore.decode(NowPlayingDisplayStore.encode(display)), display.widgetCopy)
        XCTAssertNil(NowPlayingDisplayStore.decode(nil))
        XCTAssertNil(NowPlayingDisplayStore.decode(Data("{\"token\":\"x\"}".utf8)))
        XCTAssertEqual(NowPlayingDisplayStore.appGroupID, "group.com.aerodj", "the existing App Group, no new one")
    }

    func testWidgetReloadsOnlyWhenWhatItShowsChanges() {
        let a = NowPlayingDisplay.make(snapshot: snapshot(), dj: .idle)
        let onAir = NowPlayingDisplay.make(snapshot: snapshot(), dj: .speaking(includesBriefing: false))
        XCTAssertTrue(NowPlayingDisplayStore.needsWidgetReload(from: nil, to: a))
        XCTAssertFalse(NowPlayingDisplayStore.needsWidgetReload(from: a, to: onAir), "DJ state alone never reloads")
        let paused = NowPlayingDisplay.make(snapshot: snapshot(.paused), dj: .idle)
        XCTAssertTrue(NowPlayingDisplayStore.needsWidgetReload(from: a, to: paused))
    }

    // MARK: Live Activity plan

    func testLiveActivityStartsOnlyFromTheForegroundWhilePlaying() {
        let playing = NowPlayingDisplay.make(snapshot: snapshot(), dj: .idle)
        XCTAssertEqual(LiveActivityPlan.action(for: playing, previous: nil, isActive: false,
                                               appInForeground: true, activitiesEnabled: true), .start(playing))
        XCTAssertEqual(LiveActivityPlan.action(for: playing, previous: nil, isActive: false,
                                               appInForeground: false, activitiesEnabled: true), .none)
        XCTAssertEqual(LiveActivityPlan.action(for: playing, previous: nil, isActive: false,
                                               appInForeground: true, activitiesEnabled: false), .none)
        let paused = NowPlayingDisplay.make(snapshot: snapshot(.paused), dj: .idle)
        XCTAssertEqual(LiveActivityPlan.action(for: paused, previous: nil, isActive: false,
                                               appInForeground: true, activitiesEnabled: true), .none)
    }

    func testLiveActivityUpdatesOnChangeAndEndsOnStop() {
        let idle = NowPlayingDisplay.make(snapshot: snapshot(), dj: .idle)
        let onAir = NowPlayingDisplay.make(snapshot: snapshot(), dj: .speaking(includesBriefing: false))
        XCTAssertEqual(LiveActivityPlan.action(for: onAir, previous: idle, isActive: true,
                                               appInForeground: false, activitiesEnabled: true), .update(onAir))
        let ready = NowPlayingDisplay.make(snapshot: snapshot(), dj: .ready(includesBriefing: false, seconds: 30))
        XCTAssertEqual(LiveActivityPlan.action(for: ready, previous: idle, isActive: true,
                                               appInForeground: false, activitiesEnabled: true), .update(ready))
        XCTAssertEqual(LiveActivityPlan.action(for: onAir, previous: onAir, isActive: true,
                                               appInForeground: false, activitiesEnabled: true), .none)
        let stopped = NowPlayingDisplay.make(snapshot: snapshot(.stopped), dj: .idle)
        XCTAssertEqual(LiveActivityPlan.action(for: stopped, previous: onAir, isActive: true,
                                               appInForeground: false, activitiesEnabled: true), .end)
        XCTAssertEqual(LiveActivityPlan.action(for: idle, previous: idle, isActive: true,
                                               appInForeground: true, activitiesEnabled: false), .end)
    }

    // MARK: #539 one lock-screen card, and every activity follows the song

    func testLockScreenDropsTheTrackWhileSystemNowPlayingOwnsIt() throws {
        let playing = NowPlayingDisplay.make(snapshot: snapshot(), dj: .ready(includesBriefing: false, seconds: 30))
        XCTAssertTrue(playing.systemNowPlayingOwnsLockScreen)
        XCTAssertFalse(playing.lockScreenShowsPlaybackChrome)
        XCTAssertEqual(playing.track, "Tidewater")
        XCTAssertEqual(playing.widgetCopy.track, "Tidewater", "the widget still carries the song")
        let card = playing.lockScreenPresentation
        XCTAssertNil(card.track)
        XCTAssertNil(card.artist)
        XCTAssertNil(card.art)
        XCTAssertNil(card.station)
        XCTAssertNil(card.state.caption, "no transport line next to the system player")
        XCTAssertEqual(card.state, .playing)
        XCTAssertEqual(card.readyLabel, NowPlayingDisplay.readyLineCopy)
        XCTAssertNil(card.onAirLabel)
        XCTAssertEqual(playing.track, "Tidewater", "the activity payload keeps the song for the island")
        let text = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        XCTAssertFalse(text.contains("Tidewater"))
        XCTAssertFalse(text.contains("Lumen Harbor"))
        XCTAssertFalse(text.contains("Morning Calm"))
        XCTAssertTrue(text.contains(NowPlayingDisplay.readyLineCopy))

        let speaking = NowPlayingDisplay.make(snapshot: snapshot(), dj: .speaking(includesBriefing: false))
        XCTAssertEqual(speaking.lockScreenPresentation.onAirLabel, "On Air")
        XCTAssertNil(speaking.lockScreenPresentation.readyLabel)
        XCTAssertNil(speaking.lockScreenPresentation.track)

        let paused = NowPlayingDisplay.make(snapshot: snapshot(.paused), dj: .idle)
        XCTAssertEqual(paused.state.caption, "Paused")
        XCTAssertTrue(paused.systemNowPlayingOwnsLockScreen)
        XCTAssertNil(paused.lockScreenPresentation.track)
        XCTAssertNil(paused.lockScreenPresentation.state.caption)
        XCTAssertEqual(paused.state, .paused)

        let starting = NowPlayingDisplay.make(snapshot: snapshot(.preparing),
                                              dj: .ready(includesBriefing: false, seconds: 12))
        XCTAssertEqual(starting.state, .starting)
        XCTAssertFalse(starting.systemNowPlayingOwnsLockScreen)
        XCTAssertTrue(starting.lockScreenShowsPlaybackChrome)
        XCTAssertEqual(starting.lockScreenPresentation, starting)
        XCTAssertEqual(starting.lockScreenPresentation.track, "Tidewater")
        XCTAssertEqual(starting.lockScreenPresentation.state.caption, "Starting")

        let stopped = NowPlayingDisplay.make(snapshot: snapshot(.stopped), dj: .idle)
        XCTAssertFalse(stopped.systemNowPlayingOwnsLockScreen)
    }

    func testReconcilerUpdatesEveryActivityOnTrackChange() {
        let first = song("Tidewater")
        let next = song("Paper Satellites")
        XCTAssertNotEqual(first, next)
        XCTAssertEqual(LiveActivityReconciler.commands(display: next,
                                                       running: [LiveActivityRecord(id: "live", content: first)],
                                                       appInForeground: false, activitiesEnabled: true),
                       [.update(id: "live", display: next)])
        let paused = NowPlayingDisplay.make(snapshot: snapshot(.paused), dj: .idle)
        XCTAssertEqual(LiveActivityReconciler.commands(display: paused,
                                                       running: [LiveActivityRecord(id: "live", content: first)],
                                                       appInForeground: false, activitiesEnabled: true),
                       [.update(id: "live", display: paused)])
        let ready = NowPlayingDisplay.make(snapshot: snapshot(), dj: .ready(includesBriefing: false, seconds: 30))
        XCTAssertEqual(LiveActivityReconciler.commands(display: ready,
                                                       running: [LiveActivityRecord(id: "live", content: first)],
                                                       appInForeground: false, activitiesEnabled: true),
                       [.update(id: "live", display: ready)])
        // The song `.first` already shows is not a reason to skip the other activity.
        XCTAssertEqual(LiveActivityReconciler.commands(display: next,
                                                       running: [LiveActivityRecord(id: "shown", content: next),
                                                                 LiveActivityRecord(id: "stuck", content: first)],
                                                       appInForeground: false, activitiesEnabled: true),
                       [.update(id: "stuck", display: next), .end(id: "stuck")])
        XCTAssertEqual(LiveActivityReconciler.commands(display: next,
                                                       running: [LiveActivityRecord(id: "live", content: next)],
                                                       appInForeground: true, activitiesEnabled: true),
                       [])
    }

    func testReconcilerEndsOnStopAndAtStartup() {
        let playing = song("Tidewater")
        let stopped = NowPlayingDisplay.make(snapshot: snapshot(.stopped), dj: .idle)
        XCTAssertEqual(LiveActivityReconciler.commands(display: stopped,
                                                       running: [LiveActivityRecord(id: "live", content: playing),
                                                                 LiveActivityRecord(id: "stuck", content: playing)],
                                                       appInForeground: false, activitiesEnabled: true),
                       [.end(id: "live"), .end(id: "stuck")])
        XCTAssertEqual(LiveActivityReconciler.commands(display: playing,
                                                       running: [LiveActivityRecord(id: "live", content: playing)],
                                                       appInForeground: true, activitiesEnabled: false),
                       [.end(id: "live")])
        XCTAssertEqual(LiveActivityReconciler.startupCommands(running: [
            LiveActivityRecord(id: "live", content: playing),
            LiveActivityRecord(id: "stuck", content: song("Paper Satellites")),
        ]), [.end(id: "live"), .end(id: "stuck")])
        XCTAssertEqual(LiveActivityReconciler.startupCommands(running: []), [])
        // Nothing running, and not a foreground play: do not start a second card later.
        XCTAssertEqual(LiveActivityReconciler.commands(display: stopped, running: [],
                                                       appInForeground: true, activitiesEnabled: true),
                       [])
        XCTAssertEqual(LiveActivityReconciler.commands(display: playing, running: [],
                                                       appInForeground: false, activitiesEnabled: true),
                       [])
        XCTAssertEqual(LiveActivityReconciler.commands(display: playing, running: [],
                                                       appInForeground: true, activitiesEnabled: true),
                       [.start(playing)])
        let starting = NowPlayingDisplay.make(snapshot: snapshot(.preparing), dj: .idle)
        XCTAssertEqual(LiveActivityReconciler.commands(display: starting,
                                                       running: [LiveActivityRecord(id: "live", content: playing)],
                                                       appInForeground: true, activitiesEnabled: true),
                       [.update(id: "live", display: starting)])
    }

    private func song(_ title: String, transport: TransportState = .playing) -> NowPlayingDisplay {
        NowPlayingDisplay.make(snapshot: PlaybackSnapshot(station: station,
                                                          nowPlaying: TrackInfo(id: title, title: title,
                                                                                artistName: "Lumen Harbor"),
                                                          transport: transport),
                               dj: .idle)
    }

    func testLiveActivityFitsUnder160Points() {
        XCTAssertLessThanOrEqual(LiveActivityLayout.contentHeight, LiveActivityLayout.maxHeight)
        XCTAssertEqual(LiveActivityLayout.maxHeight, 160)
        // 14*2 + 20 + 10 + 56 + 10 + 16 = 140, including the Ready line budget.
        XCTAssertEqual(LiveActivityLayout.contentHeight, 140)
    }
}
