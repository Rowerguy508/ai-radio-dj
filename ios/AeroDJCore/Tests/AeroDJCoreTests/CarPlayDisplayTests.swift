import XCTest
@testable import AeroDJCore

/// CarPlay (#438). The car may show station names, the song title, the artist, the
/// station name, and the track artwork URL. Spoken lines, queue rows, errors, and a
/// created station's summary cannot appear there. The audio entitlement stays out of
/// the project until Apple grants it.
final class CarPlayDisplayTests: XCTestCase {
    private let script = "ZZ_DJ_SCRIPT_ZZ"
    private let calendar = "ZZ_CALENDAR_EVENT_ZZ"
    private let email = "ZZ_EMAIL_BODY_ZZ"
    private let artwork = URL(string: "https://example.com/track-art.jpg")!

    private func stuffedSnapshot(track: TrackInfo?,
                                 station: StationRef?,
                                 transport: TransportState = .playing) -> PlaybackSnapshot {
        PlaybackSnapshot(
            station: station,
            nowPlaying: track,
            upNext: [TrackInfo(id: "next", title: calendar, artistName: email, artworkURL: nil)],
            transport: transport,
            dj: .speaking(line: script),
            error: PlaybackError(kind: .speechFailed, message: email, isRecoverable: true))
    }

    private func screen(track: TrackInfo?,
                        station: StationRef? = StationRef(id: "kitchen", name: "Kitchen Radio"),
                        opened: StationRef? = nil,
                        access: PlaybackAccess = .authorized,
                        transport: TransportState = .playing,
                        createdName: String = "Rainy Day") -> CarPlayScreenModel {
        let created = CreatedStationEntry(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                                          name: createdName,
                                          summary: "\(script) \(calendar) \(email)")
        return CarPlayScreen.project(
            builtIn: [CarPlayBuiltInStation(id: "morning", name: "Morning Calm"),
                      CarPlayBuiltInStation(id: "late", name: "Late Night")],
            created: [created],
            snapshot: stuffedSnapshot(track: track, station: station, transport: transport),
            opened: opened,
            access: access)
    }

    private func assertNoSecrets(_ text: [String], file: StaticString = #filePath, line: UInt = #line) {
        let joined = text.joined(separator: "\n")
        for secret in [script, calendar, email] {
            XCTAssertFalse(joined.contains(secret), secret, file: file, line: line)
        }
    }

