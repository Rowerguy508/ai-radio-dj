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
    /// `djSpeaking`: the ON AIR pill's timer is pinned here instead of counting from the
    /// moment the pill appeared, so every capture and video take reads 0:04.
    static let onAirElapsed: TimeInterval = 4

    /// `breakToSongHandoff`: the break after song one has finished (`playbackFinished`) and
    /// song two is playing with song three queued. The same songs as `PlaybackFixtures`.
    static let handoffSnapshot = PlaybackSnapshot(
        station: PlaybackFixtures.station,
        nowPlaying: PlaybackFixtures.songs[1],
        upNext: [PlaybackFixtures.songs[2]],
        transport: .playing,
        dj: .idle
    )

    /// `stationListCustom`: one created (+) station after the built-ins. A genre recipe with a
    /// fixed id and date, read through `CreatedStations` like the live list, and never written
    /// to the recipe store.
    static let createdStationRecipe = StationRecipe(
        id: UUID(uuidString: "B06E5F54-8293-4EAF-8031-4C5D6E7F8091")!,
        name: "Night Bus Electronic",
        configuration: StationConfiguration(seeds: [StationSeed(kind: .genre, catalogID: "7", name: "Electronic")]),
        createdAt: Date(timeIntervalSince1970: 1_790_000_000)
    )

    /// `genreBuilder`: the genre already picked on the add-station pick step. One of
    /// `StaticGenreProvider.fixture`'s rows, so its row shows the checkmark.
    static let pickedGenre = StationSeed(kind: .genre, catalogID: "7", name: "Electronic")

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
    /// The listen player with a break ready (`breakReady`) in a 640 × 820 pt compact-class
    /// container: below the Studio switch but wider than any phone in portrait, like the
    /// unfolded Duo's split-view detail (owner, build 25). Needs a window at least that big.
    case duoWideReady
    /// App Store video (build 27). The DJ is on air between songs one and two
    /// (`PlaybackFixtures.djSpeaking`), reached through `breakReady` then `playbackStarted`, the
    /// same events the audio player sends. The ON AIR timer is pinned (`onAirElapsed`).
    case djSpeaking
    /// App Store video (build 27). The moment after that break: `playbackFinished` has ended
    /// On Air and song two is playing from 0:03 (`handoffSnapshot`).
    case breakToSongHandoff
    /// App Store video (build 27). The add-station walkthrough's genre pick step, listing
    /// `StaticGenreProvider.fixture` (no MusicKit, no authorization) with one genre picked.
    /// Nothing is saved: the capture never taps Next.
    case genreBuilder
    /// App Store video (build 27). The station picker with the built-ins plus one created
    /// station (`createdStationRecipe`): the carousel at compact width, the list at regular.
    /// Local selection only; nothing restores, searches or plays.
    case stationListCustom

    var access: PlaybackAccess {
        switch self {
        case .loading: .checking
        case .denied: .denied
        case .stations, .resize, .resizeTune, .shell, .genreBuilder, .stationListCustom: .authorized
        default: .authorized
        }
    }

    var snapshot: PlaybackSnapshot {
        switch self {
        case .empty, .loading, .denied, .stations, .resize, .genreBuilder, .stationListCustom: PlaybackFixtures.stopped
        case .error: PlaybackFixtures.recoverableError
        case .djSpeaking: PlaybackFixtures.djSpeaking
        case .breakToSongHandoff: StudioCapture.handoffSnapshot
        default: PlaybackFixtures.playing
        }
    }

    /// The workspace segment the scenario is about, if any.
    var segment: WorkspaceSegment? {
        switch self {
        case .revoked: .connections
        case .config, .resizeTune: .tune
        case .resize: .queue
        case .stations, .shell: nil
        default: nil
        }
    }

    /// Fixed progress for a playing scenario, nil when nothing plays. Song two has only just
    /// started in the break scenarios; every other playing scenario keeps 1:12 of 3:45.
    var timeSource: PlaybackTimeSource? {
        switch self {
        case .djSpeaking: return .songStart(elapsed: 0)
        case .breakToSongHandoff: return .songStart(elapsed: 3)
        default: return snapshot.transport == .playing ? PlaybackTimeSource.fixture : nil
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
            } else if scenario == .stations {
                // The split is the root. An outer NavigationStack makes compact width
                // open the detail column, so the fixture list never appears.
                StationListCapture()
            } else if scenario == .shell {
                // Auth is settled in `.task` before `loaded` so the shell never paints
                // `.checking` / Connecting in place of Allow.
                CaptureStationSplit(dependencies: dependencies)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("capture.shell")
            } else if scenario == .duoWideReady {
                DuoWideCaptureContainer(scenario: scenario, studio: dependencies.studio)
            } else if scenario == .genreBuilder {
                GenreBuilderCapture(studio: dependencies.studio)
            } else if scenario == .stationListCustom {
                CreatedStationListCapture()
            } else {
                NavigationStack {
                    if showsProbe {
                        LayoutResizeProbe(wide: $probeWide, scenario: scenario, studio: dependencies.studio)
                    } else {
                        PlayingScreen(station: PlaybackFixtures.station, access: scenario.access,
                                      snapshot: scenario.snapshot, actions: .preview,
                                      search: scenario == .empty ? .counting : .captureOffline,
                                      studio: dependencies.studio, isTestStation: true,
                                      timeSource: scenario.timeSource)
                    }
                }
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
        .environment(\.studioCaptureOnAirElapsed, loaded && scenario == .djSpeaking ? StudioCapture.onAirElapsed : nil)
        .task {
            // The app root's task starts Studio (b39d15f). Wait for that load to finish rather
            // than loading again: a second load would overwrite the scenario's edits below.
            let studio = dependencies.studio
            let defaults = UserDefaults.standard
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
            switch scenario {
            case .revoked:
                await studio.connections.refresh()
                await studio.connections.perform(.revoke, onSource: .calendar)
            case .playbackFailed:
                studio.dj.send(.playbackFailed(afterTrack: 0))
            case .breakReady, .duoWideReady:
                studio.dj.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 30))
            case .djSpeaking:
                // Speaking only ever comes from playbackStarted (DJPresentationModel).
                studio.dj.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 8))
                studio.dj.send(.playbackStarted(afterTrack: 0))
            case .breakToSongHandoff:
                studio.dj.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 8))
                studio.dj.send(.playbackStarted(afterTrack: 0))
                studio.dj.send(.playbackFinished(afterTrack: 0))
            case .config, .resizeTune:
                // Fry #110: Save while holding schedules pending until a safe boundary.
                // Idle Save would apply immediately ("Saved…"), which breaks
                // testStationConfigChangeIsPendingNotActive / testPendingTuneSurvivesFold.
                await studio.station.setPlaybackActivity(.holdingSong)
                await studio.station.setEnergy(0.85)
                await studio.station.setGenres(["pop", "indie", "synthwave"])
                await studio.station.saveChanges()
            default:
                break
            }
            if let segment = defaults.string(forKey: StudioCapture.segmentKey).flatMap(WorkspaceSegment.init) ?? scenario.segment {
                StudioCaptureSegment.initial = segment
            }
            // Shell observes authState. Settle the non-prompting status before flipping
            // `loaded`, so CaptureStationSplit's first frame is Allow / denied / ready —
            // never the bare Connecting spinner, and never blocked on MusicKit request().
            if chosen == .shell {
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

    var body: some View {
        let size = StudioCapture.duoWideContainerSize
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            Color(white: 0.14)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            NavigationStack {
                PlayingScreen(station: PlaybackFixtures.station, access: scenario.access,
                              snapshot: scenario.snapshot, actions: .preview,
                              search: .captureOffline,
                              studio: studio, isTestStation: true,
                              timeSource: .fixture)
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
            .navigationTitle("AeroDJ")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("split.sidebar")
        } detail: {
            Text("Choose a station")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("split.placeholder")
        }
    }
}

