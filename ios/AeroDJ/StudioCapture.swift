#if DEBUG
import AeroDJCore
import SwiftUI

/// Debug-only screenshot and UI-test harness. Honoured only in the test station
/// (`-AeroDJTestStation YES`) and only with `-AeroDJStudioCapture YES`; Release builds do
/// not compile it. It renders the real `PlayingScreen` with the test station's
/// `StudioPresentationModel` and the shared `PlaybackFixtures` snapshot, with actions that
/// do nothing, so no Apple Music permission prompt or playback is involved.
enum StudioCapture {
    static let defaultsKey = "AeroDJStudioCapture"
    /// Optional: `queue`, `tune` or `connections`.
    static let segmentKey = "AeroDJStudioCaptureSegment"
    /// Optional: a `StudioCaptureScenario` raw value (default `playing`).
    static let scenarioKey = "AeroDJStudioCaptureScenario"
    /// Optional: `YES` renders the capture in dark appearance (the simulator-wide
    /// appearance switch is not reliable before launch).
    static let darkKey = "AeroDJStudioCaptureDark"
    /// Optional: `YES` forces Reduce Motion for the capture, whatever the simulator setting is.
    static let reduceMotionKey = "AeroDJReduceMotion"
    /// `duoWideReady`: the stand-in for the unfolded Duo's split-view detail. The UI test
    /// (`testDuoWideListenPlayerIsOneCentredColumn`) checks the same 640 × 820 pt.
    static let duoWideContainerSize = CGSize(width: 640, height: 820)
    /// `duoTent` (#465 item 3): the unfolded Duo rotated, fold horizontal at y = 320. Assumed
    /// from the 640 × 820 pt measurement, as in the owner mockup; not measured in a tent.
    static let duoTentContainerSize = CGSize(width: 820, height: 640)

    static func isRequested(mode: AppRuntimeMode, defaults: UserDefaults = .standard) -> Bool {
        mode == .testStation && defaults.bool(forKey: defaultsKey)
    }
}

/// The states a capture run can show. Each one is the real `PlayingScreen` / Studio model
/// in that state, reached through the same intents the UI uses, never a mock-up.
enum StudioCaptureScenario: String {
    /// A fixture song playing with two queued.
    case playing
    /// Authorized, nothing queued: the empty state with Apple Music search.
    case empty
    /// Still connecting to Apple Music.
    case loading
    /// A recoverable playback error banner.
    case error
    /// Music plays, and the player reported that the last DJ break failed to play
    /// (`DJPresentationEvent.playbackFailed`, the same event the audio player sends).
    case playbackFailed
    /// A rendered break is waiting (`.ready`, no briefing). The playing screen must not
    /// show the break headline or its VoiceOver detail.
    case breakReady
    /// Apple Music access denied: the Settings path, no transport.
    case denied
    /// The fixture calendar was turned off via Connections (`perform(.revoke)`): selection
    /// cleared and anything prepared from it purged.
    case revoked
    /// The listener changed energy and genres in the tuner: saved, pending the next boundary.
    case config
    /// The fixture station list (`Station.defaultStations`). Not the playing screen.
    /// The share extension is not a scenario: `AeroDJShare` draws nothing and has no colours.
    case stations
    /// Empty player inside a width probe: compact, then regular, without searching or playing.
    case resize
    /// Tuner with a pending change, then the same width probe.
    case resizeTune
    /// The real station split. Selecting a row must not start playback.
    case shell
    /// #454: the real station split with the tap route wired: a row, card or Duo dial tap selects
    /// the station and records the id it would start (`capture.startedStation`), and Now Playing
    /// shows that station's "Starting <name>…". Nothing searches or plays.
    case stationTap
    /// The listen player with a break ready (`breakReady`) in a 640 × 820 pt compact-class
    /// container: below the Studio switch but wider than any phone in portrait, like the
    /// unfolded Duo's split-view detail (owner, build 25). Needs a window at least that big.
    case duoWideReady
    /// The same 640 × 820 pt container with nothing playing, so Search Apple Music is the
    /// content column's first control.
    case duoWideEmpty
    /// A side-by-side split. `AeroDJSplitExample` is `narrow`, `half` or `wide`.
    case splitView
    /// Folded phone container, then the unfolded Duo, in one launch. Playback, the
    /// scroll anchor and the selected station must survive the size-class change.
    case duoContinuity
    /// The unfolded rail with the DJ speaking, so the live dot is lit. Same container as
    /// `duoWideReady`. The ON AIR pill's timer is frozen, as in `onAir`.
    case duoWideSpeaking
    /// Regular width at the same 640 × 820 pt: artwork and controls in one pane, the
    /// up-next timeline in the other. The compact-class `duoWideReady` container is unchanged.
    case duoArrangement
    /// The same 640 × 820 pt container with the DJ on air: `breakReady` then `playbackStarted`,
    /// the same events as `onAir`, with the ON AIR timer frozen at 0:12. The track column
    /// keeps the art (`keepArtVisible`); the orb sits in the content column (`folded.visualizer`).
    case duoWideOnAir
    /// The DJ is on air: a break became ready and the player reported it started
    /// (`breakReady` then `playbackStarted`, the same events the audio player sends), so the
    /// folded player draws the ON AIR pill. At default size, `testDefaultOnAirShowsOrbOnlyArtCard`
    /// captures `closed-onair` / `open-onair` (#435 n1). At AX5 on a phone the pill is pinned
    /// above the scrubber (#310, `testAX5OnAirPinnedAboveScrubber`).
    case onAir
    /// Station ratings (-Nova, PR B): `playing` with the rating button, unrated, with its
    /// first-time "Rate" label. The other scenarios get no rating controller, so they are unchanged.
    case ratingFirstTime
    /// #454: a station row was tapped and its first song is on its way: "Starting <name>…" on
    /// Now Playing, never the search field.
    case stationStarting
    /// #454: the tapped station could not start: "Couldn't start <name>" with Try again (which
    /// counts a play in the capture), on the same screen, never the search field.
    case stationStartFailed
    /// The playing song rated Like it (plus.circle), label already seen.
    case ratingLiked
    /// The playing song was Like it, then Never: the Undo toast over the player. The fixture
    /// holds that toast until Undo (no skip: the capture has no playing-song id). Production
    /// still dismisses a never toast after six seconds.
    case ratingNever
    /// #465 item 3: the tent pose with the DJ on air (`breakReady` then `playbackStarted`), in
    /// an 820 × 640 pt container. The hinge is forced to partially open at 100° and fed to the
    /// real `DuoPoseDecision`; the clock and the on-air timer are frozen. Needs an iPad window.
    case duoTent

