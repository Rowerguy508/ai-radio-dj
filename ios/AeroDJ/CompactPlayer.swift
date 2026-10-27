import AeroDJCore
import SwiftUI

/// Closed Duo: bleed artwork fills the window; transport and the DJ line sit in a material inset.
/// Used whenever the container is narrower than `StudioLayoutMetrics.studioMinWidth`, or the
/// width class is compact.
struct CompactPlayer: View {
    let station: StationRef?
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    let soundTags: [String]
    let search: MusicSearch?
    @ObservedObject var studioSearch: StudioSearchModel
    var timeSource: PlaybackTimeSource? = nil
    var artworkNamespace: Namespace.ID? = nil
    var extendsUnderSafeArea = true
    let onOpenWorkspace: () -> Void
    let onTune: () -> Void
    let onReview: () -> Void

    var body: some View {
        BleedNowPlaying(station: station, content: content, snapshot: snapshot, actions: actions,
                        dj: dj, soundTags: soundTags, search: search, studioSearch: studioSearch,
                        timeSource: timeSource,
                        artworkNamespace: artworkNamespace, extendsUnderSafeArea: extendsUnderSafeArea,
                        onQueue: onOpenWorkspace, onTune: onTune, onReview: onReview)
    }
}

/// Listen and Studio share this column. Artwork fills the column edge to edge.
/// Title and artist sit on the art. Transport and the DJ status line sit in a system-material
/// inset, so they stay on screen at accessibility sizes.
struct BleedNowPlaying: View {
    let station: StationRef?
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    let soundTags: [String]
    var search: MusicSearch? = nil
    @ObservedObject var studioSearch: StudioSearchModel
    var timeSource: PlaybackTimeSource? = nil
    var showsUpNext = true
    var artworkNamespace: Namespace.ID? = nil
    /// Closed Listen only. Zone A does not extend past its column.
    var extendsUnderSafeArea = false
    /// The parent scroll pins the transport. This view is then the title, metadata, and art.
    var usesParentScroll = false
    let onQueue: () -> Void
    let onTune: () -> Void
    let onReview: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            if usesParentScroll {
                accessibilityContent
            } else {
                ScrollView { accessibilityContent }
                    .safeAreaInset(edge: .bottom, spacing: 0) { chrome }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            bleed
        }
    }

    /// Title and chrome own the layout frame. Artwork is only a background so its
    /// bleed cannot widen the accessibility union that `studio.zoneA` reports.
    private var bleed: some View {
        GeometryReader { geo in
            titleBlock
                .environment(\.onSlab, true)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .background {
                    BleedArtwork(track: heroTrack, station: station)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .modifier(BleedArtFrame(namespace: artworkNamespace))
                        // Compact Listen only: expand the *background*, not the layout frame.
                        .ignoresSafeArea(edges: extendsUnderSafeArea ? .all : [])
                        .accessibilityHidden(true)
                }
                .clipped()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { chrome }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Title and metadata first, then the art. No fixed height: the art is a square of the
    /// column width, and the scroll's inset keeps that title above the transport.
    private var accessibilityContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            slabText
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            BleedArtwork(track: heroTrack, station: station)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .modifier(BleedArtFrame(namespace: artworkNamespace))
        }
        .environment(\.onSlab, false)
    }

    private var heroTrack: TrackInfo? {
        if case .track(let track) = content { return track }
        return nil
    }

    private var titleBlock: some View {
        ScrollView(showsIndicators: false) {
            slabText
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var slabText: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch content {
            case .track(let track):
                TrackBlock(track: track, stationName: station?.name)
                if !soundTags.isEmpty {
                    StationSoundRow(tags: soundTags, action: onTune)
                }
            case .nothingPlaying:
                NowPlayingPlaceholder(content: content, actions: actions)
                if let search {
                    StartListeningView(search: search, model: studioSearch)
                }
            default:
                NowPlayingPlaceholder(content: content, actions: actions)
            }
        }
    }

    private var chrome: some View {
        PlaybackChromeBar(content: content, snapshot: snapshot, actions: actions, dj: dj,
                          timeSource: timeSource, showsUpNext: showsUpNext,
                          onQueue: onQueue, onTune: onTune, onReview: onReview)
    }
}

