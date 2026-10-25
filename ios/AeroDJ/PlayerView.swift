import SwiftUI

/// Player screen. Built against `PlaybackService` (mock now, MusicKit later).
/// Handles loading / empty / error states, album artwork, and accessibility.
struct PlayerView: View {
    let station: Station
    @StateObject private var service: MockPlaybackService

    init(station: Station, service: MockPlaybackService = MockPlaybackService()) {
        self.station = station
        _service = StateObject(wrappedValue: service)
    }

    var body: some View {
        VStack(spacing: 24) {
            Text(station.name)
                .font(.title2)
                .accessibilityAddTraits(.isHeader)

            if let error = service.errorMessage {
                errorView(error)
            } else if service.isLoading {
                loadingView
            } else if let track = service.currentTrack {
                nowPlayingView(track)
            } else {
                emptyView
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading station")
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.headline)
            Text("Pick a track to start the station.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Playback unavailable")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback error: \(message)")
    }

    // MARK: - Now playing

    private func nowPlayingView(_ track: PlayableTrack) -> some View {
        VStack(spacing: 20) {
            artwork(track)
            VStack(spacing: 4) {
                Text(track.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(track.title) by \(track.artist)")

            controls
        }
    }

    private func artwork(_ track: PlayableTrack) -> some View {
        Group {
            if let url = track.artworkURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        placeholderArtwork
                    case .empty:
                        ProgressView()
                    @unknown default:
                        placeholderArtwork
                    }
                }
            } else {
                placeholderArtwork
            }
        }
        .frame(width: 200, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 8)
        .accessibilityHidden(true)
    }

    private var placeholderArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo, .purple],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 56))
                .foregroundStyle(.white)
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                Task { await service.skip() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .accessibilityLabel("Next track")

            Button {
                Task { await service.togglePlayPause() }
            } label: {
                Image(systemName: service.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .accessibilityLabel(service.isPlaying ? "Pause" : "Play")
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil))
}