    var access: PlaybackAccess {
        switch self {
        case .loading: .checking
        case .denied: .denied
        case .stations, .resize, .resizeTune, .shell, .stationTap: .authorized
        default: .authorized
        }
    }

    var snapshot: PlaybackSnapshot {
        switch self {
        case .empty, .loading, .denied, .stations, .resize, .stationStarting, .stationStartFailed, .duoWideEmpty:
            return PlaybackFixtures.stopped
        case .error:
            return PlaybackFixtures.recoverableError
        case .duoWideReady, .duoWideSpeaking, .duoArrangement, .duoWideOnAir:
            // A playing song the listener can seek. The shared fixture leaves canSeek false,
            // which draws the scrubber as a non-interactive element.
            var playing = PlaybackFixtures.playing
            playing.canSeek = true
            return playing
        default:
            return PlaybackFixtures.playing
        }
    }

    /// The workspace segment the scenario is about, if any.
    var segment: WorkspaceSegment? {
        switch self {
        case .revoked: .connections
        case .config, .resizeTune: .tune
        case .resize: .queue
        case .stations, .shell, .stationTap: nil
        default: nil
        }
    }
}

struct StudioCaptureView: View {
    let dependencies: AppDependencies
    @State private var loaded = false
    @State private var scenario: StudioCaptureScenario = .playing
    /// Owned here, outside the wide player, so the fold control stays in the window.
    @State private var probeWide = false
    @ObservedObject private var calls = PlaybackCallLog.shared
    /// Set when the station never finished loading. The capture refuses to render a screenshot
    /// that depends on timing; UI tests fail on `capture.failed` (StudioScreenTests.launch).
    @State private var failure: String?
    /// Only the rating scenarios set one; nil keeps every other capture as it was (-Nova, PR B).
    @State private var captureRating: SongRatingController?
    @StateObject private var continuityLoads = DisplayContinuityLoadCounter()

    private var showsProbe: Bool {
        loaded && (scenario == .resize || scenario == .resizeTune)
    }

