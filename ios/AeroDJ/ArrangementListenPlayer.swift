import AeroDJCore
import SwiftUI

/// Regular-width listen player (#465 item 4). Artwork and the controls are one pane.
/// The up-next timeline is the other. `ArrangementPaneLayout` decides which, and a
/// compact or phone-sized container never reaches this view.
///
/// On iOS 27.1 the split is an `ArrangementView`. The SDK this tree builds with draws
/// the same two panes from the layout frames. Playback, the DJ session, and narration
/// are untouched: the controls are the shared `TransportRow` and the existing callbacks.
struct ArrangementListenPlayer: View {
    let station: StationRef
    let heading: StationHeading
    let isTestStation: Bool
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    let search: MusicSearch?
    var timeSource: PlaybackTimeSource? = nil
    let decision: ArrangementPaneLayout.Decision
    let onQueue: () -> Void
    let onTune: () -> Void
    let onConnections: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        arranged
            .background {
                FoldedStyle.background
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            .environment(\.colorScheme, .dark)
            .environment(\.onSlab, true)
    }

    @ViewBuilder
    private var arranged: some View {
        switch decision {
        case .unchanged:
            EmptyView()
        case .split(let metrics):
            split(metrics)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("arrangement.split")
        case .singleColumn(let metrics):
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: CGFloat(metrics.gutter)) {
                    primary
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("arrangement.primary")
                        .accessibilityLabel("Now playing")
                    timeline
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("arrangement.secondary")
                        .accessibilityLabel("Up next")
                }
                .padding(CGFloat(metrics.edgeInset))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("arrangement.column")
        }
    }

    @ViewBuilder
    private func split(_ metrics: ArrangementPaneLayout.Metrics) -> some View {
        #if compiler(>=6.4.2)
        if #available(iOS 27.1, *) {
            systemSplit(metrics)
        } else {
            manualSplit(metrics)
        }
        #else
        manualSplit(metrics)
        #endif
    }

    /// The frames `ArrangementPaneLayout` already checked. Used when `ArrangementView` is not in the SDK.
    private func manualSplit(_ metrics: ArrangementPaneLayout.Metrics) -> some View {
        let edge = CGFloat(metrics.edgeInset)
        let gap = CGFloat(metrics.gutter)
        let primaryWidth = CGFloat(metrics.primary.width)
        let primaryHeight = CGFloat(metrics.primary.height)
        let secondaryWidth = CGFloat(metrics.secondary.width)
        let secondaryHeight = CGFloat(metrics.secondary.height)
        return Group {
            switch metrics.axis {
            case .horizontal:
                HStack(alignment: .top, spacing: gap) {
                    pane(primary, width: primaryWidth, height: primaryHeight, identifier: "arrangement.primary",
                         label: "Now playing", sort: 2)
                    pane(timeline, width: secondaryWidth, height: secondaryHeight, identifier: "arrangement.secondary",
                         label: "Up next", sort: 1)
                }
            case .vertical:
                VStack(alignment: .leading, spacing: gap) {
                    pane(primary, width: primaryWidth, height: primaryHeight, identifier: "arrangement.primary",
                         label: "Now playing", sort: 2)
                    pane(timeline, width: secondaryWidth, height: secondaryHeight, identifier: "arrangement.secondary",
                         label: "Up next", sort: 1)
                }
            }
        }
        .padding(edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pane<Content: View>(_ content: Content, width: CGFloat, height: CGFloat,
                                     identifier: String, label: String, sort: Double) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .accessibilitySortPriority(sort)
    }

    // MARK: - Primary (artwork and controls)

    private var primary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isTestStation {
                Text("TEST STATION")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FoldedStyle.secondaryInk)
                    .accessibilityLabel("Test station")
                    .accessibilityIdentifier("folded.testStation")
            }
            switch content {
            case .track(let track):
                artwork(track)
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(track.artistName)
                    .font(.body)
                    .foregroundStyle(FoldedStyle.secondaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                status
            default:
                NowPlayingPlaceholder(content: content, actions: actions)
                if case .nothingPlaying = content, search != nil {
                    SearchAppleMusicButton(action: onQueue)
                }
            }
            PlaybackErrorBanner(error: snapshot.error, actions: actions)
            if showsProgress, let timeSource {
                PlaybackScrubber(time: timeSource, transport: snapshot.transport,
                                 trackID: snapshot.nowPlaying?.id,
                                 canSeek: snapshot.canSeek,
                                 onSeek: { await actions.seek(to: $0, trackID: $1) },
                                 isDJSpeaking: dj.state.onAirLabel != nil)
            }
            if content.showsTransport {
                TransportRow(transport: snapshot.transport, startTimedOut: snapshot.startTimedOut,
                             actions: actions, onTune: nil, balancesSides: false)
                    .frame(minHeight: CGFloat(ArrangementPaneLayout.hitTarget))
            }
            stationChip
            chrome
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func artwork(_ track: TrackInfo) -> some View {
        let side = artSide
        BleedArtwork(track: track, station: station)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: FoldedStyle.artRadius, style: .continuous))
            .accessibilityHidden(true)
    }

    /// Square art inside the primary pane. The pane scrolls if Dynamic Type needs the rest.
    private var artSide: CGFloat {
        let width: Double
        let height: Double
        switch decision {
        case .unchanged:
            width = 240
            height = 240
        case .split(let metrics), .singleColumn(let metrics):
            width = metrics.primary.width - 24
            height = min(120, metrics.primary.height * 0.18)
        }
        return CGFloat(max(ArrangementPaneLayout.hitTarget, min(width, height, 420)))
    }

    /// On Air and its dot use `DJStudioState.onAirLabel` only. Other states keep their
    /// quiet headline, and that headline is never the On Air string.
    @ViewBuilder
    private var status: some View {
        if let label = ArrangementPaneLayout.liveMark(onAirLabel: dj.state.onAirLabel) {
            HStack(spacing: 8) {
                Circle()
                    .fill(FoldedStyle.onAirAmber)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FoldedStyle.onAirAmber)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: CGFloat(ArrangementPaneLayout.hitTarget),
                   minHeight: CGFloat(ArrangementPaneLayout.hitTarget), alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("arrangement.onAir")
        } else if let headline = dj.headline, !headline.isEmpty {
            Text(headline)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: CGFloat(ArrangementPaneLayout.hitTarget), alignment: .leading)
                .accessibilityLabel(dj.accessibilityLabel.isEmpty ? headline : dj.accessibilityLabel)
                .accessibilityIdentifier("arrangement.status")
        }
    }

    private var stationChip: some View {
        let caption = heading.playing?.id == heading.opened.id ? "Playing from" : "Station"
        return Button(action: onQueue) {
            HStack(spacing: 10) {
                StationArtwork(style: .station(heading.opened), size: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(FoldedStyle.tertiaryInk)
                    Text(heading.opened.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: CGFloat(ArrangementPaneLayout.hitTarget), alignment: .leading)
            .foldedGlass(Capsule(), role: .control)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(caption) \(heading.opened.name)")
        .accessibilityIdentifier("station.title")
    }

    private var chrome: some View {
        HStack(spacing: 8) {
            symbolButton(systemImage: "chevron.backward", label: "Back",
                         hint: "Returns to your stations", identifier: "folded.back") { dismiss() }
            Menu {
                Button(action: onConnections) {
                    Label("Connections", systemImage: "link")
                }
                .accessibilityIdentifier("more.connections")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .foldedGlass(Circle(), role: .control)
                    .contentShape(Circle())
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("folded.more")
            symbolButton(systemImage: "list.bullet",
                         label: snapshot.upNext.first.map { "Up next: \($0.title) by \($0.artistName)" } ?? "Up next: nothing queued",
                         hint: "Opens the queue", identifier: "queue.affordance", action: onQueue)
            symbolButton(systemImage: "slider.horizontal.3", label: "Tune station",
                         hint: "Opens the tuner. Music continues.", identifier: "transport.tune", action: onTune)
        }
        .frame(minHeight: CGFloat(ArrangementPaneLayout.hitTarget))
    }

    private func symbolButton(systemImage: String, label: String, hint: String, identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .foldedGlass(Circle(), role: .control)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Secondary (up next)

    private var timeline: some View {
        let rows = lines
        return VStack(alignment: .leading, spacing: 8) {
            Text("Up next")
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Button(action: onQueue) {
                VStack(alignment: .leading, spacing: 6) {
                    if rows.isEmpty {
                        Text("Nothing queued")
                            .font(.subheadline)
                            .foregroundStyle(FoldedStyle.secondaryInk)
                            .frame(maxWidth: .infinity, minHeight: CGFloat(ArrangementPaneLayout.hitTarget), alignment: .leading)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, line in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(line.title)
                                    .font(.subheadline.weight(line.role == .nowPlaying ? .semibold : .regular))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !line.detail.isEmpty {
                                    Text(line.detail)
                                        .font(.caption)
                                        .foregroundStyle(FoldedStyle.secondaryInk)
                                        .lineLimit(1)
                                }
                            }
                            .accessibilityIdentifier("arrangement.upNext.\(line.role.rawValue)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: CGFloat(ArrangementPaneLayout.hitTarget), alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foldedGlass(RoundedRectangle(cornerRadius: FoldedStyle.fieldRadius, style: .continuous), role: .surface)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(timelineLabel(rows))
            .accessibilityHint("Opens the queue")
            .accessibilityIdentifier("arrangement.upNext")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lines: [DuoUpNextTimeline.Line] {
        guard let track = heroTrack else { return [] }
        let readyBreak: String?
        if case .ready = dj.state {
            readyBreak = dj.headline
        } else {
            readyBreak = nil
        }
        return DuoUpNextTimeline.lines(
            now: .init(title: track.title, artist: track.artistName),
            readyBreak: readyBreak,
            queued: snapshot.upNext.map { .init(title: $0.title, artist: $0.artistName) })
    }

    private func timelineLabel(_ rows: [DuoUpNextTimeline.Line]) -> String {
        if rows.isEmpty { return "Up next, nothing queued" }
        return rows.map { $0.detail.isEmpty ? $0.title : "\($0.title), \($0.detail)" }.joined(separator: ". ")
    }

    private var heroTrack: TrackInfo? {
        if case .track(let track) = content { return track }
        return nil
    }

    private var showsProgress: Bool {
        guard content.showsTransport, let timeSource else { return false }
        return timeSource.duration().map { $0 > 0 } ?? false
    }
}

#if compiler(>=6.4.2)
@available(iOS 27.1, *)
private extension ArrangementListenPlayer {
    /// System split. The axis matches `ArrangementPaneLayout`, so a tall container
    /// keeps the timeline on screen instead of dropping it.
    @ViewBuilder
    func systemSplit(_ metrics: ArrangementPaneLayout.Metrics) -> some View {
        let share = CGFloat(ArrangementPaneLayout.primaryShare)
        switch metrics.axis {
        case .horizontal:
            ArrangementView {
                primary
                    .splitArrangementLayoutRatio(share)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("arrangement.primary")
                    .accessibilityLabel("Now playing")
            } secondary: {
                timeline
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("arrangement.secondary")
                    .accessibilityLabel("Up next")
            }
            .arrangementViewStyle(.split.axes(.horizontal))
        case .vertical:
            ArrangementView {
                primary
                    .splitArrangementLayoutRatio(share)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("arrangement.primary")
                    .accessibilityLabel("Now playing")
            } secondary: {
                timeline
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("arrangement.secondary")
                    .accessibilityLabel("Up next")
            }
            .arrangementViewStyle(.split.axes(.vertical))
        }
    }
}
#endif
