import AeroDJCore
import SwiftUI

/// Closed Duo: a focused, immersive radio player (ui-contract.md §3). Used whenever the
/// container is narrower than `StudioLayoutMetrics.studioMinWidth`. Renders values and
/// sends intents; owns no playback service.
///
/// Originally written by Claudio (#60); taken over and revised by Fry.
struct CompactPlayer: View {
    let station: StationRef?
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    let isTestStation: Bool
    let search: MusicSearch?
    @Binding var searchQuery: String
    let onOpenWorkspace: () -> Void
    let onReview: () -> Void

    var body: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    StationHeader(station: station, isTestStation: isTestStation)
                    switch content {
                    case .track(let track):
                        ArtworkView(url: track.artworkURL, size: artworkSize(in: geo.size))
                            .padding(.top, 4)
                        TrackBlock(track: track, dj: dj, onReview: onReview, alignment: .leading)
                    case .nothingPlaying:
                        NowPlayingPlaceholder(content: content).padding(.top, 24)
                        if let search { StartListeningView(search: search, query: $searchQuery) }
                    default:
                        NowPlayingPlaceholder(content: content).padding(.top, 48)
                    }
                    PlaybackErrorBanner(error: snapshot.error, actions: actions)
                }
                .padding(.horizontal, CGFloat(StudioLayoutMetrics.edgeInset))
                .padding(.bottom, 16)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if content.showsTransport {
                VStack(spacing: 6) {
                    TransportRow(transport: snapshot.transport, actions: actions)
                    QueueAffordance(upNext: snapshot.upNext, action: onOpenWorkspace)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .studioSurface(cornerRadius: 28)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
    }

    /// min(width − 2·16, 360, 0.45·height), never below 120.
    private func artworkSize(in size: CGSize) -> CGFloat {
        max(120, min(size.width - 32, 360, size.height * 0.45))
    }
}

/// Station identity: name, plus a visible TEST STATION tag in the debug fixture mode so a
/// screenshot can never be mistaken for the listener's real station.
struct StationHeader: View {
    let station: StationRef?
    let isTestStation: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(station?.name ?? "AeroDJ")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            if isTestStation {
                Text("TEST STATION")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().strokeBorder(.secondary))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Title (2 lines), artist (1 line), then the truthful DJ line.
struct TrackBlock: View {
    let track: TrackInfo
    let dj: DJStatusPresentation
    let onReview: () -> Void
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            VStack(alignment: alignment, spacing: 4) {
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(track.artistName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(track.title), \(track.artistName)")
            DJStatusLine(presentation: dj, onReview: onReview)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

#Preview("Compact playing") {
    CompactPlayer(station: PlaybackFixtures.station,
                  content: .track(PlaybackFixtures.songs[0]),
                  snapshot: PlaybackFixtures.playing, actions: .preview,
                  dj: .init(state: .idle, playerReportedLine: nil), isTestStation: true,
                  search: nil, searchQuery: .constant(""), onOpenWorkspace: {}, onReview: {})
}

#Preview("Compact DJ on air") {
    CompactPlayer(station: PlaybackFixtures.station,
                  content: .track(PlaybackFixtures.songs[1]),
                  snapshot: PlaybackFixtures.djSpeaking, actions: .preview,
                  dj: .init(state: .speaking(includesBriefing: false), playerReportedLine: nil),
                  isTestStation: true, search: nil, searchQuery: .constant(""), onOpenWorkspace: {}, onReview: {})
}