    var body: some View {
        // The player pins to the leading edge and may be wider than the window. The fold
        // control is an overlay of this root's safe-area frame, top trailing, so it stays
        // inside the visible window instead of riding that wide column.
        Group {
            if let failure {
                Text(failure)
                    .accessibilityIdentifier("capture.failed")
            } else if !loaded {
                // Own branch (not nested in NavigationStack): must leave the tree when
                // `loaded` flips so XCTest cannot keep matching a stale ProgressView.
                Text("Loading studio capture")
                    .font(.body)
                    .accessibilityIdentifier("capture.loading")
            } else if scenario == .duoTent {
                TentCaptureContainer(scenario: scenario, studio: dependencies.studio)
            } else if scenario == .stations {
                // The split is the root. An outer NavigationStack makes compact width
                // open the detail column, so the fixture list never appears.
                StationListCapture()
            } else if scenario == .shell || scenario == .stationTap {
                // Auth is settled in `.task` before `loaded` so the shell never paints
                // `.checking` / Connecting in place of Allow.
                CaptureStationSplit(dependencies: dependencies, routesTaps: scenario == .stationTap)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("capture.shell")
            } else if scenario == .duoWideReady || scenario == .duoWideEmpty || scenario == .duoWideSpeaking || scenario == .duoWideOnAir {
                DuoWideCaptureContainer(scenario: scenario, studio: dependencies.studio)
            } else if scenario == .splitView {
                SplitViewCapture(studio: dependencies.studio)
            } else if scenario == .duoContinuity {
                DuoContinuityCapture(studio: dependencies.studio, loads: continuityLoads)
            } else if scenario == .duoArrangement {
                ArrangementCaptureContainer(studio: dependencies.studio)
            } else {
                NavigationStack {
                    if showsProbe {
                        LayoutResizeProbe(wide: $probeWide, scenario: scenario, studio: dependencies.studio)
                    } else {
                        PlayingScreen(station: PlaybackFixtures.station, access: scenario.access,
                                      snapshot: scenario.snapshot, actions: .preview,
                                      search: scenario == .empty ? .counting : .captureOffline,
                                      studio: dependencies.studio, isTestStation: true,
                                      timeSource: scenario.snapshot.transport == .playing ? .fixture : nil)
                    }
                }
                .modifier(SongRatingToastHost())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            if showsProbe {
                ProbeChrome(wide: $probeWide)
            } else if loaded && scenario == .empty {
                Text(verbatim: calls.label)
                    .font(.caption.monospacedDigit())
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .accessibilityIdentifier("playback.calls")
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(UserDefaults.standard.bool(forKey: StudioCapture.darkKey) ? .dark : nil)
        // Replaces the app root's controller: nil outside the rating scenarios.
        .environment(\.songRating, captureRating)
        .overlay(alignment: .bottomLeading) {
            // ratingNever only: the playing song's rating and its station scope, for the Undo test.
            // One point, not hittable, so it does not cover Undo or move the player.
            if loaded, scenario == .ratingNever, let captureRating {
                RatingCaptureReadout(controller: captureRating, songID: PlaybackFixtures.songs[0].id)
            }
        }
        .task {
            // The app root's task starts Studio (b39d15f). Wait for that load to finish rather
            // than loading again: a second load would overwrite the scenario's edits below.
            let studio = dependencies.studio
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: DisplayContinuityLaunch.probeKey)
            let name = defaults.string(forKey: StudioCapture.scenarioKey) ?? "playing"
            var settled = false
            for _ in 0..<200 {
                switch studio.station.loadState {
                case .ready, .failed: settled = true
                default: try? await Task.sleep(for: .milliseconds(50))
                }
                if settled { break }
            }
            guard settled else {
                failure = "Studio capture failed: station did not load within 10 s (scenario \(name))"
                return
            }
            guard let chosen = StudioCaptureScenario(rawValue: name) else {
                failure = "Studio capture failed: unknown scenario \(name)"
                return
            }
            scenario = chosen
            if chosen == .duoContinuity {
                defaults.set(true, forKey: DisplayContinuityLaunch.probeKey)
                // The station model finished loading above. One load, not one per layout.
                continuityLoads.noteLoad()
            }
            switch scenario {
            case .revoked:
                await studio.connections.refresh()
                await studio.connections.perform(.revoke, onSource: .calendar)
            case .playbackFailed:
                studio.dj.send(.playbackFailed(afterTrack: 0))
            case .breakReady, .duoWideReady, .duoArrangement:
                studio.dj.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 30))
            case .duoWideSpeaking, .onAir, .duoWideOnAir:
                // Freeze the pill's timer before it appears, so the PNG is deterministic.
                StudioCaptureOnAir.frozenElapsed = StudioCaptureOnAir.capturedElapsed
                studio.dj.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 30))
                studio.dj.send(.playbackStarted(afterTrack: 0))
            case .config, .resizeTune:
                // Fry #110: Save while holding schedules pending until a safe boundary.
                // Idle Save would apply immediately ("Saved…"), which breaks
                // testStationConfigChangeIsPendingNotActive / testPendingTuneSurvivesFold.
                await studio.station.setPlaybackActivity(.holdingSong)
                await studio.station.setEnergy(0.85)
                await studio.station.setGenres(["pop", "indie", "synthwave"])
                await studio.station.saveChanges()
            case .stationStarting:
                studio.stationStart.begin(stationID: PlaybackFixtures.station.id,
                                          stationName: PlaybackFixtures.station.name, songAtTap: nil)
            case .stationStartFailed:
                let tap = studio.stationStart.begin(stationID: PlaybackFixtures.station.id,
                                                    stationName: PlaybackFixtures.station.name, songAtTap: nil,
                                                    retry: { PlaybackCallLog.shared.recordPlay() })
                studio.stationStart.finish(tap: tap, outcome: .notStarted(.notReadyInTime))
            case .ratingFirstTime:
                captureRating = await SongRatingController.fixture(songID: PlaybackFixtures.songs[0].id)
            case .ratingLiked:
                captureRating = await SongRatingController.fixture(rated: .like, songID: PlaybackFixtures.songs[0].id, labelSeen: true)
            case .duoTent:
                TentPoseCapture.forcedHinge = TentPoseCapture.capturedHinge
                TentPoseCapture.frozenDate = TentPoseCapture.capturedDate
                StudioCaptureOnAir.frozenElapsed = StudioCaptureOnAir.capturedElapsed
                studio.dj.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 30))
                studio.dj.send(.playbackStarted(afterTrack: 0))
            case .ratingNever:
                let song = PlaybackFixtures.songs[0]
                let rating = await SongRatingController.fixture(rated: .like, songID: song.id, labelSeen: true, holdToast: true)
                await rating.rate(.never, songID: song.id, artistName: song.artistName)
                captureRating = rating
            default:
                break
            }
            if let segment = defaults.string(forKey: StudioCapture.segmentKey).flatMap(WorkspaceSegment.init) ?? scenario.segment {
                StudioCaptureSegment.initial = segment
            }
            // Shell observes authState. Settle the non-prompting status before flipping
            // `loaded`, so CaptureStationSplit's first frame is Allow / denied / ready —
            // never the bare Connecting spinner, and never blocked on MusicKit request().
            if chosen == .shell || chosen == .stationTap {
                await dependencies.playback.refreshAuthorizationStatus()
            }
            loaded = true
        }
    }
}

