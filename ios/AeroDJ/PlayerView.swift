import SwiftUI
import AeroDJCore

/// Player screen. Two connected layouts driven by `horizontalSizeClass`:
/// - compact (Duo closed): immersive artwork, station identity, unified controls.
/// - regular (Duo unfolded): Studio Mode — persistent Now Playing, editable
///   queue, station tuner, Connections panel (see StudioView).
/// Uses Claude's shared playback state (`PlaybackSnapshot`) + queue contract
/// (`UpNextEdit`) from AeroDJCore. Artwork scales with available space.
struct PlayerView: View {
    let station: Station
    @ObservedObject private var service: MockPlaybackService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showQueue = false

    init(station: Station, service: MockPlaybackService = MockPlaybackService()) {
        self.station = station
        _service = ObservedObject(wrappedValue: service)
    }

    var body: some View {
        // Route on available width, not size class: an iPhone Duo when open is
        // a wide canvas and should show the Studio, even though it's still
        // technically .compact. Portrait iPhone (narrow) shows the compact player.
        GeometryReader { geo in
            Group {
                if geo.size.width >= 680 {
                    StudioView(station: station, service: service)
                } else {
                    compactLayout
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showQueue) {
            CompactQueueSheet(service: service)
        }
    }

    // MARK: - Compact (Duo closed)

    private var compactLayout: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 20) {
                    if let error = service.snapshot.error {
                        errorView(error)
                    } else if let track = service.snapshot.nowPlaying {
                        compactNowPlaying(track, availableHeight: geo.size.height)
                    } else {
                        emptyView
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }

    private func compactNowPlaying(_ track: TrackInfo, availableHeight: CGFloat) -> some View {
        VStack(spacing: 20) {
            stationIdentity
            artwork(track, size: min(availableHeight * 0.48, 320))
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

            controlBar
        }
        .frame(maxWidth: .infinity)
    }

    /// Station + DJ identity above the artwork.
    private var stationIdentity: some View {
        HStack(spacing: 10) {
            Text(service.stations.first(where: { $0.name == station.name })?.artName ?? "dot.radiowaves.left.and.right")
                .font(.subheadline)
                .foregroundStyle(.tint)
            Text(station.name)
                .font(.subheadline.weight(.semibold))
            Text("· DJ \(station.djName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(station.name), DJ \(station.djName)")
    }

    // MARK: - Shared pieces

    /// Truthful DJ status: shown only when the DJ is actually speaking.
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

    /// Unified control bar: skip + queue on a row, large play/pause center.
    private var controlBar: some View {
        VStack(spacing: 16) {
            if case .speaking = service.snapshot.dj { djBadge }

            HStack(spacing: 40) {
                Button {
                    Task { await service.togglePlayPause() }
                } label: {
                    Image(systemName: service.snapshot.transport == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .frame(width: 64, height: 64)
                        .contentShape(Circle())
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                }
                .accessibilityLabel(service.snapshot.transport == .playing ? "Pause" : "Play")
                .sensoryFeedback(.impact(weight: .medium), trigger: service.snapshot.transport)
                .buttonStyle(.plain)

                Button {
                    Task { await service.skip() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Next track")
                .sensoryFeedback(.impact(weight: .light), trigger: service.snapshot.nowPlaying?.id)
                .buttonStyle(.plain)

                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Up next")
                .buttonStyle(.plain)
            }
        }
    }

    private func artwork(_ track: TrackInfo, size: CGFloat) -> some View {
        Group {
            if let url = track.artworkURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: placeholderArtwork(station)
                    case .empty: ProgressView()
                    @unknown default: placeholderArtwork(station)
                    }
                }
            } else {
                placeholderArtwork(station)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .accessibilityHidden(true)
    }

    /// Station-identity artwork (SF Symbol on a station-tinted gradient) —
    /// real album art lands when Claude's TrackInfo.artworkURL is populated.
    private func placeholderArtwork(_ station: Station) -> some View {
        ZStack {
            LinearGradient(
                colors: [.indigo, .purple, .blue],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: service.stations.first(where: { $0.name == station.name })?.artName ?? "music.note")
                .font(.system(size: 72))
                .foregroundStyle(.white)
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

/// Compact queue sheet — a natural entry to reorder/remove up next.
struct CompactQueueSheet: View {
    @ObservedObject var service: MockPlaybackService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if service.snapshot.upNext.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "list.number")
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
                        .onMove { source, dest in
                            // Translate a List move into Claude's UpNextEdit.
                            if let from = source.first {
                                let to = dest > from ? dest - 1 : dest
                                _ = service.applyQueueEdit(.move(from: from, to: to))
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                let id = service.snapshot.upNext[i].id
                                _ = service.applyQueueEdit(.remove(id: id))
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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