import AeroDJCore
import SwiftUI

/// Compact Now Playing (ui-contract.md §3). Used when the container is below
/// `studioMinWidth`. Renders a `PlaybackSnapshot` + `PlaybackActions` + DJ state;
/// owns no playback service. Safe-area-aware; never clips; text never breaks
/// mid-word. Scrolls only when the content exceeds the container height.
struct CompactPlayer: View {
    let station: StationRef?
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJPresentationState
    let onOpenQueue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geo in
            let content = VStack(alignment: .leading, spacing: 0) {
                StationHeader(station: station, dj: dj)
                    .padding(.bottom, 20)

                // Artwork: scaled frame, never a fixed size beyond the container.
                ArtworkView(url: snapshot.nowPlaying?.artworkURL,
                            size: artworkSize(in: geo.size))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 28)

                TrackBlock(snapshot: snapshot, dj: dj)
            }

            // Fixed VStack if it fits, ScrollView only when it doesn't.
            if fits(content: geo.height) {
                content
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) { content.padding(16) }
            }
        }
        .padding(.horizontal, 16)
        .safeAreaInset(edge: .bottom) {
            transportAndQueue
        }
    }

    /// min(containerWidth − 2·16, 360, 0.45·containerHeight), scaled frame.
    private func artworkSize(in size: CGSize) -> CGFloat {
        min(min(size.width - 32, 360), max(0.45 * size.height, 120))
    }

    private func fits(content height: CGFloat) -> Bool {
        // Rough budget: header (~60) + artwork (<= 0.45·h, capped) + track block
        // (~120) + transport (~90). When Dynamic Type grows, give up and scroll.
        if typeSize >= .xxxLarge { return false }
        return height >= 520
    }

    private var transportAndQueue: some View {
        VStack(spacing: 20) {
            TransportRow(transport: snapshot.transport, actions: actions)
            QueueAffordance(upNext: snapshot.upNext, action: onOpenQueue)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}

/// §3.1 Station identity row.
struct StationHeader: View {
    let station: StationRef?
    let dj: DJPresentationState

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(station?.name ?? "AeroDJ")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if dj.isLive {
                Text("DJ on air")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// §3.3 Track block: title (2 lines) + artist (1 line) + DJ line.
struct TrackBlock: View {
    let snapshot: PlaybackSnapshot
    let dj: DJPresentationState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.nowPlaying?.title ?? "Nothing playing")
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.tail)
            Text(snapshot.nowPlaying?.artistName ?? " ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            DJStatusLine(state: dj, spokenLine: snapshot.dj.speakingLine)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension DJActivity {
    /// The spoken line text, if the DJ is speaking.
    var speakingLine: String? {
        if case .speaking(let line) = self { return line }
        return nil
    }
}

#Preview("Compact playing") {
    CompactPlayer(
        station: PlaybackFixtures.station,
        snapshot: PlaybackFixtures.playing,
        actions: .preview,
        dj: .idle,
        onOpenQueue: {})
}

#Preview("Compact DJ speaking") {
    CompactPlayer(
        station: PlaybackFixtures.station,
        snapshot: PlaybackFixtures.djSpeaking,
        actions: .preview,
        dj: .speaking(afterTrack: 0, includesBriefing: false),
        onOpenQueue: {})
}

#Preview("Compact stopped / empty") {
    CompactPlayer(
        station: PlaybackFixtures.station,
        snapshot: PlaybackFixtures.stopped,
        actions: .preview,
        dj: .idle,
        onOpenQueue: {})
}