/// The unfolded Duo's split-view detail, stood in by a fixed 640 × 820 pt compact-class
/// container (`StudioCapture.duoWideContainerSize`). Fry, #207: the first capture pinned that
/// container top-leading inside the iPad window with nothing behind it, so the screenshot was
/// three quarters player and one quarter blank, and read as a capture taken mid-resize (the
/// "spinner" in the corner is iPadOS's window resize grip, on every iPad shot). Now the
/// container owns its NavigationStack like a split-view detail column, sits centred on a
/// neutral backdrop, is clipped to its own bounds (the art glow no longer bleeds past it) and
/// is outlined, so the frame shows exactly what the Duo shows. `capture.duoContainer` lets
/// the UI test wait for its final size and position before the screenshot.
private struct DuoWideCaptureContainer: View {
    let scenario: StudioCaptureScenario
    let studio: StudioPresentationModel

    @State private var openedStation = ""

    var body: some View {
        let size = StudioCapture.duoWideContainerSize
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let stops = [
            DuoStationSwitch.Stop(id: PlaybackFixtures.station.id, name: PlaybackFixtures.station.name),
            DuoStationSwitch.Stop(id: "late-night", name: "Late Night"),
        ]
        ZStack {
            Color(white: 0.14)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            NavigationStack {
                PlayingScreen(station: PlaybackFixtures.station, access: scenario.access,
                              snapshot: scenario.snapshot, actions: .preview,
                              search: .captureOffline,
                              studio: studio, isTestStation: true,
                              timeSource: .fixture,
                              stationStops: stops,
                              onOpenStation: { openedStation = $0 })
                Text(verbatim: openedStation)
                    .font(.system(size: 1))
                    .accessibilityIdentifier("duo.openedStation")
                    .accessibilityLabel(openedStation)
                    .allowsHitTesting(false)
            }
            .environment(\.horizontalSizeClass, .compact)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1).allowsHitTesting(false) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture.duoContainer")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// The tent pose (#465 item 3) in a fixed 820 × 640 pt container on the same neutral
/// backdrop as `DuoWideCaptureContainer`. `capture.tentContainer` lets the UI test wait for
/// its final size before the screenshot.
private struct TentCaptureContainer: View {
    let scenario: StudioCaptureScenario
    let studio: StudioPresentationModel

    @State private var openedStation = ""

    var body: some View {
        let size = StudioCapture.duoTentContainerSize
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let stops = [
            DuoStationSwitch.Stop(id: PlaybackFixtures.station.id, name: PlaybackFixtures.station.name),
            DuoStationSwitch.Stop(id: "late-night", name: "Late Night"),
        ]
        ZStack {
            Color(white: 0.14)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            NavigationStack {
                PlayingScreen(station: PlaybackFixtures.station, access: scenario.access,
                              snapshot: scenario.snapshot, actions: .preview,
                              search: .captureOffline,
                              studio: studio, isTestStation: true,
                              timeSource: .fixture,
                              stationStops: stops,
                              onOpenStation: { openedStation = $0 })
                Text(verbatim: openedStation)
                    .font(.system(size: 1))
                    .accessibilityIdentifier("tent.openedStation")
                    .accessibilityLabel(openedStation)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1).allowsHitTesting(false) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture.tentContainer")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// The same fixture rows as `StationListView`, with no live inbox and no playback.
/// Local selection only: this capture does not read the split's stored station ID, so it
/// cannot restore a player.
private struct StationListCapture: View {
    /// Nothing is selected, so compact width stays on the list.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List(Station.defaultStations) { station in
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name).font(.headline)
                    Text(station.description ?? "")
                        .font(.subheadline)
                        .foregroundStyle(AeroDJPalette.secondaryText)
                }
            }
            .navigationTitle(AppName.display)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("split.sidebar")
        } detail: {
            Text("Choose a station")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("split.placeholder")
        }
    }
}

