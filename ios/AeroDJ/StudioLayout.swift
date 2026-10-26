import AeroDJCore
import SwiftUI

/// Unfolded Studio (ui-contract.md §4). Two persistent zones: Zone A = Now
/// Playing + transport; Zone B = segmented Queue / Tune / Connections workspace.
/// Both zones share the leaf views from PlaybackComponents.swift. Switching a
/// segment never resets playback or scrolls Zone A.
struct StudioLayout: View {
    let station: StationRef?
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJPresentationState
    let stationModel: StationConfigurationModel
    let onOpenQueue: () -> Void
    @State private var segment: WorkspaceSegment = .queue
    @State private var browsing = false

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: gutter) {
                // Zone A: persistent Now Playing + transport.
                NowPlayingPanel(station: station, snapshot: snapshot,
                                actions: actions, dj: dj, height: geo.size.height)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .padding(.leading, edgeInset)

                // Zone B: persistent workspace.
                WorkspaceView(stationModel: stationModel, snapshot: snapshot,
                              actions: actions, dj: dj,
                              segment: $segment, onOpenQueue: onOpenQueue,
                              browsing: $browsing)
                    .frame(minWidth: zoneBMinWidth, maxWidth: .infinity)
                    .padding(.trailing, edgeInset)
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemBackground))
    }

    // MARK: Constants (ui-contract.md §5)

    private let gutter: CGFloat = 24
    private let edgeInset: CGFloat = 16
    private let zoneBMinWidth: CGFloat = 340
}

/// Additive layout constants shared with the width switch in PlayingScreen.
enum StudioMetrics {
    static let gutter: CGFloat = 24
    static let edgeInset: CGFloat = 16
    static let zoneAMinWidth: CGFloat = 320
    static let zoneBMinWidth: CGFloat = 340
    /// 320 + 24 + 340 = 684. The only layout decision.
    static var studioMinWidth: CGFloat { zoneAMinWidth + gutter + zoneBMinWidth }
}

/// Zone A: persistent Now Playing + always-visible transport.
struct NowPlayingPanel: View {
    let station: StationRef?
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJPresentationState
    let height: CGFloat

    var body: some View {
        let artwork: CGFloat = min(height < 480 ? 120 : 300, 300)
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                StationHeader(station: station, dj: dj)

                ArtworkView(url: snapshot.nowPlaying?.artworkURL, size: artwork)
                    .frame(maxWidth: .infinity)

                TrackBlock(snapshot: snapshot, dj: dj)

                // §5: at low height keep transport, drop artwork to 120.
                if height >= 480 {
                    TransportRow(transport: snapshot.transport, actions: actions)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            if height < 480 {
                // Transport must never be hidden, even at low height.
                TransportRow(transport: snapshot.transport, actions: actions)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
    }
}

/// Zone B: the three-segment workspace.
struct WorkspaceView: View {
    let stationModel: StationConfigurationModel
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJPresentationState
    @Binding var segment: WorkspaceSegment
    let onOpenQueue: () -> Void
    @Binding var browsing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Workspace", selection: $segment) {
                ForEach(WorkspaceSegment.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch segment {
                case .queue:
                    QueueList(snapshot: snapshot, editingAllowed: actions.editUpNext != nil,
                              applyEdit: actions.editUpNext)
                case .tune:
                    TuneForm(model: stationModel)
                case .connections:
                    ConnectionsList(model: stationModel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

enum WorkspaceSegment: String, CaseIterable, Identifiable {
    case queue, tune, connections
    var id: String { rawValue }
    var title: String {
        switch self {
        case .queue: "Queue"
        case .tune: "Tune"
        case .connections: "Connections"
        }
    }
}

/// Queue: a "Now playing" row above the up-next list. Read-only in live
/// (editUpNext == nil hides all edit affordances per §2.2).
struct QueueList: View {
    let snapshot: PlaybackSnapshot
    let editingAllowed: Bool
    let applyEdit: ((UpNextEdit) -> Void)?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if let now = snapshot.nowPlaying {
                    LabeledRow(title: now.title, subtitle: now.artistName,
                               isNowPlaying: true)
                }
                Divider()
                if snapshot.upNext.isEmpty {
                    Text("Up next is empty.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                } else {
                    ForEach(Array(snapshot.upNext.enumerated()), id: \.element.id) { index, track in
                        queueRow(for: track, at: index)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func queueRow(for track: TrackInfo, at index: Int) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if editingAllowed {
                Button {
                    applyEdit?(.move(from: index, to: index - 1))
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .buttonStyle(.borderless)

                Button {
                    applyEdit?(.move(from: index, to: index + 1))
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == snapshot.upNext.count - 1)
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    applyEdit?(.remove(id: track.id))
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct LabeledRow: View {
    let title: String
    let subtitle: String
    let isNowPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(isNowPlaying ? .subheadline.weight(.semibold) : .subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if isNowPlaying {
                Text("Now playing")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

#Preview("Studio layout") {
    StudioLayoutPreviewLoader()
}

struct StudioLayoutPreviewLoader: View {
    @State private var model: StationConfigurationModel?

    var body: some View {
        Group {
            if let model {
                StudioLayout(
                    station: PlaybackFixtures.station,
                    snapshot: PlaybackFixtures.playing,
                    actions: .preview,
                    dj: .idle,
                    stationModel: model,
                    onOpenQueue: {})
            } else {
                ProgressView()
            }
        }
        .task { model = await StationConfigurationModel.preview() }
    }
}
