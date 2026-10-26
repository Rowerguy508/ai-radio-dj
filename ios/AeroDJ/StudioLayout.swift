import AeroDJCore
import SwiftUI

/// Open Duo: a two-zone radio control room (ui-contract.md §4). Zone A is the persistent
/// Now Playing panel with transport; Zone B is the Queue / Tune / Connections workspace.
/// Zone widths come from `StudioZoneWidths.allocate`, the same source of truth as the
/// compact/Studio switch, so the switch and the geometry can never disagree (#60 P1).
/// The split is even when possible, so the gutter sits over the Duo's hinge.
///
/// Originally written by Claudio (#60); taken over and revised by Fry.
struct StudioLayout: View {
    let widths: StudioZoneWidths
    let containerHeight: CGFloat
    let zoneA: NowPlayingPanel
    let workspace: WorkspaceView

    var body: some View {
        HStack(alignment: .top, spacing: CGFloat(StudioLayoutMetrics.gutter)) {
            zoneA
                .frame(width: CGFloat(widths.zoneA))
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("studio.zoneA")
            workspace
                .padding(14)
                .frame(width: CGFloat(widths.zoneB))
                .frame(maxHeight: .infinity, alignment: .top)
                .studioSurface(cornerRadius: 28)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("studio.zoneB")
        }
        .padding(.horizontal, CGFloat(StudioLayoutMetrics.edgeInset))
        .padding(.vertical, 12)
    }
}

/// Open Duo at an accessibility text size: the two zones stack in one scroll view and the
/// transport stays reachable (ui-contract.md §6).
struct StudioStackedLayout: View {
    let zoneA: NowPlayingPanel
    let workspace: WorkspaceView

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                zoneA
                workspace
                    .padding(14)
                    .frame(minHeight: 640, alignment: .top)
                    .studioSurface(cornerRadius: 28)
            }
            .padding(.horizontal, CGFloat(StudioLayoutMetrics.edgeInset))
            .padding(.vertical, 12)
        }
    }
}

/// Zone A: persistent Now Playing. Transport is always visible when there is a track;
/// below 480 pt of height the artwork drops to 120 pt instead of hiding transport.
struct NowPlayingPanel: View {
    let station: StationRef?
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    let isTestStation: Bool
    let artworkSide: CGFloat
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StationHeader(station: station, isTestStation: isTestStation)
            switch content {
            case .track(let track):
                ArtworkView(url: track.artworkURL, size: artworkSide)
                    .frame(maxWidth: .infinity)
                TrackBlock(track: track, dj: dj, onReview: onReview)
            default:
                NowPlayingPlaceholder(content: content).padding(.vertical, 40)
            }
            PlaybackErrorBanner(error: snapshot.error, actions: actions)
            Spacer(minLength: 0)
            if content.showsTransport {
                TransportRow(transport: snapshot.transport, actions: actions)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .studioSurface(cornerRadius: 28)
            }
        }
    }
}

/// Zone B: the three-segment workspace. The selected segment is scene state owned by
/// `PlayingScreen`, so it survives folding (the compact sheet shows the same workspace).
struct WorkspaceView: View {
    let studio: StudioPresentationModel
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let search: MusicSearch?
    @Binding var segment: WorkspaceSegment
    @Binding var searchQuery: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Workspace", selection: $segment) {
                ForEach(WorkspaceSegment.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("workspace.segment")

            switch segment {
            case .queue:
                QueueList(content: content, snapshot: snapshot, applyEdit: actions.editUpNext,
                          search: search, searchQuery: $searchQuery)
            case .tune:
                TuneForm(studio: studio)
            case .connections:
                ConnectionsList(model: studio.connections)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// Now playing, then Up Next. Read-only in live: `editUpNext == nil` hides every edit
/// control (ui-contract.md §2.2). Below the list, the real Apple Music search starts
/// something new.
struct QueueList: View {
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let applyEdit: ((UpNextEdit) -> Void)?
    let search: MusicSearch?
    @Binding var searchQuery: String

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if case .track(let now) = content {
                    sectionTitle("Now playing")
                    row(now, isNowPlaying: true, index: nil)
                }
                sectionTitle("Up next")
                if snapshot.upNext.isEmpty {
                    Text("Nothing queued after this song.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(snapshot.upNext.enumerated()), id: \.element.id) { index, track in
                        row(track, isNowPlaying: false, index: index)
                        if index < snapshot.upNext.count - 1 { Divider() }
                    }
                }
                if applyEdit == nil, !snapshot.upNext.isEmpty {
                    Text("Reordering Up Next isn't available yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                if let search {
                    sectionTitle(content.showsTransport ? "Play something else" : "Start listening")
                    StartListeningView(search: search, query: $searchQuery)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func row(_ track: TrackInfo, isNowPlaying: Bool, index: Int?) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(isNowPlaying ? .subheadline.weight(.semibold) : .subheadline)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isNowPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else if let applyEdit, let index {
                Button { applyEdit(.move(from: index, to: index - 1)) } label: {
                    Label("Move up", systemImage: "chevron.up").labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
                .disabled(index == 0)
                Button(role: .destructive) { applyEdit(.remove(id: track.id)) } label: {
                    Label("Remove", systemImage: "minus.circle").labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isNowPlaying ? "Now playing: \(track.title), \(track.artistName)" : "\(track.title), \(track.artistName)")
    }
}
