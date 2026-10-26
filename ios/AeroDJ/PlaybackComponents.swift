import AeroDJCore
import SwiftUI

/// Shared leaf views for both layouts (ui-contract.md §11). Each renders values and sends
/// intents; none owns a service. The rules they render (what may show, which buttons are
/// real) live in AeroDJCore's `StudioScreenPresentation.swift` and are unit tested there.
///
/// Originally written by Claudio (#60); taken over and revised by Fry.

// MARK: - Surfaces

/// Restrained Liquid Glass on iOS 26+, a material before that, and an opaque grouped
/// background when Reduce Transparency is on. Used for the transport bar and the two
/// Studio zones only; content itself is never glass.
struct StudioSurface: ViewModifier {
    var cornerRadius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(.secondarySystemBackground), in: shape)
        } else {
            glass(content, shape: shape)
        }
    }

    @ViewBuilder
    private func glass(_ content: Content, shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
        #else
        content.background(.regularMaterial, in: shape)
        #endif
    }
}

extension View {
    func studioSurface(cornerRadius: CGFloat = 24) -> some View {
        modifier(StudioSurface(cornerRadius: cornerRadius))
    }
}

/// Full-bleed background: the artwork, heavily blurred, over a station-tinted gradient.
/// Decorative only, hidden from VoiceOver. Solid when Reduce Transparency is on.
struct StationBackdrop: View {
    let artworkURL: URL?
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.08), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
            if !reduceTransparency, let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill().blur(radius: 60).opacity(0.35)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// A stable tint per station, so the room keeps its colour across fold and relaunch.
    static func tint(for station: StationRef?) -> Color {
        let palette: [Color] = [.indigo, .teal, .orange, .pink, .purple, .mint, .blue]
        let key = station?.id ?? "aerodj"
        let index = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff } % palette.count
        return palette[index]
    }
}

// MARK: - ArtworkView

/// Square artwork at a size the container decides. The placeholder is a tinted tile with
/// a music note, never a spinner.
struct ArtworkView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 160 ? 22 : 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: size > 160 ? 24 : 8, y: 10)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.thinMaterial)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.28, weight: .medium))
                    .foregroundStyle(.secondary)
            )
    }
}

// MARK: - DJ status

