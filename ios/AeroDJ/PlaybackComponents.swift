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

/// The station whose colours the fallback art and backdrop use. Set once by `PlayingScreen`
/// (and again on the compact sheet), read by every `ArtworkView` below it.
private struct ArtStationKey: EnvironmentKey { static let defaultValue: StationRef? = nil }

extension EnvironmentValues {
    var artStation: StationRef? {
        get { self[ArtStationKey.self] }
        set { self[ArtStationKey.self] = newValue }
    }
}

extension StationArtStyle {
    /// 0 = base, 1 = deeper neighbour, 2 = softer accent.
    func color(_ index: Int) -> Color {
        switch index {
        case 1: Color(hue: hues[1], saturation: min(1, saturation + 0.1), brightness: brightness * 0.72)
        case 2: Color(hue: hues[2], saturation: saturation * 0.75, brightness: min(1, brightness + 0.1))
        default: Color(hue: hues[0], saturation: saturation, brightness: brightness)
        }
    }

    var startPoint: UnitPoint {
        let r = Double(angle) * .pi / 180
        return UnitPoint(x: 0.5 - cos(r) / 2, y: 0.5 - sin(r) / 2)
    }

    var endPoint: UnitPoint {
        let r = Double(angle) * .pi / 180
        return UnitPoint(x: 0.5 + cos(r) / 2, y: 0.5 + sin(r) / 2)
    }
}

/// Full-bleed atmosphere: a wash in the current track's station colours (or the station's
/// own when nothing plays), with the real artwork blurred over it when there is one.
/// Decorative only, hidden from VoiceOver. Solid when Reduce Transparency is on.
struct StationBackdrop: View {
    let artworkURL: URL?
    let style: StationArtStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Color(.systemBackground)
            if !reduceTransparency {
                LinearGradient(colors: [style.color(0).opacity(dark ? 0.55 : 0.40),
                                        style.color(1).opacity(dark ? 0.28 : 0.14),
                                        Color(.systemBackground).opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [style.color(2).opacity(dark ? 0.20 : 0.16), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: 700)
                if let artworkURL {
                    AsyncImage(url: artworkURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill().blur(radius: 70).opacity(dark ? 0.30 : 0.35)
                        }
                    }
                }
            } else {
                style.color(0).opacity(dark ? 0.25 : 0.12)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: style)
        .accessibilityHidden(true)
    }
}

// MARK: - Artwork

/// Square artwork at a size the container decides. Without album art (or while it loads,
/// or if it fails) the song gets generated station art: a gradient in the station's colours,
/// radio rings and the song's monogram. Deterministic and offline (`StationArtStyle`).
struct ArtworkView: View {
    let track: TrackInfo
    let size: CGFloat
    @Environment(\.artStation) private var station

    var body: some View {
        Group {
            if let url = track.artworkURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(size > 160 ? 0.22 : 0.12), radius: size > 160 ? 28 : 6, y: size > 160 ? 14 : 3)
        .accessibilityHidden(true)
    }

    private var cornerRadius: CGFloat { size > 160 ? 26 : max(8, size * 0.2) }

    private var fallback: some View {
        StationArtwork(style: .track(track, on: station), size: size,
                       caption: size >= 200 ? station?.name : nil)
    }
}

/// Generated cover: gradient, an accent glow, concentric "on air" rings and a monogram.
/// Never a network request or an image asset.
struct StationArtwork: View {
    let style: StationArtStyle
    let size: CGFloat
    var caption: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [style.color(0), style.color(1)],
                           startPoint: style.startPoint, endPoint: style.endPoint)
            RadialGradient(colors: [style.color(2).opacity(0.55), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: size * 0.95)
            ForEach(1...max(1, style.rings), id: \.self) { ring in
                Circle()
                    .strokeBorder(.white.opacity(0.08 + 0.05 * Double(style.rings - ring + 1)),
                                  lineWidth: max(0.75, size * 0.008))
                    .frame(width: size * (0.38 + 0.26 * Double(ring)), height: size * (0.38 + 0.26 * Double(ring)))
            }
            Text(style.monogram)
                .font(.system(size: size * 0.30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(size * 0.12)
                .shadow(color: .black.opacity(0.22), radius: size * 0.03, y: size * 0.012)
            if let caption {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(caption.uppercased()).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: max(10, size * 0.042), weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.85))
                }
                .padding(size * 0.07)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Station identity for the navigation bar: a small station-art tile, the station name and,
/// in the debug fixture mode, a TEST STATION tag so a screenshot can't be mistaken for a
/// listener's real station.
struct StationTitle: View {
    let station: StationRef
    let isTestStation: Bool

    var body: some View {
        HStack(spacing: 8) {
            StationArtwork(style: .station(station), size: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(station.name)
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("station.title")
    }
}

extension View {
    /// Replaces the plain navigation title with `StationTitle`; the title string stays for
    /// the back button and VoiceOver.
    func stationToolbar(_ station: StationRef, isTestStation: Bool) -> some View {
        navigationTitle(station.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { StationTitle(station: station, isTestStation: isTestStation) }
            }
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

/// Tune (opens the tuner), Play/Pause (64 pt, filled in the station colour) and Skip.
/// Haptics fire only on the user's own taps, via a counter bumped inside the button
/// actions, never on a snapshot or DJ change.
struct TransportRow: View {
    let transport: TransportState
    let actions: PlaybackActions
    let accent: Color
    var onTune: (() -> Void)?
    @State private var taps = 0

    var body: some View {
        HStack(spacing: 0) {
            side {
                if let onTune {
                    Button {
                        taps += 1
                        onTune()
                    } label: {
                        Label("Tune station", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 52, height: 52)
                            .contentShape(Circle())
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Opens the tuner. Music continues.")
                    .accessibilityIdentifier("transport.tune")
                }
            }

            Button {
                taps += 1
                if transport == .playing { actions.pause() } else { Task { await actions.resume() } }
            } label: {
                Label(transport == .playing ? "Pause" : "Play",
                      systemImage: transport == .playing ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(accent.gradient))
                    .shadow(color: accent.opacity(0.35), radius: 10, y: 4)
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityIdentifier("transport.playPause")

            side {
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
                .foregroundStyle(.primary)
                .accessibilityIdentifier("transport.skip")
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }

    private func side<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(maxWidth: .infinity)
    }
}

// MARK: - Up next

/// The next song as a small card (art, "Up next", title — artist). Opens the workspace on
/// its Queue segment.
struct QueueAffordance: View {
    let upNext: [TrackInfo]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let next = upNext.first {
                    ArtworkView(track: next, size: 36)
                } else {
                    Image(systemName: "list.bullet")
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("UP NEXT")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Text(upNext.first.map { "\($0.title) · \($0.artistName)" } ?? "Nothing queued")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if upNext.count > 1 {
                    Text("+\(upNext.count - 1)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(upNext.first.map { "Up next: \($0.title) by \($0.artistName)" } ?? "Up next: nothing queued")
        .accessibilityHint("Opens the queue, tuner and connections")
        .accessibilityAddTraits(.isButton)
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
                            ArtworkView(track: track, size: 44)
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
