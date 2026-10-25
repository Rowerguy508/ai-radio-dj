import SwiftUI
import AeroDJCore

/// Duo Studio Mode — the unfolded radio control room. A true two-zone
/// workspace: Now Playing + controls on one side, queue/tuner/connections on
/// the other. Uses `ViewThatFits` so it lays out side-by-side when the space
/// allows and stacks on narrow canvases. Queue edits go through Claude's
/// `UpNextEdit`. Music never restarts on layout change (app-scoped service).
struct StudioView: View {
    let station: Station
    @ObservedObject private var service: MockPlaybackService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(station: Station, service: MockPlaybackService = MockPlaybackService()) {
        self.station = station
        _service = ObservedObject(wrappedValue: service)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                // Two-zone workspace when there's real width; stacked otherwise.
                // Content-responsive (actual available width), not hardcoded dims.
                if geo.size.width >= 680 {
                    twoZoneLayout
                } else {
                    stackedLayout
                }
                .padding(20)
            }
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Layouts

    /// Side-by-side: Now Playing left, control panels right.
    private var twoZoneLayout: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                  spacing: 24) {
            nowPlayingSection
                .gridCellColumns(2)
            stationTunerSection
            rightPanels
        }
    }

    /// Narrow fallback: everything stacked with clear grouping.
    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 24) {
            nowPlayingSection
            stationTunerSection
            queueSection
            connectionsSection
        }
    }

    @ViewBuilder
    private var rightPanels: some View {
        VStack(alignment: .leading, spacing: 24) {
            queueSection
            connectionsSection
        }
    }

    // MARK: - Now Playing

    private var nowPlayingSection: some View {
        HStack(alignment: .center, spacing: 16) {
            if let track = service.snapshot.nowPlaying {
                artwork(track)
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(1)
                    Text(track.title)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .lineLimit(2)
                    Text(track.artistName)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    djBadge
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(station.name), \(track.title) by \(track.artistName)")
                Spacer(minLength: 0)
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

    // MARK: - Queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Up Next", icon: "list.number")
            if service.snapshot.upNext.isEmpty {
                Text("Queue is empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(service.snapshot.upNext.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.subheadline)
                            Text(track.artistName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Removal routes through Claude's UpNextEdit.
                        Button {
                            _ = service.applyQueueEdit(.remove(id: track.id))
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Remove \(track.title) from queue")
                        .buttonStyle(.plain)
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Station tuner (label mock pending Fry's contract)

    private var stationTunerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent {
                Text("Mock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } label: {
                sectionHeader("Tuner", icon: "dial.medium")
            }
            HStack(spacing: 10) {
                ForEach(service.stations) { station in
                    TunerCard(station: station)
                }
            }
        }
    }

    // MARK: - Connections (honest states pending Fry's contract)

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent {
                Text("Mock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } label: {
                sectionHeader("Connections", icon: "link")
            }
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
                        Text("Not connected")
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
        .frame(width: 140, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .accessibilityHidden(true)
    }

    private var placeholderArtwork: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.system(size: 44)).foregroundStyle(.white)
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Button {
                Task { await service.togglePlayPause() }
            } label: {
                Image(systemName: service.snapshot.transport == .playing ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .accessibilityLabel(service.snapshot.transport == .playing ? "Pause" : "Play")
            .sensoryFeedback(.impact(weight: .medium), trigger: service.snapshot.transport)
            .buttonStyle(.plain)

            Button {
                Task { await service.skip() }
            } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
            .accessibilityLabel("Next track")
            .sensoryFeedback(.impact(weight: .light), trigger: service.snapshot.nowPlaying?.id)
            .buttonStyle(.plain)
        }
    }
}

/// A tuner card — station identity + mood/energy, tactile. LABELED MOCK.
struct TunerCard: View {
    let station: StationConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: station.artName)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(station.name)
                .font(.headline)
                .lineLimit(1)
            Text(station.mood)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(0..<10, id: \.self) { i in
                    Circle()
                        .fill(i < station.energy ? Color.accentColor : Color(.systemGray4))
                        .frame(width: 4, height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(station.name), \(station.mood), energy \(station.energy) of 10")
    }
}

#Preview("Studio — narrow") {
    NavigationStack {
        StudioView(station: Station(id: UUID(), name: "Morning Calm", description: nil, djName: "Maya"))
            .frame(width: 340)
    }
}

#Preview("Studio — wide") {
    NavigationStack {
        StudioView(station: Station(id: UUID(), name: "Morning Calm", description: nil, djName: "Maya"))
            .frame(width: 900)
    }
}