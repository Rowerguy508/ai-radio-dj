import AeroDJCore
import SwiftUI

/// Closed Duo: bleed artwork on top, type and transport on the slab below.
/// Used whenever the container is narrower than `StudioLayoutMetrics.studioMinWidth`.
struct CompactPlayer: View {
    let station: StationRef?
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    let soundTags: [String]
    let search: MusicSearch?
    @Binding var searchQuery: String
    var artworkNamespace: Namespace.ID? = nil
    let onOpenWorkspace: () -> Void
    let onTune: () -> Void
    let onReview: () -> Void

    var body: some View {
        BleedNowPlaying(station: station, content: content, snapshot: snapshot, actions: actions,
                        dj: dj, soundTags: soundTags, search: search, searchQuery: $searchQuery,
                        artworkNamespace: artworkNamespace,
                        onQueue: onOpenWorkspace, onTune: onTune, onReview: onReview)
    }
}

/// Listen and Studio share this column. Artwork is full-bleed and square-cornered.
/// Title, artist, and station sit on an opaque slab that grows as type grows; the art shrinks
/// to make room. Transport stays pinned, so it remains on screen at accessibility sizes.
struct BleedNowPlaying: View {
    let station: StationRef?
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    let soundTags: [String]
    var search: MusicSearch? = nil
    @Binding var searchQuery: String
    var showsUpNext = true
    var artworkNamespace: Namespace.ID? = nil
    /// Set when the parent is a scroll view and cannot offer a height.
    var lockedHeight: CGFloat? = nil
    let onQueue: () -> Void
    let onTune: () -> Void
    let onReview: () -> Void

    private static let minimumArt: CGFloat = 64
    @State private var textHeight: CGFloat = 220

    var body: some View {
        GeometryReader { geo in
            column(width: geo.size.width, height: geo.size.height)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if content.showsTransport {
                transportBar
            }
        }
        .background(AeroDJPalette.slab)
        .environment(\.onSlab, true)
        .frame(height: lockedHeight)
        .frame(maxWidth: .infinity, maxHeight: lockedHeight == nil ? .infinity : nil)
        .onPreferenceChange(BleedTextHeightKey.self) { new in
            guard new > 0, abs(new - textHeight) > 1 else { return }
            withTransaction(Transaction(animation: nil)) { textHeight = new }
        }
    }

    private func column(width: CGFloat, height: CGFloat) -> some View {
        let overflow = textHeight + Self.minimumArt > height
        let artHeight = overflow ? Self.minimumArt : max(Self.minimumArt, height - textHeight)
        return VStack(spacing: 0) {
            BleedArtwork(track: heroTrack, station: station)
                .frame(width: width, height: artHeight)
                .clipped()
                .modifier(BleedArtFrame(namespace: artworkNamespace))
            if overflow {
                ScrollView(showsIndicators: false) {
                    measuredText
                }
                .frame(width: width, height: max(0, height - artHeight))
            } else {
                measuredText
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .clipped()
    }

    private var heroTrack: TrackInfo? {
        if case .track(let track) = content { return track }
        return nil
    }

    private var measuredText: some View {
        slabText
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: BleedTextHeightKey.self, value: proxy.size.height)
                }
            }
    }

    @ViewBuilder
    private var slabText: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch content {
            case .track(let track):
                TrackBlock(track: track, stationName: station?.name, dj: dj, onReview: onReview)
                if !soundTags.isEmpty {
                    StationSoundRow(tags: soundTags, action: onTune)
                }
            case .nothingPlaying:
                NowPlayingPlaceholder(content: content)
                if let search {
                    StartListeningView(search: search, query: $searchQuery)
                }
            default:
                NowPlayingPlaceholder(content: content)
            }
            PlaybackErrorBanner(error: snapshot.error, actions: actions)
        }
    }

    private var transportBar: some View {
        VStack(spacing: 8) {
            if showsUpNext {
                QueueAffordance(upNext: snapshot.upNext, action: onQueue)
                Rectangle()
                    .fill(AeroDJPalette.slabSecondary.opacity(0.4))
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            TransportRow(transport: snapshot.transport, actions: actions, onTune: onTune)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(AeroDJPalette.slab)
    }
}

private struct BleedTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The station's saved sound as a quiet row of tags; tapping opens the tuner.
struct StationSoundRow: View {
    let tags: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "dial.medium")
                    .foregroundStyle(AeroDJPalette.slabSecondary)
                    .accessibilityHidden(true)
                Text(tags.prefix(4).joined(separator: " · "))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(AeroDJPalette.slabSecondary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Station sound: \(tags.joined(separator: ", "))")
        .accessibilityHint("Opens the tuner")
        .accessibilityIdentifier("station.sound")
    }
}

/// Serif title, then artist and station in the system face. All of it wraps on the slab.
struct TrackBlock: View {
    let track: TrackInfo
    let stationName: String?
    let dj: DJStatusPresentation
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(.largeTitle, design: .serif))
                    .foregroundStyle(AeroDJPalette.onMediaLight)
                    .fixedSize(horizontal: false, vertical: true)
                Text(track.artistName)
                    .font(.body)
                    .foregroundStyle(AeroDJPalette.slabSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let stationName, !stationName.isEmpty {
                    Text(stationName)
                        .font(.subheadline)
                        .foregroundStyle(AeroDJPalette.slabSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenTitle)
            DJStatusLine(presentation: dj, onReview: onReview)
                .padding(.top, 6)
        }
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
                  search: nil, searchQuery: .constant(""), onOpenWorkspace: {}, onTune: {}, onReview: {})
}

#Preview("Compact speaking") {
    CompactPlayer(station: PlaybackFixtures.station,
                  content: .track(PlaybackFixtures.songs[1]),
                  snapshot: PlaybackFixtures.djSpeaking, actions: .preview,
                  dj: .init(state: .speaking(includesBriefing: false)),
                  soundTags: [], search: nil, searchQuery: .constant(""),
                  onOpenWorkspace: {}, onTune: {}, onReview: {})
}
