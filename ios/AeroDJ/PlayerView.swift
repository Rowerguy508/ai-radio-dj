import SwiftUI
import AeroDJCore

/// Player screen. Two connected layouts driven by `horizontalSizeClass`:
/// - compact (Duo closed): immersive artwork, prominent controls, truthful DJ badge.
/// - regular (Duo unfolded): Studio Mode — persistent Now Playing, editable
///   queue, station tuner, Connections panel (see StudioView).
/// Uses Claude's shared playback state (`PlaybackSnapshot`) from AeroDJCore.
/// Artwork scales with available space; no hardcoded dimensions.
struct PlayerView: View {
    let station: Station
    @ObservedObject private var service: MockPlaybackService
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(station: Station, service: MockPlaybackService = MockPlaybackService()) {
        self.station = station
        _service = ObservedObject(wrappedValue: service)
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                StudioView(station: station, service: service)
            } else {
                compactLayout
            }
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Compact (Duo closed)

    private var compactLayout: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 24) {
                    if let error = service.snapshot.error {
                        errorView(error)
                    } else if let track = service.snapshot.nowPlaying {
                        compactNowPlaying(track, availableHeight: geo.size.height)
                    } else {
                        emptyView
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
    }

    private func compactNowPlaying(_ track: TrackInfo, availableHeight: CGFloat) -> some View {
        VStack(spacing: 24) {
            djBadge
            // Artwork scales with available space, capped by width.
            artwork(track, size: min(availableHeight * 0.5, 320))
            VStack(spacing: 6) {
                Text(track.title)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(track.artistName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(track.title) by \(track.artistName)")

            controls
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared pieces

    /// Truthful DJ status: shown only when the DJ is actually speaking.
    /// `speaking` is set only from real speech-audio callbacks (Claude's model).
    private var djBadge: some View {
        Group {
            if case .speaking(let line) = service.snapshot.dj {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("On air")
                        .font(.caption.weight(.semibold))
                        .tracking(0.5)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityLabel("On air: \(line)")
            }
        }
    }

    private func artwork(_ track: TrackInfo, size: CGFloat) -> some View {
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .accessibilityHidden(true)
    }

    private var placeholderArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo, .purple],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 72))
                .foregroundStyle(.white)
        }
    }

    private var controls: some View {
        HStack(spacing: 48) {
            Button {
                Task { await service.skip() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .accessibilityLabel("Next track")
            .sensoryFeedback(.impact(weight: .light), trigger: service.snapshot.nowPlaying?.id)

            Button {
                Task { await service.togglePlayPause() }
            } label: {
                Image(systemName: service.snapshot.transport == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
            }
            .accessibilityLabel(service.snapshot.transport == .playing ? "Pause" : "Play")
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: service.snapshot.transport)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Nothing playing").font(.headline)
            Text("Pick a track to start the station.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func errorView(_ error: PlaybackError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Playback unavailable").font(.headline)
            Text(error.message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback error: \(error.message)")
    }
}

#Preview("Compact") {
    PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil, djName: "Maya"))
        .environment(\.horizontalSizeClass, .compact)
}

#Preview("Unfolded") {
    PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil, djName: "Maya"))
        .environment(\.horizontalSizeClass, .regular)
}

#Preview("Empty") {
    PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil, djName: "Maya"))
        .environment(\.horizontalSizeClass, .compact)
}

#Preview("Error") {
    PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil, djName: "Maya"))
        .environment(\.horizontalSizeClass, .compact)
}