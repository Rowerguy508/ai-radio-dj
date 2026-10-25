import SwiftUI

/// Player shell. MusicKit playback is managed by the framework; this view
/// reflects state and forwards user actions. No protected-stream mixing.
struct PlayerView: View {
    let station: Station
    @StateObject private var music = MusicKitService.shared
    @State private var searchQuery = ""
    @State private var results: [Track] = []

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
        .task { await music.authorize() }
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
                    music.isPlaying ? music.pause() : Task { try? await music.resume() }
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
    PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil))
}