/// The production split, with the one test-station studio and counting actions.
/// Selecting or restoring a station does not search or play. Access follows the binder's
/// non-prompting `refreshAuthorizationStatus()` (capture defaults to `.notDetermined`).
private struct CaptureStationSplit: View {
    let dependencies: AppDependencies
    /// #454 (`stationTap`): wire the split's tap route and the Duo dial. Off for `shell`, unchanged.
    var routesTaps = false
    /// The last station a tap would start (`capture.startedStation`), "" before any tap.
    @State private var startedStation = ""
    @ObservedObject private var music = MusicKitService.shared
    @ObservedObject private var calls = PlaybackCallLog.shared
    @State private var showSharedInbox = false

    private var access: PlaybackAccess {
        // Match live PlayerView: `.unknown` → Connecting; `.notDetermined` → Allow.
        // Shell settles refresh before `loaded`, so the first painted frame is not stuck
        // on `.unknown` / capture.loading.
        switch music.authState {
        case .unknown: .checking
        case .notDetermined: .needsAuthorization
        case .authorized: .authorized
        case .denied: .denied
        case .notSubscribed: .subscriptionRequired
        }
    }

    /// Capture actions count search/play; Allow still reaches the real `authorize()` so a
    /// tap would bump the authorize badge (restore-without-tap must stay at 0).
    private var actions: PlaybackActions {
        PlaybackActions(
            pause: {},
            resume: { PlaybackCallLog.shared.recordPlay() },
            skip: {},
            dismissError: { music.dismissError() },
            authorize: { await music.authorize() },
            editUpNext: nil
        )
    }

    private var snapshot: PlaybackSnapshot {
        guard access == .authorized else { return music.snapshot }
        guard routesTaps else { return PlaybackFixtures.playing }
        // `stationTap`: the fixture plays from the real Morning Calm id, so its dial stop is the
        // playing one and a tap on it must start nothing (`StationTapRoute.dialPlayingID`).
        var playing = PlaybackFixtures.playing
        playing.station = StationRef(id: Station.morningCalmID.uuidString, name: "Morning Calm")
        return playing
    }

    /// #454: what `StationListView.openStation` does first on a tap, minus the queue: Now Playing
    /// shows "Starting <name>…" for the selected station. Records the id; never plays or searches.
    private func started(_ id: Station.ID) {
        startedStation = id.uuidString
        let name = Station.defaultStations.first { $0.id == id }?.name ?? "station"
        dependencies.studio.stationStart.begin(stationID: id.uuidString, stationName: name,
                                               songAtTap: snapshot.nowPlaying?.id)
    }

    private static var stops: [DuoStationSwitch.Stop] {
        Station.defaultStations.map { DuoStationSwitch.Stop(id: $0.id.uuidString, name: $0.name) }
    }

    /// The split's start action, `stationTap` only. Nil keeps `shell` as it was.
    private var startRoute: ((Station.ID) async -> Void)? {
        guard routesTaps else { return nil }
        return { id in started(id) }
    }

