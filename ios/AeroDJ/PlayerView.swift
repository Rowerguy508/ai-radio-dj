import SwiftUI
import AeroDJCore

/// Player shell. MusicKit playback is managed by the framework; this view
/// reflects state and forwards user actions. No protected-stream mixing.
struct PlayerView: View {
    let station: Station
    @StateObject private var music: MusicKitService
    @StateObject private var interlude: InterludePlaybackAdapter
    let djSession: DJBreakSession
    @State private var searchQuery = ""
    @State private var results: [Track] = []

    /// `music` is the app-scoped session from `AppDependencies`. Never a new player.
    init(station: Station, music: MusicKitService, djSession: DJBreakSession) {
        self.station = station
        self.djSession = djSession
        _music = StateObject(wrappedValue: music)
        _interlude = StateObject(wrappedValue: InterludePlaybackAdapter(music: music))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(station.name).font(.title2)

            if let err = music.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }

            switch music.authState {
            case .unknown:
                ProgressView("Checking Apple Music…")
            case .denied:
                Text("Apple Music access denied. Enable it in Settings.")
                    .foregroundStyle(.red)
            case .notSubscribed:
                Text("An Apple Music subscription is required.")
                    .foregroundStyle(.orange)
            case .authorized:
                nowPlayingSection
                searchSection
            }
        }
        .padding()
        .task {
            music.onBoundary = { @MainActor [interlude, music, djSession] boundary, finishedIndex in
                guard case .naturalEnd = boundary else { return }
                // A break is only ever played at a natural end. Anything late, missing or failed is
                // skipped, and the next song is not delayed.
                Task { @MainActor in
                    guard !interlude.isSpeaking,
                          let prepared = await djSession.naturalBoundary(afterTrack: finishedIndex) else {
                        music.skipInterlude()
                        return
                    }
                    let line = prepared.cues.map(\.text).joined(separator: " ")
                    guard !line.isEmpty else {
                        music.skipInterlude()
                        return
                    }
                    await interlude.play(clips: prepared.clips.map(\.audio.data), line: line, afterTrack: finishedIndex)
                }
            }
            music.onBreakMustStop = { [interlude] in interlude.stop() }
            // Only real audio events reach the DJ session; nothing is synthesized from the plan.
            interlude.onPlayback = { [djSession] event in
                switch event {
                case .started(let k): djSession.playbackStarted(afterTrack: k)
                case .finished(let k): djSession.playbackFinished(afterTrack: k)
                case .failed(let k): djSession.playbackFailed(afterTrack: k)
                }
            }
            await music.authorize()
        }
    }

    private var nowPlayingSection: some View {
        VStack(spacing: 12) {
            if let track = music.currentTrack {
                AsyncImage(url: track.artworkURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(track.title).font(.headline)
                Text(track.artistName).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Nothing playing").foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                Button { Task { try? await music.skip() } } label: {
                    Image(systemName: "forward.fill").font(.title2)
                }
                Button {
                    if music.isPlaying {
                        music.pause()
                    } else {
                        Task { try? await music.resume() }
                    }
                } label: {
                    Image(systemName: music.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }
            }
        }
    }

    private var searchSection: some View {
        VStack(spacing: 8) {
            TextField("Search Apple Music", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { results = (try? await music.search(searchQuery)) ?? [] } }

            List(results) { track in
                Button {
                    Task { try? await music.play([track]) }
                } label: {
                    HStack {
                        Text(track.title)
                        Spacer()
                        Text(track.artistName).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 200)
        }
    }
}

#Preview {
    PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil),
               music: MusicKitService.shared,
               djSession: DJBreakSession(preparer: DJBreakPreparer(renderer: VoiceRenderer.onDeviceDefault(),
                                                                   userID: "preview", stationID: "preview"),
                                         station: StationConfigurationModel(store: InMemoryStationConfigurationStore(),
                                                                            consent: StaticIntegrationConsent([:])),
                                         dj: DJPresentationStore()))
}