/// `genreBuilder`: the real add-station walkthrough on its pick step for a genre station, over
/// `StaticGenreProvider.fixture`. Its seed search is offline (`CaptureOfflineSeedSearch`), so no
/// step can reach Apple Music, and Cancel / Done do nothing. The model is built once, before the
/// first frame, with `pickedGenre` already picked.
private struct GenreBuilderCapture: View {
    let studio: StudioPresentationModel
    @State private var creation: StationCreationModel?

    var body: some View {
        Group {
            if let creation {
                AddStationWalkthroughView(studio: studio, creation: creation,
                                          initialStep: .picks, initialKind: .genre) {}
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("capture.genreBuilder")
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard creation == nil else { return }
            let model = StationCreationModel(studio: studio, search: CaptureOfflineSeedSearch(), kind: .genre,
                                             genres: StaticGenreProvider.fixture)
            model.toggle(StudioCapture.pickedGenre)
            creation = model
        }
    }
}

/// Capture only: catalog and library search that never leaves the device. Genres come from
/// the walkthrough's `GenreProviding` (`StaticGenreProvider.fixture`), not from here.
private struct CaptureOfflineSeedSearch: StationSeedSearching {
    func searchSeeds(_ term: String, kinds: Set<StationSeedKind>, limit: Int) async throws -> [StationSeedSearchResult] {
        throw CancellationError()
    }

