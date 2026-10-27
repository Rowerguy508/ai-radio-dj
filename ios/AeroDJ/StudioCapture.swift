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

    var access: PlaybackAccess {
        switch self {
        case .loading: .checking
        case .denied: .denied
        case .stations: .authorized
        default: .authorized
        }
    }

    var snapshot: PlaybackSnapshot {
        switch self {
        case .empty, .loading, .denied, .stations: PlaybackFixtures.stopped
        case .error: PlaybackFixtures.recoverableError
        default: PlaybackFixtures.playing
        }
    }

    /// The workspace segment the scenario is about, if any.
    var segment: WorkspaceSegment? {
        switch self {
        case .revoked: .connections
        case .config: .tune
        case .stations: nil
        default: nil
        }
    }
}

struct StudioCaptureView: View {
    let dependencies: AppDependencies
    @State private var loaded = false
    @State private var scenario: StudioCaptureScenario = .playing
    /// Set when the station never finished loading. The capture refuses to render a screenshot
    /// that depends on timing; UI tests fail on `capture.failed` (StudioScreenTests.launch).
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    Text(failure)
                        .accessibilityIdentifier("capture.failed")
                } else if loaded && scenario == .stations {
                    StationListCapture()
                } else if loaded {
                    PlayingScreen(station: PlaybackFixtures.station, access: scenario.access,
                                  snapshot: scenario.snapshot, actions: .preview,
                                  search: scenario == .empty ? .captureOffline : nil,
                                  studio: dependencies.studio, isTestStation: true)
                } else {
                    ProgressView()
                        .accessibilityIdentifier("capture.loading")
                }
            }
        }
        .preferredColorScheme(UserDefaults.standard.bool(forKey: StudioCapture.darkKey) ? .dark : nil)
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
            case .breakReady:
                studio.dj.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 30))
            case .config:
                await studio.station.setEnergy(0.85)
                await studio.station.setGenres(["pop", "indie", "synthwave"])
            default:
                break
            }
            if let segment = defaults.string(forKey: StudioCapture.segmentKey).flatMap(WorkspaceSegment.init) ?? scenario.segment {
                StudioCaptureSegment.initial = segment
            }
            loaded = true
        }
    }
}

/// The same fixture rows as `StationListView`, with no live inbox and no playback.
private struct StationListCapture: View {
    var body: some View {
        List(Station.defaultStations) { station in
            NavigationLink {
                EmptyView()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name).font(.headline)
                    Text(station.description ?? "")
                        .font(.subheadline)
                        .foregroundStyle(AeroDJPalette.secondaryText)
                }
            }
        }
        .navigationTitle("AeroDJ")
    }
}

extension MusicSearch {
    /// Capture only: the real search UI with no Apple Music behind it. Searching reports
    /// "isn't available" instead of inventing results.
    static let captureOffline = MusicSearch(search: { _ in throw CancellationError() }, play: { _, _ in })
}

/// The segment a capture run starts on, read by `PlayingScreen` once.
@MainActor
enum StudioCaptureSegment {
    static var initial: WorkspaceSegment?
}
#endif