    /// The Duo dial's open action, `stationTap` only: the split's own tap route, like the live app.
    private func dialRoute(_ openFromDetail: @escaping (Station.ID) -> Void) -> ((String) async -> Void)? {
        guard routesTaps else { return nil }
        return { stopID in
            guard let id = StationTapRoute.stationID(forStop: stopID, in: Station.defaultStations.map(\.id)) else { return }
            openFromDetail(id)
        }
    }

    var body: some View {
        // Same once-only binder as the live split. Refresh is non-prompting; request()
        // waits for Allow or an explicit station open.
        StationSplitRoot(stations: Station.defaultStations, showsSharedInbox: true,
                         showSharedInbox: $showSharedInbox,
                         onUserOpenedStation: startRoute,
                         stationDetail: { station, openFromDetail in
            PlayingScreen(station: StationRef(id: station.id.uuidString, name: station.name),
                          access: access,
                          snapshot: snapshot,
                          actions: actions, search: .counting,
                          studio: dependencies.studio, isTestStation: true,
                          timeSource: access == .authorized ? .fixture : nil,
                          stationStops: routesTaps ? Self.stops : [],
                          onOpenStation: dialRoute(openFromDetail))
        })
        .overlay(alignment: .bottomTrailing) {
            if routesTaps {
                Text(verbatim: startedStation)
                    .font(.caption2)
                    .padding(6)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("capture.startedStation")
                    .accessibilityLabel(startedStation)
            }
        }
        .task(id: "playback-session") { await PlaybackSessionBinder.bind(dependencies) }
        .sheet(isPresented: $showSharedInbox) {
            SharedInboxSheet(isPresented: $showSharedInbox) {
                SharedInboxReviewView(review: SharedInboxReview(
                    reader: SharedInboxReader(directory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("AeroDJCaptureInbox", isDirectory: true))))
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(verbatim: calls.label)
                    .accessibilityIdentifier("playback.calls")
                Text(verbatim: "\(calls.authorizeCount)")
                    .accessibilityIdentifier("playback.authorize")
            }
            .font(.caption2)
            .padding(6)
            .allowsHitTesting(false)
        }
    }
}

/// Folded phone (390×844, compact) then the unfolded Duo (640×820, regular) around one
/// `PlayingScreen`. The size-class change is the simulator's stand-in for opening the
/// phone. The scroll anchor, station and playback token live in scene storage above
/// the player's placement switch. The load counter increments once, when this capture
/// finishes loading the station, and the unfold button does not touch it.
private struct DuoContinuityCapture: View {
    let studio: StudioPresentationModel
    @ObservedObject var loads: DisplayContinuityLoadCounter
    @State private var unfolded = false
    @SceneStorage("aerodj.player.scrollAnchor") private var storedScrollAnchor = ""
    @SceneStorage("aerodj.continuity.station") private var continuityStation = ""
    @SceneStorage("aerodj.continuity.playback") private var continuityPlayback = ""
    @ObservedObject private var calls = PlaybackCallLog.shared

    private var containerSize: CGSize {
        unfolded ? StudioCapture.duoWideContainerSize : CGSize(width: 390, height: 844)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            Color(white: 0.14).ignoresSafeArea().accessibilityHidden(true)
            NavigationStack {
                PlayingScreen(station: PlaybackFixtures.station, access: .authorized,
                              snapshot: duoSnapshot, actions: .counting, search: .counting,
                              studio: studio, isTestStation: true, timeSource: .fixture,
                              stationStops: [
                                  DuoStationSwitch.Stop(id: PlaybackFixtures.station.id,
                                                        name: PlaybackFixtures.station.name),
                                  DuoStationSwitch.Stop(id: "late-night", name: "Late Night"),
                              ],
                              onOpenStation: { _ in })
            }
            .environment(\.horizontalSizeClass, unfolded ? .regular : .compact)
            .frame(width: containerSize.width, height: containerSize.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1).allowsHitTesting(false) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("continuity.container")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .topTrailing) { chrome }
    }

    /// The fixture song, seekable, so the scrubber is the same control the Duo tests use.
    private var duoSnapshot: PlaybackSnapshot {
        var playing = PlaybackFixtures.playing
        playing.canSeek = true
        return playing
    }

    private var chrome: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    storedScrollAnchor = DisplayContinuity.rowAnchor(4)
                } label: {
                    Text("Row 4")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("continuity.scrollToRow")
                Button {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { unfolded.toggle() }
                } label: {
                    Text(unfolded ? "Fold" : "Unfold")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("continuity.unfold")
            }
            readout("continuity.anchor", storedScrollAnchor.isEmpty ? "none" : storedScrollAnchor)
            readout("continuity.station", continuityStation)
            readout("continuity.playback", continuityPlayback)
            readout("continuity.loads", "\(loads.count)")
            readout("continuity.sizeClass", unfolded ? "regular" : "compact")
            readout("continuity.pose", unfolded ? "unfolded" : "folded")
            Text(verbatim: calls.label)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: Capsule())
                .accessibilityIdentifier("playback.calls")
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    private func readout(_ identifier: String, _ value: String) -> some View {
        Text(value)
            .font(.system(size: 1))
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(value)
            .allowsHitTesting(false)
    }
}

