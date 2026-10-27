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

    /// System material for the transport inset and Zone B. Opaque when Reduce Transparency is on.
    func systemMaterialBackground() -> some View {
        modifier(SystemMaterialBackground())
    }
}

private struct SystemMaterialBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(.secondarySystemBackground))
        } else {
            content.background(.regularMaterial)
        }
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
///
/// The layout frame is `Color.clear`. `scaledToFill` lives in an overlay, so its larger
/// ideal size cannot widen the zone. The title already names the song, so the image is hidden.
struct BleedArtwork: View {
    static let morphID = "bleed-art"
    let track: TrackInfo?
    let station: StationRef?

    var body: some View {
        Color.clear
            .overlay { canvas }
            .clipped()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var canvas: some View {
        if let track, let url = track.artworkURL {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                        .accessibilityHidden(true)
                } else {
                    fittedIdent(.track(track, on: station))
                }
            }
        } else if let track {
            fittedIdent(.track(track, on: station))
        } else {
            fittedIdent(.station(station))
        }
    }

    /// The ident is a square. It is sized from the overlay's own bounds, so it cannot
    /// push the zone past the gutter.
    private func fittedIdent(_ style: StationArtStyle) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            StationArtwork(style: style, size: max(side, 1))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .accessibilityHidden(true)
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
    @Environment(\.onSlab) private var onSlab

    private var ink: Color { onSlab ? AeroDJPalette.onMediaLight : Color.primary }
    private var secondaryInk: Color { onSlab ? AeroDJPalette.slabSecondary : Color.secondary }

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
            .tint(ink)
            .accessibilityHint("Opens Connections to review shared items. Music continues.")
        } else if let headline = presentation.headline, presentation.onAirBadge == nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(secondaryInk)
                    .accessibilityHidden(true)
                Text(headline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(secondaryInk)
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
    /// `PlaybackSnapshot.startTimedOut`: the `.preparing` start passed its 8 s deadline.
    var startTimedOut: Bool = false
    let actions: PlaybackActions
    var onTune: (() -> Void)?
    @State private var taps = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        #if DEBUG
        systemReduceMotion || UserDefaults.standard.bool(forKey: StudioCapture.reduceMotionKey)
        #else
        systemReduceMotion
        #endif
    }
    @Environment(\.onSlab) private var onSlab

    private var ink: Color { onSlab ? AeroDJPalette.onMediaLight : Color.primary }

    private var face: TransportButtonFace {
        TransportTapPolicy.face(transport: transport, startTimedOut: startTimedOut)
    }

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
                    .foregroundStyle(ink)
                    .accessibilityHint("Opens the tuner. Music continues.")
                    .accessibilityIdentifier("transport.tune")
                }
            }

            Button {
                // Build 9 P0 (-Atlas; Orion, Nova, Sentinel): `TransportTapPolicy` decides. A second
                // tap while a start is preparing does nothing until its 8 s deadline is reported;
                // after that the button is Stop and cancels the start as a user pause.
                switch TransportTapPolicy.decide(transport: transport, startTimedOut: startTimedOut) {
                case .ignore:
                    actions.transportTapIgnored()
                case .cancelStart:
                    taps += 1
                    actions.cancelStart()
                case .pause:
                    taps += 1
                    actions.pause()
                case .play:
                    taps += 1
                    Task { await actions.resume() }
                }
            } label: {
                Group {
                    if let systemImage = face.systemImage {
                        Label(face.accessibilityLabel, systemImage: systemImage)
                            .labelStyle(.iconOnly)
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(AeroDJPalette.onMediaInk)
                            .accessibilityLabel(face.accessibilityLabel)
                    }
                }
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(AeroDJPalette.onMediaInk)
                .frame(width: 68, height: 68)
                .background(Circle().fill(AeroDJPalette.onMediaLight))
                .contentShape(Circle())
                .modifier(SymbolReplace(enabled: !reduceMotion))
            }
            // Nova: while starting, VoiceOver reads "Starting playback" with no button trait.
            // Not `.disabled`, so nothing dims; a tap that still arrives is ignored above.
            .accessibilityLabel(face.accessibilityLabel)
            .accessibilityRemoveTraits(face.isActionable ? [] : .isButton)
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
                .foregroundStyle(ink)
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
    @Environment(\.onSlab) private var onSlab

    private var ink: Color { onSlab ? AeroDJPalette.onMediaLight : Color.primary }
    private var secondaryInk: Color { onSlab ? AeroDJPalette.slabSecondary : Color.secondary }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                if let next = upNext.first {
                    ArtworkView(track: next, size: 36)
                } else {
                    Image(systemName: "list.bullet")
                        .frame(width: 36, height: 36)
                        .foregroundStyle(secondaryInk)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("UP NEXT")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(secondaryInk)
                    Text(upNext.first.map { "\($0.title) · \($0.artistName)" } ?? "Nothing queued")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if upNext.count > 1 {
                    Text("+\(upNext.count - 1)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(secondaryInk)
                }
                Image(systemName: "chevron.up").font(.subheadline.weight(.semibold))
                    .foregroundStyle(ink)
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
    @Environment(\.onSlab) private var onSlab

    var body: some View {
        if let p = PlaybackErrorPresentation(error) {
            switch p.style {
            case .caption:
                Label(p.title, systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(onSlab ? AeroDJPalette.slabSecondary : Color.secondary)
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
    /// Required for `.needsAuthorization` so Allow calls `authorize()`, never a no-op.
    var actions: PlaybackActions? = nil
    @Environment(\.openURL) private var openURL

    @Environment(\.onSlab) private var onSlab

    private var ink: Color { onSlab ? AeroDJPalette.onMediaLight : Color.primary }
    private var secondaryInk: Color { onSlab ? AeroDJPalette.slabSecondary : Color.secondary }

    var body: some View {
        VStack(spacing: 10) {
            if content == .connecting {
                ProgressView()
                    .tint(ink)
                    .accessibilityHidden(true)
            }
            Text(content.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = content.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if content == .needsAuthorization, let actions {
                Button("Allow Apple Music") {
                    Task { await actions.authorize() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("playback.allowMusic")
            }
            if content == .accessDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        // Keep Allow / Settings as their own elements so UI tests can find them.
        .accessibilityElement(children: (content == .needsAuthorization || content == .accessDenied) ? .contain : .combine)
    }
}

// MARK: - Start listening (real Apple Music search)

/// Search Apple Music and play a result. Playing replaces the current queue with the
/// chosen song and the results after it, so the station has more than one song.
/// Query and results live in `StudioSearchModel` so Listen and Studio share one path.
struct StartListeningView: View {
    let search: MusicSearch
    @ObservedObject var model: StudioSearchModel
    @Environment(\.onSlab) private var onSlab

    private var ink: Color { onSlab ? AeroDJPalette.onMediaLight : Color.primary }
    private var secondaryInk: Color { onSlab ? AeroDJPalette.slabSecondary : AeroDJPalette.secondaryText }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search Apple Music", text: queryBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { model.run(using: search) }
                    .accessibilityIdentifier("search.field")
                    .accessibilityValue(model.query)
                Button("Search") { model.run(using: search) }
                    .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || model.phase == .searching)
                    .accessibilityIdentifier("search.submit")
            }
            .padding(12)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            switch model.phase {
            case .idle: EmptyView()
            case .searching: ProgressView("Searching Apple Music")
            case .failed(let message): Text(message).font(.caption).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true)
            case .empty: Text("No songs found.").font(.caption).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true)
            }

            if !model.results.isEmpty {
                Text("Playing a song replaces the queue with it and the songs after it.")
                    .font(.caption)
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, track in
                    Button {
                        Task {
                            do { try await search.play(model.results, index) } catch MusicKitError.superseded {
                                // Build 9 P0 (-Atlas): a newer tap owns the screen; nothing to show.
                            } catch {
                                model.phase = .failed(Self.playFailureMessage(error))
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
                        .accessibilityIdentifier("search.result.\(track.id)")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(track.title) by \(track.artistName)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.results")
    }

    private var queryBinding: Binding<String> {
        Binding(get: { model.query }, set: { model.updateQuery($0) })
    }

    /// TEMPORARY diagnostic for device builds (remove: #121): error type, NSError domain and
    /// code only (`PlaybackErrorCode`). Never localizedDescription, debugDescription, the
    /// underlying-error chain, request URLs, titles or search terms. From Atlas #109.
    static func playFailureMessage(_ error: Error) -> String {
        let code = PlaybackErrorCode(error)
        playLog.error("TEMPORARY Apple Music play failed: \(code.typeName, privacy: .public) \(code.domain, privacy: .public) code \(code.code, privacy: .public)")
        return "TEMPORARY: couldn't start playback: \(code)."
    }

    private static let playLog = Logger(subsystem: "com.aerodj.app", category: "playback")
}

// MARK: - Playback progress (display-only)

/// Read-only elapsed/duration for the scrubber. Closures so live can poll without publishing.
/// Seeking is not wired: `PlaybackActions` has no seek path yet.
/// `@MainActor` because live closures read `MusicKitService` (also main-actor).
@MainActor
struct PlaybackTimeSource {
    let elapsed: () -> TimeInterval
    let duration: () -> TimeInterval?
    /// Advance the tick only while this is true. Compare to `.playing` only; a future
    /// `.preparing` transport must not move the bar.
    let isPlaying: () -> Bool

#if DEBUG
    /// Capture/UI-test fixture: fixed 1:12 of 3:45. Debug/capture only — not in Release.
    static let fixture = PlaybackTimeSource(
        elapsed: { 72 },
        duration: { 225 },
        isPlaying: { true }
    )
#endif

    /// Live playhead from MusicKitService (read-only). TimelineView polls; no seek.
    static var live: PlaybackTimeSource {
        PlaybackTimeSource(
            elapsed: { MusicKitService.shared.playbackTime },
            duration: { MusicKitService.shared.currentDuration },
            isPlaying: { MusicKitService.shared.snapshot.transport == .playing }
        )
    }
}

/// Elapsed, remaining, and a display-only bar. Hidden when duration is nil.
struct PlaybackProgressBar: View {
    let time: PlaybackTimeSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: time.isPlaying() && !reduceMotion ? 1 : 3600)) { context in
            let _ = context.date
            let elapsed = max(0, time.elapsed())
            let duration = time.duration()
            if let duration, duration > 0 {
                let remaining = max(0, duration - elapsed)
                let fraction = min(1, elapsed / duration)
                VStack(spacing: 4) {
                    progress(fraction: fraction)
                    HStack {
                        Text(Self.format(elapsed))
                            .font(.caption.monospacedDigit())
                        Spacer(minLength: 0)
                        Text(Self.format(remaining))
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(Self.format(elapsed)) of \(Self.format(duration))")
                .accessibilityIdentifier("playback.progress")
            }
        }
    }

    @ViewBuilder
    private func progress(fraction: Double) -> some View {
        // Display-only: no seek binding. A Slider would imply dragging.
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: max(4, geo.size.width * fraction))
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = abs(total % 60)
        return "\(m):\(String(format: "%02d", s))"
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
