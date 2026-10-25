import SwiftUI

/// Player screen. Two connected layouts driven by `horizontalSizeClass`:
/// - compact (Duo closed): immersive artwork, prominent controls, LIVE badge.
/// - regular (Duo unfolded): studio layout — artwork + controls + queue + DJ + briefing.
/// Built against `PlaybackService` (mock now, MusicKit later). No hardcoded dims.
struct PlayerView: View {
    let station: Station
    @StateObject private var service: MockPlaybackService
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(station: Station, service: MockPlaybackService = MockPlaybackService()) {
        self.station = station
        _service = StateObject(wrappedValue: service)
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                studioLayout
            } else {
                compactLayout
            }
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Compact (Duo closed)

    private var compactLayout: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            if let error = service.errorMessage {
                errorView(error)
            } else if service.isLoading {
                loadingView
            } else if let track = service.currentTrack {
                compactNowPlaying(track)
            } else {
                emptyView
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactNowPlaying(_ track: PlayableTrack) -> some View {
        VStack(spacing: 28) {
            liveBadge
            artwork(track, size: 300)
            VStack(spacing: 6) {
                Text(track.title)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(track.artist)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(track.title) by \(track.artist)")

            controls
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Unfolded (Duo studio)

    private var studioLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            // Left: artwork + controls.
            VStack(spacing: 24) {
                if let error = service.errorMessage {
                    errorView(error)
                } else if service.isLoading {
                    loadingView
                } else if let track = service.currentTrack {
                    artwork(track, size: 360)
                    VStack(spacing: 6) {
                        Text(track.title)
                            .font(.system(.title, design: .rounded, weight: .bold))
                        Text(track.artist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    controls
                } else {
                    emptyView
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            // Right: queue + DJ + briefing — the extra space does real work.
            VStack(alignment: .leading, spacing: 24) {
                liveBadge
                if let dj = service.dj {
                    djCard(dj)
                }
                if !service.briefing.isEmpty {
                    briefingCard
                }
                if !service.queue.isEmpty {
                    queueCard
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func djCard(_ dj: DJPresence) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(dj.name).font(.headline)
                Text(dj.mood).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("DJ \(dj.name), \(dj.mood)")
    }

    private var briefingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Morning Briefing", systemImage: "sun.max")
                .font(.headline)
            ForEach(service.briefing) { item in
                Text(item.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Up Next", systemImage: "list.number")
                .font(.headline)
            ForEach(service.queue) { track in
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                    Text(track.title).font(.subheadline)
                    Spacer()
                    Text(track.artist).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Shared pieces

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("LIVE")
                .font(.caption.weight(.semibold))
                .tracking(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel("Live DJ")
    }

    private func artwork(_ track: PlayableTrack, size: CGFloat) -> some View {
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
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
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
            .sensoryFeedback(.impact(weight: .light), trigger: service.currentTrack?.id)

            Button {
                Task { await service.togglePlayPause() }
            } label: {
                Image(systemName: service.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
            }
            .accessibilityLabel(service.isPlaying ? "Pause" : "Play")
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: service.isPlaying)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading station")
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

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Playback unavailable").font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback error: \(message)")
    }
}

#Preview("Compact") {
    PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil))
        .environment(\.horizontalSizeClass, .compact)
}

#Preview("Unfolded") {
    PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil))
        .environment(\.horizontalSizeClass, .regular)
}