    func testPersonalBriefingCannotAppearOnTheCar() {
        let track = TrackInfo(id: "song", title: "Slow Burn", artistName: "Neon Harbor", artworkURL: artwork)
        let model = screen(track: track)
        XCTAssertEqual(model.visibleText, [
            "Morning Calm", "Late Night", "Rainy Day",
            "Slow Burn", "Neon Harbor", "Kitchen Radio",
        ])
        XCTAssertNil(model.emptyMessage)
        XCTAssertEqual(model.nowPlaying?.artworkURL, artwork)
        XCTAssertEqual(model.rows.map(\.pick), [
            .builtIn, .builtIn, .created(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
        ])
        assertNoSecrets(model.visibleText)
        let publicationText = model.publication?.fields.visibleText ?? []
        assertNoSecrets(publicationText)
    }

    func testSpokenLineIsNotASubstituteForATrack() {
        let model = screen(track: nil)
        XCTAssertNil(model.nowPlaying)
        XCTAssertNil(model.publication)
        XCTAssertEqual(model.visibleText, ["Morning Calm", "Late Night", "Rainy Day"])
        assertNoSecrets(model.visibleText)
    }

    func testNowPlayingNamesTheSessionStationWhenOneIsSet() {
        let track = TrackInfo(id: "song", title: "Slow Burn", artistName: "Neon Harbor", artworkURL: artwork)
        let opened = StationRef(id: "late", name: "Late Night")
        let model = screen(track: track, station: StationRef(id: "kitchen", name: "Kitchen Radio"), opened: opened)
        XCTAssertEqual(model.nowPlaying?.stationName, "Kitchen Radio")
        assertNoSecrets(model.visibleText)
    }

    func testNowPlayingUsesTheOpenedStationWhenTheSessionHasNone() {
        let track = TrackInfo(id: "song", title: "Slow Burn", artistName: "Neon Harbor", artworkURL: nil)
        let model = screen(track: track, station: nil, opened: StationRef(id: "late", name: "Late Night"))
        XCTAssertEqual(model.nowPlaying, CarPlayNowPlaying(title: "Slow Burn", artist: "Neon Harbor",
                                                           stationName: "Late Night", artworkURL: nil))
        assertNoSecrets(model.visibleText)
    }

    func testNowPlayingUsesTheAppNameWhenNoStationIsKnown() {
        let track = TrackInfo(id: "song", title: "Slow Burn", artistName: "Neon Harbor", artworkURL: nil)
        let model = screen(track: track, station: nil, opened: nil)
        XCTAssertEqual(model.nowPlaying?.stationName, AppName.display)
        assertNoSecrets(model.visibleText)
    }

    func testAccessNoticeIsFixedCopyAndDoesNotCarryTheSnapshot() {
        let track = TrackInfo(id: "song", title: "Slow Burn", artistName: "Neon Harbor", artworkURL: artwork)
        let denied = screen(track: track, access: .denied)
        XCTAssertEqual(denied.accessNotice, NowPlayingContent.accessDenied.title)
        XCTAssertEqual(denied.visibleText.last, NowPlayingContent.accessDenied.title)
        assertNoSecrets(denied.visibleText)

        XCTAssertEqual(CarPlayScreen.accessNotice(for: .needsAuthorization), NowPlayingContent.needsAuthorization.title)
        XCTAssertEqual(CarPlayScreen.accessNotice(for: .subscriptionRequired), NowPlayingContent.subscriptionRequired.title)
        XCTAssertNil(CarPlayScreen.accessNotice(for: .authorized))
        XCTAssertNil(CarPlayScreen.accessNotice(for: .checking))
        let notices = [denied.accessNotice, CarPlayScreen.accessNotice(for: .needsAuthorization),
                       CarPlayScreen.accessNotice(for: .subscriptionRequired)].compactMap { $0 }
        assertNoSecrets(notices)
    }

    func testBlankStationNamesAreOmittedSoASummaryCannotFillThem() {
        let model = screen(track: nil, createdName: " \n\t ")
        XCTAssertEqual(model.rows.map(\.name), ["Morning Calm", "Late Night"])
        XCTAssertNil(model.emptyMessage)
        assertNoSecrets(model.visibleText)
    }

    func testASpokenLineDoesNotChangeThePublication() {
        let track = TrackInfo(id: "song", title: "Slow Burn", artistName: "Neon Harbor", artworkURL: artwork)
        let speaking = stuffedSnapshot(track: track, station: StationRef(id: "kitchen", name: "Kitchen Radio"))
        var quiet = speaking
        quiet.dj = .idle
        let opened: StationRef? = nil
        XCTAssertEqual(CarPlayScreen.project(builtIn: [], created: [], snapshot: speaking, opened: opened, access: .authorized).publication,
                       CarPlayScreen.project(builtIn: [], created: [], snapshot: quiet, opened: opened, access: .authorized).publication)
    }

    func testPlaybackConfirmRepublishesTheSameWords() {
        let track = TrackInfo(id: "song", title: "Slow Burn", artistName: "Neon Harbor", artworkURL: artwork)
        let preparing = screen(track: track, transport: .preparing).publication
        let playing = screen(track: track, transport: .playing).publication
        XCTAssertNotEqual(preparing, playing)
        XCTAssertEqual(preparing?.fields, playing?.fields)
        assertNoSecrets(playing?.fields.visibleText ?? [])
    }

    func testPickingAStationUsesTheExistingStartPaths() {
        let id = UUID()
        XCTAssertEqual(CarPlayStationStart.trigger, .userTap)
        XCTAssertEqual(CarPlayScreen.effect(for: .created(id)), .openCreatedStation(id))
        XCTAssertEqual(CarPlayScreen.effect(for: .builtIn), .openBuiltInShell)
    }

    func testNextMatchesTheRemoteCommandAndPreviousStaysOff() {
        XCTAssertFalse(CarPlayTransport.previousTrackEnabled)
        for index in 0..<5 {
            for count in 0..<5 {
                XCTAssertEqual(CarPlayTransport.nextTrackEnabled(queueIndex: index, queueCount: count),
                               RemoteNextCommand.isEnabled(queueIndex: index, queueCount: count),
                               "index \(index) count \(count)")
            }
        }
    }

    func testNowPlayingMergeKeepsTimingAndDropsPersonalTextKeys() {
        let fields = CarPlayNowPlaying(title: "Slow Burn", artist: "Neon Harbor",
                                       stationName: "Kitchen Radio", artworkURL: artwork)
        let info: [String: Any] = [
            CarPlayNowPlayingMerge.titleKey: script,
            CarPlayNowPlayingMerge.artistKey: calendar,
            CarPlayNowPlayingMerge.stationNameKey: email,
            CarPlayNowPlayingMerge.lyricsKey: script,
            CarPlayNowPlayingMerge.commentsKey: email,
            "elapsedPlaybackTime": 12.5,
            "playbackDuration": 200.0,
            "playbackRate": 1.0,
        ]
        let merged = CarPlayNowPlayingMerge.apply(fields: fields, to: info)
        XCTAssertEqual(merged[CarPlayNowPlayingMerge.titleKey] as? String, "Slow Burn")
        XCTAssertEqual(merged[CarPlayNowPlayingMerge.artistKey] as? String, "Neon Harbor")
        XCTAssertEqual(merged[CarPlayNowPlayingMerge.stationNameKey] as? String, "Kitchen Radio")
        XCTAssertNil(merged[CarPlayNowPlayingMerge.lyricsKey])
        XCTAssertNil(merged[CarPlayNowPlayingMerge.commentsKey])
        XCTAssertEqual(merged["elapsedPlaybackTime"] as? Double, 12.5)
        XCTAssertEqual(merged["playbackDuration"] as? Double, 200.0)
        XCTAssertEqual(merged["playbackRate"] as? Double, 1.0)
        let strings = merged.values.compactMap { $0 as? String }
        XCTAssertEqual(Set(strings), ["Slow Burn", "Neon Harbor", "Kitchen Radio"])
        assertNoSecrets(strings)
        XCTAssertFalse(strings.contains(artwork.absoluteString))
    }

    func testSceneManifestAddsCarPlayWithoutASecondPhoneWindow() throws {
        let plist = try sourcePlist("AeroDJ/Info.plist")
        let manifest = try XCTUnwrap(plist["UIApplicationSceneManifest"] as? [String: Any])
        XCTAssertEqual(manifest["UIApplicationSupportsMultipleScenes"] as? Bool, false)
        let configs = try XCTUnwrap(manifest["UISceneConfigurations"] as? [String: Any])
        XCTAssertNil(configs["UIWindowSceneSessionRoleApplication"], "SwiftUI keeps the one phone window")
        let scenes = try XCTUnwrap(configs["CPTemplateApplicationSceneSessionRoleApplication"] as? [[String: Any]])
        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(scenes[0]["UISceneClassName"] as? String, "CPTemplateApplicationScene")
        XCTAssertEqual(scenes[0]["UISceneConfigurationName"] as? String, "CarPlay")
        XCTAssertEqual(scenes[0]["UISceneDelegateClassName"] as? String, "$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate")
    }

    func testCarPlayAudioEntitlementIsNotInTheProject() throws {
        let forbidden = ["com.apple.developer.carplay", "audio"].joined(separator: "-")
        let roots = ["AeroDJ", "AeroDJShare", "AeroDJCore", "Config"].map { iosDir.appendingPathComponent($0) }
        var hits: [String] = []
        for root in roots {
            let found = try files(at: root, extensions: ["swift", "plist", "entitlements", "xcconfig", "yml"])
            for url in found {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains(forbidden) {
                    hits.append(url.path.replacingOccurrences(of: iosDir.path + "/", with: ""))
                }
            }
        }
        let project = try String(contentsOf: iosDir.appendingPathComponent("project.yml"), encoding: .utf8)
        if project.contains(forbidden) { hits.append("project.yml") }
        XCTAssertEqual(hits, [])
    }

    func testCarPlaySceneUsesTemplatesAndTheExistingStartPaths() throws {
        let files = try files(at: iosDir.appendingPathComponent("AeroDJ"), extensions: ["swift"])
            .filter { $0.lastPathComponent.hasPrefix("CarPlay") }
        XCTAssertEqual(Set(files.map(\.lastPathComponent)),
                       ["CarPlaySceneDelegate.swift", "CarPlayNowPlayingBridge.swift"])
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for required in [
            "CPListTemplate",
            "CPNowPlayingTemplate",
            "CPTemplateApplicationSceneDelegate",
            "openCreatedStation(.userTap",
            "cancelCreatedStationStart",
            "CarPlayNowPlayingMerge.apply",
            "MPNowPlayingInfoCenter.default()",
            "CarPlayTransport.previousTrackEnabled",
            "detailText: nil",
            "CarPlayScreen.project",
        ] {
            XCTAssertTrue(code.contains(required), required)
        }
        let lowered = code.lowercased()
        for banned in ["snapshot.dj", "snapshot.error", ".upnext", ".speaking", "briefing", "eventkit",
                       "avaudiosession", "elevenlabs", ".skip(", "func skip", "nexttrackcommand.addtarget",
                       "previoustrackcommand.isenabled = true", "setcategory", "setactive(", "logger(", "print("] {
            XCTAssertFalse(lowered.contains(banned), banned)
        }
        for banned in ["calendar", "email"] {
            XCTAssertFalse(lowered.contains(banned), banned)
        }
    }

    func testLateFetchForTheSameArtworkDoesNotRestoreTheEarlierSong() {
        var gate = CarPlayArtworkGate()
        let url = URL(string: "https://example.com/shared.jpg")!
        let songA = nowPlaying("Song A", "Artist A", "Station A", url)
        let songB = nowPlaying("Song B", "Artist B", "Station B", url)
        let started = gate.publish(songA)
        let token = fetchToken(started)
        XCTAssertEqual(gate.publish(songB), [.writeText(songB)])
        XCTAssertEqual(gate.fetchArrived(token), .setArtwork(url))
    }

    func testChangingTheArtworkURLClearsTheOldImageImmediately() {
        var gate = CarPlayArtworkGate()
        let first = URL(string: "https://example.com/a.jpg")!
        let second = URL(string: "https://example.com/b.jpg")!
        let songA = nowPlaying("Song A", "Artist A", "Station A", first)
        let songB = nowPlaying("Song B", "Artist B", "Station B", second)
        let tokenA = fetchToken(gate.publish(songA))
        let next = gate.publish(songB)
        XCTAssertEqual(next.first, .writeText(songB))
        XCTAssertTrue(next.contains(.clearArtwork))
        let tokenB = fetchToken(next)
        XCTAssertNotEqual(tokenA, tokenB)
        XCTAssertEqual(gate.fetchArrived(tokenA), .ignore)
        XCTAssertEqual(gate.fetchArrived(tokenB), .setArtwork(second))
    }

    func testClearingTheArtworkURLDropsTheImageImmediately() {
        var gate = CarPlayArtworkGate()
        let url = URL(string: "https://example.com/a.jpg")!
        let songA = nowPlaying("Song A", "Artist A", "Station A", url)
        let token = fetchToken(gate.publish(songA))
        let cleared = nowPlaying("Song B", "Artist B", "Station B", nil)
        let next = gate.publish(cleared)
        XCTAssertEqual(next, [.writeText(cleared), .clearArtwork])
        XCTAssertEqual(gate.fetchArrived(token), .ignore)
    }

    func testAnOlderFetchThatFinishesLastDoesNotWin() {
        var gate = CarPlayArtworkGate()
        let first = URL(string: "https://example.com/a.jpg")!
        let second = URL(string: "https://example.com/b.jpg")!
        let songA = nowPlaying("Song A", "Artist A", "Station A", first)
        let songB = nowPlaying("Song B", "Artist B", "Station B", second)
        let tokenA = fetchToken(gate.publish(songA))
        let tokenB = fetchToken(gate.publish(songB))
        XCTAssertEqual(gate.fetchArrived(tokenB), .setArtwork(second))
        XCTAssertEqual(gate.fetchArrived(tokenA), .ignore)
        XCTAssertEqual(gate.publish(songB), [.writeText(songB)], "the image already showing is left in place")
    }

    private func nowPlaying(_ title: String, _ artist: String, _ station: String, _ artwork: URL?) -> CarPlayNowPlaying {
        CarPlayNowPlaying(title: title, artist: artist, stationName: station, artworkURL: artwork)
    }

    private func fetchToken(_ commands: [CarPlayArtworkGate.Command],
                            file: StaticString = #filePath, line: UInt = #line) -> CarPlayArtworkGate.Token {
        for command in commands {
            if case .startFetch(let token) = command { return token }
        }
        XCTFail("no fetch", file: file, line: line)
        return CarPlayArtworkGate.Token(id: 0, url: URL(string: "https://example.com/missing.jpg")!)
    }

    // MARK: - Repo fixtures

    private var iosDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sourcePlist(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: iosDir.appendingPathComponent(relative))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func files(at root: URL, extensions: [String]) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            XCTFail("missing \(root.path)")
            return []
        }
        let skip: Set = ["build", ".build", "DerivedData", ".git"]
        var found: [URL] = []
        while let url = walker.nextObject() as? URL {
            if skip.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if extensions.contains(url.pathExtension) { found.append(url) }
        }
        return found
    }
}

