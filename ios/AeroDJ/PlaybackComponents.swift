import AeroDJCore
import SwiftUI
import OSLog

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
private struct OnSlabKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var artStation: StationRef? {
        get { self[ArtStationKey.self] }
        set { self[ArtStationKey.self] = newValue }
    }

    /// True for views drawn on the warm-black Now Playing slab, so type does not use the
    /// panel colours (those are for light surfaces in light mode).
    var onSlab: Bool {
        get { self[OnSlabKey.self] }
        set { self[OnSlabKey.self] = newValue }
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
            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(size > 160 ? 0.22 : 0.12), radius: size > 160 ? 28 : 6, y: size > 160 ? 14 : 3)
        .accessibilityHidden(true)
    }

    private var cornerRadius: CGFloat { size > 160 ? 26 : max(8, size * 0.2) }

    private var fallback: some View {
        StationArtwork(style: .track(track, on: station), size: size,
                       caption: size >= 200 ? station?.name : nil)
    }
}

/// Generated cover: gradient, an accent glow, concentric radio rings and a monogram.
/// Never a network request or an image asset. The same pixels in light and dark.
struct StationArtwork: View {
    let style: StationArtStyle
    let size: CGFloat
    var caption: String?

    var body: some View {
        let base = AeroDJPalette.backing(forLightText: style.color(0))
        let deep = AeroDJPalette.backing(forLightText: style.color(1))
        ZStack {
            LinearGradient(colors: [base, deep],
                           startPoint: style.startPoint, endPoint: style.endPoint)
            RadialGradient(colors: [style.color(2).opacity(0.55), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: size * 0.95)
            ForEach(1...max(1, style.rings), id: \.self) { ring in
                Circle()
                    .strokeBorder(AeroDJPalette.onMediaLight.opacity(0.08 + 0.05 * Double(style.rings - ring + 1)),
                                  lineWidth: max(0.75, size * 0.008))
                    .frame(width: size * (0.38 + 0.26 * Double(ring)), height: size * (0.38 + 0.26 * Double(ring)))
            }
            Text(style.monogram)
                .font(.system(size: size * 0.30, weight: .heavy, design: .rounded))
                .foregroundStyle(AeroDJPalette.onMediaLight)
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
                    .foregroundStyle(AeroDJPalette.onMediaLight)
                }
                .padding(size * 0.07)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Hero artwork for Listen and Studio. Edge to edge, corner radius 0. Album art when the
/// current track has it; otherwise the station ident. Dark mode does not tint, dim, or blur it.
struct BleedArtwork: View {
    static let morphID = "bleed-art"
    let track: TrackInfo?
    let station: StationRef?

    var body: some View {
        GeometryReader { geo in
            let column = geo.size.width
            ZStack {
                if let track, let url = track.artworkURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                        } else {
                            fittedIdent(.track(track, on: station), width: column)
                        }
                    }
                } else if let track {
                    fittedIdent(.track(track, on: station), width: column)
                } else {
                    fittedIdent(.station(station), width: column)
                }
            }
            .frame(width: column, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .accessibilityHidden(true)
    }

    /// The ident is a square. Fit it to the column width so its frame cannot cross the gutter.
    private func fittedIdent(_ style: StationArtStyle, width: CGFloat) -> some View {
        StationArtwork(style: style, size: width)
            .aspectRatio(1, contentMode: .fit)
            .frame(width: width)
    }
}

struct BleedArtFrame: ViewModifier {
    var namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: BleedArtwork.morphID, in: namespace)
        } else {
            content
        }
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
                .foregroundStyle(AeroDJPalette.onMediaLight)
                .lineLimit(1)
                .truncationMode(.tail)
            if isTestStation {
                Text("TEST STATION")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().strokeBorder(AeroDJPalette.slabSecondary))
                    .foregroundStyle(AeroDJPalette.slabSecondary)
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
            .toolbarBackground(AeroDJPalette.slab, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { StationTitle(station: station, isTestStation: isTestStation) }
            }
    }
}

// MARK: - DJ status

/// The DJ line. Renders `DJStatusPresentation` headlines for preparing and failed.
/// Every `.ready` draws nothing, the same as idle: the core still has a headline
/// ("DJ break after this song" / "Briefing after this song") and a VoiceOver detail
/// ("… ready for after this song"), and either can stay up when no break plays.
/// Speaking draws no badge.
struct DJStatusLine: View {
    let presentation: DJStatusPresentation
    var onReview: (() -> Void)?