/// The DJ line. Renders `DJStatusPresentation` only: "On Air" only while the player has
/// confirmed DJ audio (`studio.djState`), no caption or transcript, and nothing at all
/// when the DJ is idle.
struct DJStatusLine: View {
    let presentation: DJStatusPresentation
    var onReview: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let count = presentation.reviewCount {
            Button {
                onReview?()
            } label: {
                Label("\(count) to review", systemImage: "exclamationmark.bubble")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Opens Connections to review shared items. Music continues.")
        } else if let headline = presentation.headline {
            HStack(spacing: 8) {
                if let badge = presentation.onAirBadge {
                    OnAirBadge(text: badge, pulses: presentation.animatesActivity && !reduceMotion)
                } else {
                    Image(systemName: icon).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text(headline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(presentation.onAirBadge == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
        }
    }

    private var icon: String {
        switch presentation.state {
        case .preparing: "hourglass"
        case .ready: "clock"
        case .failed: "speaker.slash"
        case .idle, .speaking: "waveform"
        }
    }
}

/// "ON AIR": system red with a text label, never colour alone. Pulses only while the DJ is
/// actually speaking and Reduce Motion is off.
struct OnAirBadge: View {
    let text: String
    let pulses: Bool
    @State private var dim = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.white).frame(width: 6, height: 6).opacity(dim ? 0.35 : 1)
            Text(text.uppercased()).font(.caption.weight(.heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.red))
        .onAppear {
            guard pulses else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

// MARK: - TransportRow

/// Play/Pause (64 pt) and Skip (44 pt minimum). Haptics fire only on the user's own taps,
/// via a counter bumped inside the button actions, never on a snapshot or DJ change.
struct TransportRow: View {
    let transport: TransportState
    let actions: PlaybackActions
    @State private var taps = 0

    var body: some View {
        HStack(spacing: 36) {
            Button {
                taps += 1
                if transport == .playing { actions.pause() } else { Task { await actions.resume() } }
            } label: {
                Label(transport == .playing ? "Pause" : "Play",
                      systemImage: transport == .playing ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }
            .accessibilityIdentifier("transport.playPause")

            Button {
                taps += 1
                Task { await actions.skip() }
            } label: {
                Label("Skip", systemImage: "forward.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .accessibilityIdentifier("transport.skip")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }
}

// MARK: - QueueAffordance

/// "Up next: <first title>" with a chevron. Opens the workspace on its Queue segment.
struct QueueAffordance: View {
    let upNext: [TrackInfo]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Up next: \(upNext.first?.title ?? "nothing queued")")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the queue, tuner and connections")
        .accessibilityIdentifier("queue.affordance")
    }
}

// MARK: - PlaybackErrorBanner

/// Renders `PlaybackErrorPresentation` (ui-contract.md §9). Every button calls a real
/// action: Allow → Apple Music permission, Try again → resume then dismiss.
struct PlaybackErrorBanner: View {
    let error: PlaybackError?
    let actions: PlaybackActions

    var body: some View {
        if let p = PlaybackErrorPresentation(error) {
            switch p.style {
            case .caption:
                Label(p.title, systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .banner:
                VStack(alignment: .leading, spacing: 10) {
                    Label(p.title, systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        if let action = p.primary, let title = p.primaryTitle {
                            Button(title) { perform(action) }
                                .buttonStyle(.borderedProminent)
                        }
                        if p.dismissible {
                            Button("Dismiss") { actions.dismissError() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .studioSurface(cornerRadius: 16)
            }
        }
    }

    private func perform(_ action: PlaybackErrorAction) {
        switch action {
        case .requestAuthorization:
            Task { await actions.authorize() }
        case .retry:
            Task {
                await actions.resume()
                actions.dismissError()
            }
        case .dismiss:
            actions.dismissError()
        }
    }
}

// MARK: - Access / empty states

/// Shown instead of a track when there is nothing the transport could control.
struct NowPlayingPlaceholder: View {
    let content: NowPlayingContent
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 10) {
            if content == .connecting {
                ProgressView().accessibilityHidden(true)
            }
            Text(content.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let detail = content.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if content == .accessDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Start listening (real Apple Music search)

/// Search Apple Music and play a result. Playing replaces the current queue with the
/// chosen song and the results after it, so the station has more than one song.
struct StartListeningView: View {
    let search: MusicSearch
    @Binding var query: String
    @State private var results: [TrackInfo] = []
    @State private var phase: Phase = .idle

    enum Phase: Equatable { case idle, searching, failed(String), empty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search Apple Music", text: $query)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit(runSearch)
                    .accessibilityIdentifier("search.field")
            }
            .padding(12)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            switch phase {
            case .idle: EmptyView()
            case .searching: ProgressView("Searching Apple Music")
            case .failed(let message): Text(message).font(.caption).foregroundStyle(.secondary)
            case .empty: Text("No songs found.").font(.caption).foregroundStyle(.secondary)
            }

            if !results.isEmpty {
                Text("Playing a song replaces the queue with it and the songs after it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(results.enumerated()), id: \.element.id) { index, track in
                    Button {
                        Task {
                            do { try await search.play(results, index) } catch {
                                phase = .failed("Couldn't start that song. Try another.")
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: track.artworkURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.subheadline).lineLimit(1)
                                Text(track.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(track.title) by \(track.artistName)")
                }
            }
        }
    }

    private func runSearch() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        phase = .searching
        Task {
            do {
                results = try await search.search(term)
                phase = results.isEmpty ? .empty : .idle
            } catch {
                results = []
                phase = .failed("Apple Music search isn't available right now.")
            }
        }
    }
}

// MARK: - Previews

#Preview("DJ states") {
    VStack(alignment: .leading, spacing: 20) {
        DJStatusLine(presentation: .init(state: .preparing(includesBriefing: false)))
        DJStatusLine(presentation: .init(state: .ready(includesBriefing: true, seconds: 40)))
        DJStatusLine(presentation: .init(state: .speaking(includesBriefing: false)))
        DJStatusLine(presentation: .init(state: .failed(.voiceFailed)))
        DJStatusLine(presentation: .init(state: .failed(.consentReviewRequired(pendingCount: 2))))
    }
    .padding()
}

#Preview("Errors") {
    VStack(spacing: 16) {
        PlaybackErrorBanner(error: PlaybackError(kind: .notAuthorized, message: "", isRecoverable: false), actions: .preview)
        PlaybackErrorBanner(error: PlaybackError(kind: .playbackFailed, message: "Playback stopped.", isRecoverable: true),
                            actions: .preview)
        PlaybackErrorBanner(error: PlaybackFixtures.recoverableError.error, actions: .preview)
    }
    .padding()
}