/// Counts real loads for the continuity capture. A size-class change does not call `noteLoad`.
@MainActor
final class DisplayContinuityLoadCounter: ObservableObject {
    @Published private(set) var count = 0

    func noteLoad() {
        count = DisplayContinuity.Session(
            selectedStationID: nil, scrollAnchor: nil, playbackToken: "", loadCount: count
        ).loaded().loadCount
    }
}

/// UI tests pass `-AeroDJResetContinuity YES` so a scroll anchor stored by an earlier
/// test cannot move the next screenshot. The first appear of each view clears; a later
/// appear in the same launch (the unfold) does not.
@MainActor
enum DisplayContinuityLaunch {
    static let resetKey = "AeroDJResetContinuity"
    static let probeKey = "AeroDJContinuityProbe"
    private static var resetViews: Set<String> = []

    static func shouldReset(_ view: String) -> Bool {
        guard UserDefaults.standard.bool(forKey: resetKey) else { return false }
        if resetViews.contains(view) { return false }
        resetViews.insert(view)
        return true
    }
}

/// Narrow (compact) then wide (regular) around one `PlayingScreen`, so `@State` survives.
/// The fold control lives on `ProbeChrome`, not in this column.
private struct LayoutResizeProbe: View {
    @Binding var wide: Bool
    let scenario: StudioCaptureScenario
    let studio: StudioPresentationModel

    private var columnWidth: CGFloat {
        let minimum = StudioLayoutMetrics.studioMinWidth
        return CGFloat(wide ? minimum + 64 : minimum - 64)
    }

    /// Narrow stays 680 pt (the centred column). Wide is shorter than the landscape rail
    /// (`FoldedColumnLayout.landscapeDuoMinHeight`, #542), so the widened probe still opens
    /// the two-zone Studio this probe exists to check. At 780 × 680 it would now be the rail,
    /// whose trailing controls sit past a 390 pt iPhone window in this top-leading frame.
    private var columnHeight: CGFloat {
        CGFloat(wide ? FoldedColumnLayout.landscapeDuoMinHeight - 80 : 680)
    }

    var body: some View {
        PlayingScreen(station: PlaybackFixtures.station, access: scenario.access,
                      snapshot: scenario.snapshot, actions: .counting, search: .counting,
                      studio: studio, isTestStation: true,
                      timeSource: scenario.snapshot.transport == .playing ? .fixture : nil)
            .environment(\.horizontalSizeClass, wide ? .regular : .compact)
            .frame(width: columnWidth, height: columnHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Debug fold control. Top-trailing of the capture root, inside the safe area, 44 pt.
private struct ProbeChrome: View {
    @Binding var wide: Bool
    @ObservedObject private var calls = PlaybackCallLog.shared

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: calls.label)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: Capsule())
                .accessibilityIdentifier("playback.calls")
            Button {
                wide.toggle()
            } label: {
                Text(wide ? "Narrow" : "Widen")
                    .font(.caption.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityIdentifier("probe.widen")
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }
}

extension MusicSearch {
    /// Capture only: the real search UI with no Apple Music behind it. Searching reports
    /// "isn't available" instead of inventing results.
    static let captureOffline = MusicSearch(search: { _ in throw CancellationError() }, play: { _, _ in })
}

/// The playing song's rating and the fixture station scope. UI tests read it; it is not a control.
private struct RatingCaptureReadout: View {
    let controller: SongRatingController
    let songID: String

    var body: some View {
        let rating = SongRatingPresentation.accessibilityLabel(controller.rating(for: songID))
        let scope = controller.fixtureScopeKey ?? ""
        Text(rating)
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("capture.ratingState")
            .accessibilityLabel("\(rating)|\(scope)")
            .allowsHitTesting(false)
    }
}

/// The segment a capture run starts on, read by `PlayingScreen` once.
@MainActor
enum StudioCaptureSegment {
    static var initial: WorkspaceSegment?
}

/// The `onAir`, `duoWideSpeaking`, and `duoWideOnAir` captures' frozen ON AIR timer.
/// `FoldedOnAirPill` shows `frozenElapsed` when it is set; only those scenarios set it, so
/// every other run (and Release, which does not compile this) counts from when the pill appeared.
@MainActor
enum StudioCaptureOnAir {
    /// What `closed-ax5-onair` shows: "0:12". Same width as a live "0:0x".
    static let capturedElapsed: TimeInterval = 12
    static var frozenElapsed: TimeInterval?
}

private enum SplitCaptureScreen: String, CaseIterable, Identifiable {
    case nowPlaying, library, stations, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .library: "Library"
        case .stations: "Stations"
        case .settings: "Settings"
        }
    }
}