    var body: some View {
        if isReady {
            EmptyView()
        } else if let count = presentation.reviewCount {
            Button {
                onReview?()
            } label: {
                Label("\(count) to review", systemImage: "exclamationmark.bubble")
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.bordered)
            .tint(AeroDJPalette.onMediaLight)
            .accessibilityHint("Opens Connections to review shared items. Music continues.")
        } else if let headline = presentation.headline, presentation.onAirBadge == nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(AeroDJPalette.slabSecondary)
                    .accessibilityHidden(true)
                Text(headline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AeroDJPalette.slabSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
        }
    }

    /// `.ready` is omitted entirely, so VoiceOver gets the same silence as idle.
    private var isReady: Bool {
        if case .ready = presentation.state { return true }
        return false
    }

    private var icon: String {
        switch presentation.state {
        case .preparing: "hourglass"
        case .ready: "clock"
        case .failed: "speaker.slash"
        case .idle, .speaking: "music.note"
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
    var onTune: (() -> Void)?
    @State private var taps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .foregroundStyle(AeroDJPalette.onMediaLight)
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
                    .foregroundStyle(AeroDJPalette.onMediaInk)
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(AeroDJPalette.onMediaLight))
                    .contentShape(Circle())
                    .modifier(SymbolReplace(enabled: !reduceMotion))
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
                .foregroundStyle(AeroDJPalette.onMediaLight)
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
            HStack(alignment: .center, spacing: 10) {
                if let next = upNext.first {
                    ArtworkView(track: next, size: 36)
                } else {
                    Image(systemName: "list.bullet")
                        .frame(width: 36, height: 36)
                        .foregroundStyle(AeroDJPalette.slabSecondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("UP NEXT")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(AeroDJPalette.slabSecondary)
                    Text(upNext.first.map { "\($0.title) · \($0.artistName)" } ?? "Nothing queued")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AeroDJPalette.onMediaLight)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if upNext.count > 1 {
                    Text("+\(upNext.count - 1)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(AeroDJPalette.slabSecondary)
                }
                Image(systemName: "chevron.up").font(.subheadline.weight(.semibold))
                    .foregroundStyle(AeroDJPalette.onMediaLight)
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
                    .foregroundStyle(AeroDJPalette.slabSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                ProgressView()
                    .tint(AeroDJPalette.onMediaLight)
                    .accessibilityHidden(true)
            }
            Text(content.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AeroDJPalette.onMediaLight)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = content.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AeroDJPalette.slabSecondary)
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
    @Environment(\.onSlab) private var onSlab
    @State private var results: [TrackInfo] = []
    @State private var phase: Phase = .idle

    private var ink: Color { onSlab ? AeroDJPalette.onMediaLight : Color.primary }
    private var secondaryInk: Color { onSlab ? AeroDJPalette.slabSecondary : AeroDJPalette.secondaryText }

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
            case .failed(let message): Text(message).font(.caption).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true)
            case .empty: Text("No songs found.").font(.caption).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true)
            }

            if !results.isEmpty {
                Text("Playing a song replaces the queue with it and the songs after it.")
                    .font(.caption)
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
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
                                Text(track.title).font(.subheadline).foregroundStyle(ink).lineLimit(1)
                                Text(track.artistName).font(.caption).foregroundStyle(secondaryInk).lineLimit(1)
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

    /// TEMPORARY diagnostic for device builds (remove once the search failure's cause is
    /// known): shows the error's type, code and localizedDescription instead of a generic line.
    /// Never debugDescription, the underlying-error chain, a request URL or the query, which
    /// can carry storefront or token details.
    static func searchFailureMessage(_ error: Error) -> String {
        let typeName = String(describing: type(of: error))
        let code = (error as NSError).code
        let text = error.localizedDescription
        searchLog.error("Apple Music search failed: \(typeName, privacy: .public) code \(code, privacy: .public): \(text, privacy: .public)")
        return "Apple Music search failed: \(typeName) code \(code). \(text)"
    }

    private static let searchLog = Logger(subsystem: "com.aerodj.app", category: "search")

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
                phase = .failed(Self.searchFailureMessage(error))
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
    .background(AeroDJPalette.slab)
}

#Preview("Errors") {
    VStack(spacing: 16) {
        PlaybackErrorBanner(error: PlaybackError(kind: .notAuthorized, message: "", isRecoverable: false), actions: .preview)
        PlaybackErrorBanner(error: PlaybackError(kind: .playbackFailed, message: "Playback stopped.", isRecoverable: true),
                            actions: .preview)
        PlaybackErrorBanner(error: PlaybackFixtures.recoverableError.error, actions: .preview)
    }
    .padding()
    .background(AeroDJPalette.slab)
}

private struct SymbolReplace: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}
