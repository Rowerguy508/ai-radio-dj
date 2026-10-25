import SwiftUI
import AeroDJCore

/// Duo Studio Mode — the unfolded radio control room. Persistent Now Playing
/// on top, then an editable Up Next queue, a station tuner, and a Connections
/// panel. Music never restarts on layout change (the service is app-scoped).
/// Uses Claude's shared playback state (`PlaybackSnapshot`). No hardcoded dims.
struct StudioView: View {
    let station: Station
    @ObservedObject private var service: MockPlaybackService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(station: Station, service: MockPlaybackService = MockPlaybackService()) {
        self.station = station
        _service = ObservedObject(wrappedValue: service)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                nowPlayingSection
                tunerSection
                queueSection
                connectionsSection
            }
            .padding(24)
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Persistent Now Playing

    private var nowPlayingSection: some View {
        HStack(alignment: .center, spacing: 20) {
            if let track = service.snapshot.nowPlaying {
                artwork(track)
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .lineLimit(2)
                    Text(track.artistName)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    djBadge
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(track.title) by \(track.artistName)")
                Spacer()
                controls
            } else {
                Text("Nothing playing")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Station tuner

    private var tunerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Tuner", icon: "dial.medium")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(service.stations) { station in
                        Button {
                            Task { await service.tune(to: station) }
                        } label: {
                            TunerCard(station: station)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Editable Up Next queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Up Next", icon: "list.number")
            if service.snapshot.upNext.isEmpty {
                Text("Queue is empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(service.snapshot.upNext) { track in
                        HStack(spacing: 10) {
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.subheadline)
                                Text(track.artistName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { service.moveInQueue(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        for i in offsets {
                            let track = service.snapshot.upNext[i]
                            service.removeFromQueue(track)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 120)
                .scrollDisabled(true)
            }
        }
    }

    // MARK: - Connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Connections", icon: "link")
            ForEach(service.connections) { connection in
                HStack(spacing: 12) {
                    Image(systemName: connection.icon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    Text(connection.name).font(.subheadline)
                    Spacer()
                    if connection.isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("Off")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Shared pieces

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    private var djBadge: some View {
        Group {
            if case .speaking(let line) = service.snapshot.dj {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("On air").font(.caption.weight(.semibold)).tracking(0.5)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityLabel("On air: \(line)")
            }
        }
    }

    private func artwork(_ track: TrackInfo) -> some View {
        Group {
            if let url = track.artworkURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: placeholderArtwork
                    case .empty: ProgressView()
                    @unknown default: placeholderArtwork
                    }
                }
            } else {
                placeholderArtwork
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .accessibilityHidden(true)
    }

    private var placeholderArtwork: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.system(size: 40)).foregroundStyle(.white)
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            Button {
                Task { await service.skip() }
            } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
            .accessibilityLabel("Next track")
            .sensoryFeedback(.impact(weight: .light), trigger: service.snapshot.nowPlaying?.id)

            Button {
                Task { await service.togglePlayPause() }
            } label: {
                Image(systemName: service.snapshot.transport == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            .accessibilityLabel(service.snapshot.transport == .playing ? "Pause" : "Play")
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: service.snapshot.transport)
        }
    }
}

/// A tuner card — station identity + mood/energy, tactile.
struct TunerCard: View {
    let station: StationConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(station.name)
                .font(.headline)
                .lineLimit(1)
            Text(station.mood)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    Circle()
                        .fill(i < station.energy ? Color.accentColor : Color(.systemGray4))
                        .frame(width: 4, height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(12)
        .frame(width: 140, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(station.name), \(station.mood), energy \(station.energy) of 10")
    }
}

#Preview("Studio") {
    NavigationStack {
        StudioView(station: Station(id: UUID(), name: "Morning Calm", description: nil, djName: "Maya"))
    }
}