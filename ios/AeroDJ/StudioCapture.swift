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

    static func isRequested(mode: AppRuntimeMode, defaults: UserDefaults = .standard) -> Bool {
        mode == .testStation && defaults.bool(forKey: defaultsKey)
    }
}

struct StudioCaptureView: View {
    let dependencies: AppDependencies
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if loaded {
                    PlayingScreen(station: PlaybackFixtures.station, access: .authorized,
                                  snapshot: PlaybackFixtures.playing, actions: .preview, search: nil,
                                  studio: dependencies.studio, isTestStation: true)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(PlaybackFixtures.station.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task {
            // The launch path does not start Studio yet; load it here so the tuner and
            // Connections show the test station's real state instead of "Loading".
            if dependencies.studio.station.loadState == .notLoaded { await dependencies.studio.start() }
            if let raw = UserDefaults.standard.string(forKey: StudioCapture.segmentKey),
               let segment = WorkspaceSegment(rawValue: raw) {
                StudioCaptureSegment.initial = segment
            }
            loaded = true
        }
    }
}

/// The segment a capture run starts on, read by `PlayingScreen` once.
@MainActor
enum StudioCaptureSegment {
    static var initial: WorkspaceSegment?
}
#endif