/// Picking station B on the car runs the phone's created-station tap (`open(.userTap)`).
/// The assertions are the queue's song ids and the active station, not a call count.
@MainActor
final class CarPlayStationSwitchTests: XCTestCase {
    private let stationA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let stationB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private actor Catalog: StationSeedCatalog {
        func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] {
            (0..<min(limit, 4)).map { n in
                StationCandidate(track: TrackInfo(id: "\(seed.catalogID)-song-\(n)", title: "Title \(n)",
                                                   artistName: "\(seed.catalogID)-artist"))
            }
        }
        func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { [] }
        func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { [] }
    }

    private final class Player {
        var queue: [String] = []
        var playing = false
        var nothingQueued: Bool { queue.isEmpty && !playing }
    }

    private func configuration(_ token: String) -> StationConfiguration {
        var configuration = StationConfiguration.default
        configuration.seeds = [StationSeed(kind: .artist, catalogID: token, name: token)]
        configuration.reach = .only
        return configuration.validated()
    }

    private func makeFeed() -> StationQueueFeed<String> {
        StationQueueFeed(
            resolver: CatalogStationSeedResolver(catalog: Catalog()),
            materialize: { $0.map(\.id) },
            options: .init(limit: 4),
            day: { 42 })
    }

    private func makeModel() async -> StationConfigurationModel {
        let model = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .default))),
            consent: StaticIntegrationConsent([:]))
        await model.load()
        return model
    }

    /// The car's pick: `CreatedStationStarter.open` with `CarPlayStationStart.trigger`.
    private func pick(_ id: UUID, _ token: String, _ starter: CreatedStationStarter<String>,
                      _ model: StationConfigurationModel, _ player: Player) async -> CreatedStationOpenOutcome {
        let config = configuration(token)
        return await starter.open(
            CarPlayStationStart.trigger,
            recipeID: id,
            authorize: {},
            apply: {
                await model.applyRecipe(StationRecipe(name: token, configuration: config))
                return true
            },
            active: { model.active },
            nothingQueued: { player.nothingQueued },
            start: { items in
                player.queue = items
                player.playing = true
            })
    }

    private func startA(_ starter: CreatedStationStarter<String>, _ model: StationConfigurationModel,
                        _ player: Player) async -> [String] {
        let outcome = await pick(stationA, "station-a", starter, model, player)
        guard case .started = outcome else {
            XCTFail("station A did not start: \(outcome)")
            return []
        }
        XCTAssertTrue(player.queue.allSatisfy { $0.hasPrefix("station-a-") }, "\(player.queue)")
        return player.queue
    }

    private func staged(_ feed: StationQueueFeed<String>, _ key: StationQueueKey) async {
        for _ in 0..<200 where feed.stagedKey != key {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testPickingStationBWhileAIsPlayingKeepsAsQueueUntilTheBoundaryThenPlaysB() async {
        let model = await makeModel()
        let feed = makeFeed()
        feed.follow(model)
        let player = Player()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(2), pollInterval: .milliseconds(1))
        let queueA = await startA(starter, model, player)
        await model.setPlaybackActivity(.holdingSong)
        XCTAssertTrue(player.playing)

        let outcome = await pick(stationB, "station-b", starter, model, player)
        XCTAssertEqual(outcome, .switchesAtBoundary)
        XCTAssertEqual(player.queue, queueA, "the playing queue is still station A")
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["station-a"])
        XCTAssertEqual(starter.currentRecipeID, stationB)
        XCTAssertEqual(CarPlayStationStart.trigger, .userTap)

        await staged(feed, StationQueueKey(configuration("station-b"))!)
        await model.handle(.songBoundary(afterTrack: 0))
        let next = feed.takeForBoundary(active: model.active, playbackMayStart: true)
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["station-b"])
        XCTAssertEqual(next?.allSatisfy { $0.hasPrefix("station-b-") }, true, "\(next ?? [])")
        XCTAssertNotEqual(next, queueA)
    }

    func testPickingStationBWhileAIsPausedKeepsAsQueueUntilTheBoundaryThenPlaysB() async {
        let model = await makeModel()
        let feed = makeFeed()
        feed.follow(model)
        let player = Player()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(2), pollInterval: .milliseconds(1))
        let queueA = await startA(starter, model, player)
        player.playing = false
        await model.setPlaybackActivity(.holdingSong)
        XCTAssertFalse(player.nothingQueued, "paused mid-song still has station A's queue")

        let outcome = await pick(stationB, "station-b", starter, model, player)
        XCTAssertEqual(outcome, .switchesAtBoundary)
        XCTAssertEqual(player.queue, queueA)
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["station-a"])
        XCTAssertEqual(starter.currentRecipeID, stationB)

        await staged(feed, StationQueueKey(configuration("station-b"))!)
        await model.handle(.songBoundary(afterTrack: 0))
        let next = feed.takeForBoundary(active: model.active, playbackMayStart: true)
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["station-b"])
        XCTAssertEqual(next?.allSatisfy { $0.hasPrefix("station-b-") }, true, "\(next ?? [])")
    }

    func testPickingStationBWhileIdleReplacesTheQueueWithB() async {
        let model = await makeModel()
        let feed = makeFeed()
        feed.follow(model)
        let player = Player()
        let starter = CreatedStationStarter(feed: feed, readyTimeout: .seconds(2), pollInterval: .milliseconds(1))
        _ = await startA(starter, model, player)
        player.queue = []
        player.playing = false
        await model.setPlaybackActivity(.idle)
        XCTAssertTrue(player.nothingQueued)
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["station-a"])

        let outcome = await pick(stationB, "station-b", starter, model, player)
        guard case .started(let songs, _) = outcome else { return XCTFail("expected B to start, got \(outcome)") }
        XCTAssertEqual(songs, player.queue.count)
        XCTAssertFalse(player.queue.isEmpty)
        XCTAssertTrue(player.queue.allSatisfy { $0.hasPrefix("station-b-") }, "\(player.queue)")
        XCTAssertEqual(model.active.seeds.map(\.catalogID), ["station-b"])
        XCTAssertEqual(starter.currentRecipeID, stationB)
        XCTAssertEqual(CarPlayStationStart.trigger, .userTap)
    }
}