    func genreSeeds(matching query: String) async throws -> [StationSeedSearchResult] { [] }

    func libraryPlaylistSeeds(limit: Int) async throws -> [StationSeedSearchResult] { [] }
}

/// `stationListCustom`: the built-ins plus `createdStationRecipe`, drawn like the live picker
/// (`StationSplitRoot.stationPicker`): the arc carousel at compact width, the sidebar list at
/// regular, under the same morphing "Stations" header. Like `StationListCapture` the selection
/// is local and never stored or restored, and a tap does nothing, so nothing can play.
private struct CreatedStationListCapture: View {
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var systemColorScheme

    private var stations: [Station] {
        Station.defaultStations
            + CreatedStations.entries(from: [StudioCapture.createdStationRecipe]).map(Station.init(created:))
    }

    private var isCompact: Bool { horizontalSizeClass != .regular }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            picker
                .navigationTitle("AeroDJ")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("split.sidebar")
                .morphingLargeTitle("Stations", subtitle: "Your AI-hosted radio, on Apple Music")
                .environment(\.colorScheme, isCompact ? .dark : systemColorScheme)
                .toolbarColorScheme(isCompact ? .dark : nil, for: .navigationBar)
        } detail: {
            Text("Choose a station")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("split.placeholder")
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var picker: some View {
        if isCompact {
            StationCarousel(stations: stations, selectedID: nil) { _ in }
        } else {
            List(stations) { station in
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name).font(.headline).lineLimit(1)
                    if let description = station.description {
                        Text(description).font(.subheadline).foregroundStyle(AeroDJPalette.secondaryText)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stations.row.\(station.id.uuidString)")
            }
        }
    }
}

/// The production split, with the one test-station studio and counting actions.
/// Selecting or restoring a station does not search or play. Access follows the binder's
/// non-prompting `refreshAuthorizationStatus()` (capture defaults to `.notDetermined`).
private struct CaptureStationSplit: View {
    let dependencies: AppDependencies
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

    var body: some View {
        // Same once-only binder as the live split. Refresh is non-prompting; request()
        // waits for Allow or an explicit station open.
        StationSplitRoot(stations: Station.defaultStations, showsSharedInbox: true,
                         showSharedInbox: $showSharedInbox) { station in
            PlayingScreen(station: StationRef(id: station.id.uuidString, name: station.name),
                          access: access,
                          snapshot: access == .authorized ? PlaybackFixtures.playing : music.snapshot,
                          actions: actions, search: .counting,
                          studio: dependencies.studio, isTestStation: true,
                          timeSource: access == .authorized ? .fixture : nil)
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

    var body: some View {
        PlayingScreen(station: PlaybackFixtures.station, access: scenario.access,
                      snapshot: scenario.snapshot, actions: .counting, search: .counting,
                      studio: studio, isTestStation: true,
                      timeSource: scenario.snapshot.transport == .playing ? .fixture : nil)
            .environment(\.horizontalSizeClass, wide ? .regular : .compact)
            .frame(width: columnWidth, height: 680, alignment: .topLeading)
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

extension PlaybackTimeSource {
    /// Capture only: a song that has just started, `elapsed` seconds into 3:18. Fixed, so the
    /// scrubber never moves between frames.
    static func songStart(elapsed: TimeInterval) -> PlaybackTimeSource {
        PlaybackTimeSource(elapsed: { elapsed }, duration: { 198 }, isPlaying: { true })
    }
}

private struct StudioCaptureOnAirElapsedKey: EnvironmentKey {
    static let defaultValue: TimeInterval? = nil
}

extension EnvironmentValues {
    /// Debug capture only: a fixed ON AIR timer (`StudioCapture.onAirElapsed`). Nil, the
    /// default everywhere else, keeps the live timer.
    var studioCaptureOnAirElapsed: TimeInterval? {
        get { self[StudioCaptureOnAirElapsedKey.self] }
        set { self[StudioCaptureOnAirElapsedKey.self] = newValue }
    }
}

/// The segment a capture run starts on, read by `PlayingScreen` once.
@MainActor
enum StudioCaptureSegment {
    static var initial: WorkspaceSegment?
}
#endif