/// One split width, then Now Playing, Library, Stations and Settings inside it.
/// The safe area is the sample's leading and trailing insets. The host pads by
/// those, because this container is the window and not already inside a safe area.
private struct SplitViewCapture: View {
    let studio: StudioPresentationModel
    @State private var screen: SplitCaptureScreen = .nowPlaying

    private var sample: SplitViewLayout.Sample? {
        let name = UserDefaults.standard.string(forKey: "AeroDJSplitExample") ?? ""
        return SplitViewLayout.sample(named: name)
    }

    var body: some View {
        if let sample {
            let measure = SplitMeasure(containerWidth: sample.width, containerHeight: sample.height,
                                       leading: sample.leading, trailing: sample.trailing)
            ZStack {
                Color(white: 0.14).ignoresSafeArea().accessibilityHidden(true)
                splitScreen
                    .environment(\.horizontalSizeClass, sample.hasRegularWidth ? .regular : .compact)
                    .environment(\.splitMeasure, measure)
                    .frame(width: CGFloat(sample.width), height: CGFloat(sample.height))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("split.container")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .top) { switcher }
        } else {
            Text("Studio capture failed: unknown split example")
                .accessibilityIdentifier("capture.failed")
        }
    }

    @ViewBuilder
    private var splitScreen: some View {
        switch screen {
        case .nowPlaying:
            SplitBarHost(preferred: .trailing) { insets in
                NavigationStack {
                    nowPlaying
                }
                .environment(\.splitBarEdge, insets?.barEdge)
            }
        case .library:
            SplitLibraryPane()
        case .stations:
            StationSplitRoot(stations: Station.defaultStations, onOpenSettings: {}) { _ in
                Text("Choose a station")
                    .accessibilityIdentifier("split.placeholder")
            }
        case .settings:
            SettingsView(isPresented: .constant(true), isTestStation: true)
        }
    }

    private var nowPlaying: some View {
        var playing = PlaybackFixtures.playing
        playing.canSeek = true
        return PlayingScreen(station: PlaybackFixtures.station, access: .authorized,
                             snapshot: playing, actions: .preview, search: .captureOffline,
                             studio: studio, isTestStation: true, timeSource: .fixture)
    }

    private var switcher: some View {
        HStack(spacing: 8) {
            ForEach(SplitCaptureScreen.allCases) { item in
                Button {
                    screen = item
                } label: {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                // The 44 pt floor has to be on the button. On the iOS 26.5 plain
                // style, a minHeight on the label alone left the control's
                // accessibility frame at the caption height (42 pt).
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("split.show.\(item.rawValue)")
            }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
    }
}

/// The listener's library: the fixture songs, with the bar button on the outer edge.
private struct SplitLibraryPane: View {
    var body: some View {
        SplitBarHost(preferred: .trailing) { insets in
            NavigationStack {
                List {
                    ForEach(Array(PlaybackFixtures.songs.enumerated()), id: \.element.id) { index, song in
                        Button {} label: {
                            Text("\(song.title) · \(song.artistName)")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("library.row.\(index)")
                    }
                }
                // A List keeps a 16 pt row margin and lays that out from its own
                // bounds, ignoring the host's safeAreaInset. On the 340 pt split
                // the row then starts 16 pt in, 12 pt inside the 28 pt leading.
                // This pane is the capture only. The phone lists are not this view.
                .padding(.leading, CGFloat(insets?.padding.leading ?? 0))
                .padding(.trailing, CGFloat(insets?.padding.trailing ?? 0))
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem(placement: SplitToolbar.placement(
                        preferred: .trailing, edge: insets?.barEdge,
                        leading: .topBarLeading, trailing: .topBarTrailing)) {
                        Button("Edit") {}
                            .accessibilityIdentifier("library.edit")
                    }
                }
            }
        }
    }
}
#endif