/// Transport, DJ line, and error. Pinned with `safeAreaInset` so the scrolling title
/// clears it. Draws nothing when there is no status and no transport.
struct PlaybackChromeBar: View {
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    var timeSource: PlaybackTimeSource? = nil
    var showsUpNext = true
    let onQueue: () -> Void
    let onTune: () -> Void
    let onReview: () -> Void

    private var showsChrome: Bool {
        content.showsTransport || snapshot.error != nil || showsStatus || showsProgress
    }

    private var showsProgress: Bool {
        guard content.showsTransport, let timeSource else { return false }
        return timeSource.duration().map { $0 > 0 } ?? false
    }

    private var showsStatus: Bool {
        switch dj.state {
        case .idle, .ready: false
        default: true
        }
    }

    var body: some View {
        if showsChrome {
            ViewThatFits(in: .vertical) {
                chromeStack
                if content.showsTransport {
                    TransportRow(transport: snapshot.transport, startTimedOut: snapshot.startTimedOut,
                             actions: actions, onTune: onTune)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .systemMaterialBackground()
            .environment(\.onSlab, false)
        }
    }

    private var chromeStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsStatus {
                DJStatusLine(presentation: dj, onReview: onReview)
            }
            PlaybackErrorBanner(error: snapshot.error, actions: actions)
            if content.showsTransport, showsUpNext {
                QueueAffordance(upNext: snapshot.upNext, action: onQueue)
            }
            if showsProgress, let timeSource {
                PlaybackProgressBar(time: timeSource)
            }
            if content.showsTransport {
                TransportRow(transport: snapshot.transport, startTimedOut: snapshot.startTimedOut,
                             actions: actions, onTune: onTune)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

/// The station's saved sound as a quiet row of tags; tapping opens the tuner.
struct StationSoundRow: View {
    let tags: [String]
    let action: () -> Void
    @Environment(\.onSlab) private var onSlab

    private var ink: Color { onSlab ? AeroDJPalette.slabSecondary : AeroDJPalette.secondaryText }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "dial.medium")
                    .foregroundStyle(ink)
                    .accessibilityHidden(true)
                Text(tags.prefix(4).joined(separator: " · "))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(ink)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Station sound: \(tags.joined(separator: ", "))")
        .accessibilityHint("Opens the tuner")
        .accessibilityIdentifier("station.sound")
    }
}

/// Wraps inside the column, then truncates, so the label's frame cannot cross the gutter.
private struct ColumnLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .lineLimit(8)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Serif title, then artist and station in the system face. All of it wraps on the slab.
struct TrackBlock: View {
    let track: TrackInfo
    let stationName: String?
    @Environment(\.onSlab) private var onSlab

    private var titleInk: Color { onSlab ? AeroDJPalette.onMediaLight : Color.primary }
    private var secondaryInk: Color { onSlab ? AeroDJPalette.slabSecondary : Color.secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.title)
                .font(.system(.largeTitle, design: .serif))
                .foregroundStyle(titleInk)
                .modifier(ColumnLabel())
            Text(track.artistName)
                .font(.body)
                .foregroundStyle(secondaryInk)
                .modifier(ColumnLabel())
            if let stationName, !stationName.isEmpty {
                Text(stationName)
                    .font(.subheadline)
                    .foregroundStyle(secondaryInk)
                    .modifier(ColumnLabel())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var spokenTitle: String {
        [track.title, track.artistName, stationName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

#Preview("Compact playing") {
    CompactPlayer(station: PlaybackFixtures.station,
                  content: .track(PlaybackFixtures.songs[0]),
                  snapshot: PlaybackFixtures.playing, actions: .preview,
                  dj: .init(state: .idle), soundTags: ["indie", "bright"],
                  search: nil, studioSearch: StudioSearchModel(query: ""),
                  timeSource: {
                      #if DEBUG
                      return .fixture
                      #else
                      return nil
                      #endif
                  }(),
                  onOpenWorkspace: {}, onTune: {}, onReview: {})
}

#Preview("Compact speaking") {
    CompactPlayer(station: PlaybackFixtures.station,
                  content: .track(PlaybackFixtures.songs[1]),
                  snapshot: PlaybackFixtures.djSpeaking, actions: .preview,
                  dj: .init(state: .speaking(includesBriefing: false)),
                  soundTags: [], search: nil, studioSearch: StudioSearchModel(query: ""),
                  onOpenWorkspace: {}, onTune: {}, onReview: {})
}
