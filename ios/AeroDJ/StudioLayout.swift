import AeroDJCore
import SwiftUI

/// Open Duo: a two-zone radio control room (ui-contract.md §4). Zone A is the persistent
/// Now Playing panel with transport; Zone B is the Queue / Tune / Connections workspace.
/// Zone widths come from `StudioZoneWidths.allocate`, the same source of truth as the
/// compact/Studio switch, so the switch and the geometry can never disagree (#60 P1).
/// The split is an even split of the available width when possible, so the gutter sits at
/// the container's middle. It does not track the Duo's hinge: a vertical bar or a sidebar
/// can shift or narrow the container.
///
/// Originally written by Claudio (#60); taken over and revised by Fry.
struct StudioLayout: View {
    let widths: StudioZoneWidths
    let containerHeight: CGFloat
    let zoneA: NowPlayingPanel
    let workspace: WorkspaceView

    var body: some View {
        // The margin and gutter `widths` was allocated with (`allocatePanes`: 8 and 12 pt),
        // so the drawn geometry always adds up to the container. The compact/Studio switch
        // still uses `StudioLayoutMetrics.studioMinWidth`.
        let edge = CGFloat(widths.edgeInset)
        let gutter = CGFloat(widths.gutter)
        let panel = RoundedRectangle(cornerRadius: CGFloat(StudioCornerRadius.panel), style: .continuous)
        // Exact column widths. Edge is outer padding only — never folded into zoneA/zoneB,
        // which previously made Zone A’s container report past the gutter (430 > 422).
        HStack(alignment: .top, spacing: gutter) {
            zoneA
                .frame(width: CGFloat(widths.zoneA))
                .frame(maxHeight: .infinity, alignment: .top)
                .clipShape(panel)
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("studio.zoneA")
            workspace
                .environment(\.studioPanes, true)
                .padding(CGFloat(StudioCornerRadius.panelPadding))
                .frame(width: CGFloat(widths.zoneB), alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .systemMaterialBackground()
                .clipShape(panel)
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("studio.zoneB")
        }
        .padding(.horizontal, edge)
        // No extra bottom padding: the container already stops at the bottom safe area.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(height: containerHeight, alignment: .top)
        .background(Color(.systemBackground))
    }
}

/// Open Duo at an accessibility text size: the two zones stack in one scroll view and the
/// transport stays reachable (ui-contract.md §6). The inset keeps the transport on screen
/// and lets the title scroll clear of it. Nothing here uses a fixed height.
///
/// iPad (regular width only, -Nova): the same stack in a centred readable column
/// (`LayoutMetrics.readableMaxWidth`) instead of edge to edge across up to 1366 pt.
/// Every other device, including iPhone Plus/Max landscape and the open Duo (regular width,
/// phone idiom), takes `phoneBody`, which is the pre-iPad body unchanged.
struct StudioStackedLayout: View {
    let zoneA: NowPlayingPanel
    let workspace: WorkspaceView
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if let readableWidth = LayoutMetrics(horizontalSizeClass).readableMaxWidth {
            iPadBody(readableWidth: CGFloat(readableWidth))
        } else {
            phoneBody
        }
    }

    /// iPhone path. Byte-for-byte the body before iPad support; do not edit for iPad.
    /// Pinned by ios/scripts/check-iphone-compact-path.sh.
    private var phoneBody: some View {
        ScrollView {
            VStack(spacing: 0) {
                zoneA
                workspace
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .systemMaterialBackground()
            }
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            zoneA.chromeBar
        }
    }

    /// iPad only: the same views, capped to a readable column and centred. The scroll view
    /// stays full width so the whole screen scrolls and the indicator sits at the edge.
    private func iPadBody(readableWidth: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                zoneA
                workspace
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .systemMaterialBackground()
            }
            .frame(maxWidth: readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            zoneA.chromeBar
                .frame(maxWidth: readableWidth)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Zone A: persistent Now Playing. Artwork meets the gutter; the slab and transport sit under it.
struct NowPlayingPanel: View {
    let station: StationRef?
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    let soundTags: [String]
    @ObservedObject var studioSearch: StudioSearchModel
    var timeSource: PlaybackTimeSource? = nil
    /// Off while Zone B already shows the queue, so Up Next isn't listed twice.
    var showsUpNext = true
    var artworkNamespace: Namespace.ID? = nil
    /// Closed Listen draws the art under the safe areas. Zone A stays clipped to its column.
    var extendsUnderSafeArea = false
    /// The stacked layout already scrolls and pins this panel's transport. Zone A is then
    /// only the title, metadata, and art, so a second scroll does not nest inside the first.
    var usesParentScroll = false
    let onQueue: () -> Void
    let onTune: () -> Void
    let onReview: () -> Void

    var body: some View {
        BleedNowPlaying(station: station, content: content, snapshot: snapshot, actions: actions,
                        dj: dj, soundTags: soundTags, studioSearch: studioSearch,
                        timeSource: timeSource,
                        showsUpNext: showsUpNext, artworkNamespace: artworkNamespace,
                        extendsUnderSafeArea: extendsUnderSafeArea, usesParentScroll: usesParentScroll,
                        onQueue: onQueue, onTune: onTune, onReview: onReview)
    }

    /// The transport bar the stacked scroll pins to the bottom edge.
    var chromeBar: some View {
        PlaybackChromeBar(content: content, snapshot: snapshot, actions: actions, dj: dj,
                          timeSource: timeSource, showsUpNext: showsUpNext,
                          onQueue: onQueue, onTune: onTune, onReview: onReview)
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
    @ObservedObject var studioSearch: StudioSearchModel
    @Binding var segment: WorkspaceSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Workspace", selection: $segment) {
                ForEach(WorkspaceSegment.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .workspaceSegmentShape()
            .accessibilityIdentifier("workspace.segment")

            switch segment {
            case .queue:
                QueueList(content: content, snapshot: snapshot, applyEdit: actions.editUpNext,
                          search: search, studioSearch: studioSearch)
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
    @ObservedObject var studioSearch: StudioSearchModel
    @Environment(\.dynamicTypeSize) private var typeSize

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
                        .foregroundStyle(AeroDJPalette.secondaryText)
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
                        .foregroundStyle(AeroDJPalette.secondaryText)
                        .padding(.top, 8)
                }
                if let search {
                    sectionTitle(content.showsTransport ? "Play something else" : "Start listening")
                    StartListeningView(search: search, model: studioSearch)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AeroDJPalette.secondaryText)
            .textCase(.uppercase)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func row(_ track: TrackInfo, isNowPlaying: Bool, index: Int?) -> some View {
        // The hero already speaks this song. Repeating the title here makes a shorter
        // "Morning Light" below the transport, and a containing element still exposes it.
        let repeatsHeroTitle = isNowPlaying && typeSize.isAccessibilitySize
        HStack(spacing: 12) {
            ArtworkView(track: track, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(repeatsHeroTitle ? track.artistName : track.title)
                    .font(isNowPlaying ? .subheadline.weight(.semibold) : .subheadline)
                    .lineLimit(1)
                if !repeatsHeroTitle {
                    Text(track.artistName)
                        .font(.caption)
                        .foregroundStyle(AeroDJPalette.secondaryText)
                        .lineLimit(1)
                }
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
        .accessibilityLabel(repeatsHeroTitle
            ? "Now playing, \(track.artistName)"
            : (isNowPlaying ? "Now playing: \(track.title), \(track.artistName)" : "\(track.title), \(track.artistName)"))
    }
}
