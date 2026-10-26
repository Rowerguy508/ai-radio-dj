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
    let accent: Color
    /// The station's saved sound (genres and moods), shown as identity, not as a promise
    /// about song picking.
    let soundTags: [String]
    let search: MusicSearch?
    @Binding var searchQuery: String
    let onOpenWorkspace: () -> Void
    let onTune: () -> Void
    let onReview: () -> Void

    var body: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    switch content {
                    case .track(let track):
                        Spacer(minLength: 8)
                        ArtworkView(track: track, size: artworkSize(in: geo.size))
                        Spacer(minLength: 20)
                        TrackBlock(track: track, dj: dj, onReview: onReview, alignment: .leading)
                        if !soundTags.isEmpty {
                            StationSoundRow(tags: soundTags, action: onTune)
                                .padding(.top, 14)
                        }
                        Spacer(minLength: 12)
                    case .nothingPlaying:
                        NowPlayingPlaceholder(content: content).padding(.top, 24)
                        if let search { StartListeningView(search: search, query: $searchQuery).padding(.top, 16) }
                    default:
                        NowPlayingPlaceholder(content: content).padding(.top, 48)
                    }
                    PlaybackErrorBanner(error: snapshot.error, actions: actions)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if content.showsTransport {
                VStack(spacing: 8) {
                    QueueAffordance(upNext: snapshot.upNext, action: onOpenWorkspace)
                    Divider().opacity(0.5)
                    TransportRow(transport: snapshot.transport, actions: actions, accent: accent, onTune: onTune)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .studioSurface(cornerRadius: 30)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
    }

    /// As large as fits: min(width − 2·20, 380, 0.5·height), never below 120.
    private func artworkSize(in size: CGSize) -> CGFloat {
        max(120, min(size.width - 40, 380, size.height * 0.5))
    }
}

/// The station's saved sound as a quiet row of tags; tapping opens the tuner.
struct StationSoundRow: View {
    let tags: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "dial.medium").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(tags.prefix(4).joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Station sound: \(tags.joined(separator: ", "))")
        .accessibilityHint("Opens the tuner")
        .accessibilityIdentifier("station.sound")
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
                  dj: .init(state: .idle), accent: .indigo, soundTags: ["indie", "bright"],
                  search: nil, searchQuery: .constant(""), onOpenWorkspace: {}, onTune: {}, onReview: {})
}

#Preview("Compact DJ on air") {
    CompactPlayer(station: PlaybackFixtures.station,
                  content: .track(PlaybackFixtures.songs[1]),
                  snapshot: PlaybackFixtures.djSpeaking, actions: .preview,
                  dj: .init(state: .speaking(includesBriefing: false)),
                  accent: .indigo, soundTags: [], search: nil, searchQuery: .constant(""),
                  onOpenWorkspace: {}, onTune: {}, onReview: {})
}
