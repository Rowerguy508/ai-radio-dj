import SwiftUI
import AeroDJCore

/// Player shell. MusicKit playback is managed by the framework; this view
/// reflects state and forwards user actions. No protected-stream mixing.
///
/// The UI is `PlayingScreen` (compact on the closed Duo, two-zone Studio when open). It
/// binds to the app-scoped session's `snapshot`, `studio` (tuner, Connections, DJ state)
/// and real actions. Audio wiring stays in `.task` below and belongs to the player owner.
struct PlayerView: View {
    let station: Station
    let dependencies: AppDependencies
    @StateObject private var music: MusicKitService
    @StateObject private var interlude: InterludePlaybackAdapter

    /// `music` is the app-scoped session from `AppDependencies`. Never a new player.
    init(station: Station, dependencies: AppDependencies) {
        self.station = station
        self.dependencies = dependencies
        _music = StateObject(wrappedValue: dependencies.playback)
        _interlude = StateObject(wrappedValue: InterludePlaybackAdapter(music: dependencies.playback))
    }

    var body: some View {
        PlayingScreen(station: stationRef,
                      access: access,
                      snapshot: music.snapshot,
                      actions: .live(music),
                      search: .live(music, station: stationRef),
                      studio: dependencies.studio,
                      isTestStation: dependencies.mode == .testStation)
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            music.onBoundary = { @MainActor [music] boundary, _ in
                guard case .naturalEnd = boundary else { return }
                // No prepared break is wired to the player yet (DJBreakSession lands with
                // #58), so every natural end resolves the transition with no speech.
                music.skipInterlude()
            }
            music.onBreakMustStop = { [interlude] in interlude.stop() }
            await music.authorize()
        }
    }

    private var stationRef: StationRef { StationRef(id: station.id.uuidString, name: station.name) }

    private var access: PlaybackAccess {
        switch music.authState {
        case .unknown: .checking
        case .authorized: .authorized
        case .denied: .denied
        case .notSubscribed: .subscriptionRequired
        }
    }
}

#Preview {
    NavigationStack {
        PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil),
                   dependencies: AppDependencies.make())
    }
}
