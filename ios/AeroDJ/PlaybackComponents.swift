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
                    break
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

    /// The search banner after a play tap failed (#109, #133). Fixed `PlaybackFailureCopy`:
    /// never localizedDescription, debugDescription, the underlying-error chain, request URLs,
    /// titles or search terms. The log keeps the NSError domain and code only.
    static func playFailureMessage(_ error: Error) -> String {
        let code = PlaybackErrorCode(error)
        playLog.error("Apple Music play failed: domain=\(code.domain, privacy: .public) code=\(code.code, privacy: .public)")
        if case MusicKitError.notAuthorized = error {
            return MusicKitError.notAuthorized.errorDescription ?? PlaybackFailureCopy.fallback
        }
        return PlaybackFailureCopy.bannerMessage(for: ThrownPlaybackFailure(error))
    }

    private static let playLog = Logger(subsystem: "com.aerodj.app", category: "playback")
}

// MARK: - Playback progress (display-only)

/// Read-only elapsed/duration for the scrubber. Closures so live can poll without publishing.
/// Seeking goes through `PlaybackScrubber.onSeek`, never through this type.
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

/// Elapsed, remaining, and the song scrubber. Hidden when duration is nil.
///
/// `transport` and `trackID` are plain values from the snapshot so SwiftUI reruns this body
/// when either changes. The timeline is keyed on them (`PlaybackProgressClock.Key`): the
/// period is fixed when a TimelineView is built, so a bar first drawn while paused would
/// otherwise keep its idle period after Play (frozen at 0:00, first song's duration).
/// Reduce Motion removes the fill and grow animations only; the clock still updates every second.
///
/// Scrubbing (owner, 7:40 PM). The rules live in AeroDJCore's `ScrubberState`: the bar shows
/// the finger's target while dragging (the clock fill is paused), `onSeek` runs once on
/// release and never during a drag, and the bar holds the target until playback catches up.
/// This view never touches playback state.
///
/// Inert until Atlas wires `PlaybackActions.seek(to:)` and `PlaybackSnapshot.canSeek`: with
/// `onSeek == nil` it is today's display-only bar (no thumb, no gesture, no adjustable
/// action, not dimmed). Wired with `canSeek == false` (DJ break, loading, non-seekable) it is
/// dimmed and the gesture is off.
struct PlaybackScrubber: View {
    typealias Seek = (TimeInterval) async -> Bool

    let time: PlaybackTimeSource
    let transport: TransportState
    let trackID: String?
    let canSeek: Bool
    let onSeek: Seek?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrub = ScrubberState()
    @State private var trackWidth: CGFloat = 0
    @State private var dragStarts = 0
    @State private var commits = 0
    @GestureState private var isTouching = false

    static let trackHeight: CGFloat = 4
    static let draggingTrackHeight: CGFloat = 10
    static let thumbSize: CGFloat = 12
    static let draggingThumbSize: CGFloat = 22
    static let unavailableHint = "Scrubbing unavailable during DJ break"

    private var isWired: Bool { onSeek != nil }
    private var isInteractive: Bool { isWired && canSeek }

    private var key: PlaybackProgressClock.Key {
        PlaybackProgressClock.Key(transport: transport, trackID: trackID)
    }

    var body: some View {
        // The gesture sits outside the TimelineView: `.id(key)` rebuilds the timeline on a
        // transport or track change, and a gesture inside it would be dropped mid-drag.
        TimelineView(.periodic(from: .now, by: PlaybackProgressClock.interval(for: key, reduceMotion: reduceMotion))) { context in
            let _ = context.date
            let snapshotPosition = max(0, time.elapsed())
            let duration = time.duration()
            if let duration, duration > 0 {
                let shown = scrub.displayedPosition(snapshotPosition: snapshotPosition, duration: duration, now: Self.now())
                bar(position: shown, duration: duration)
            }
        }
        .id(key)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { trackWidth = $0 })
        .opacity(isWired && !canSeek ? 0.5 : 1)
        .contentShape(isWired ? AnyShape(ScrubberHitShape()) : AnyShape(Rectangle()))
        .gesture(scrubGesture, including: isInteractive ? .all : .subviews)
        .sensoryFeedback(.selection, trigger: dragStarts)
        .sensoryFeedback(.selection, trigger: commits)
        .onAppear { scrub.trackChanged(to: trackID) }
        .onChange(of: trackID) { _, new in scrub.trackChanged(to: new) }
        .onChange(of: canSeek) { _, new in scrub.canSeekChanged(new) }
        .onChange(of: isTouching) { _, touching in
            // A cancelled drag never reaches onEnded. A normal release has already committed,
            // so this is a no-op then.
            guard !touching else { return }
            Task { @MainActor in scrub.cancelDrag() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playback.scrubber")
    }

    @ViewBuilder
    private func bar(position: TimeInterval, duration: TimeInterval) -> some View {
        let dragging = scrub.isDragging
        VStack(spacing: 4) {
            track(fraction: ScrubberState.fraction(position: position, duration: duration), dragging: dragging)
            HStack {
                Text(PlaybackTimeFormat.label(position))
                    .font(.caption.monospacedDigit())
                Spacer(minLength: 0)
                Text(PlaybackTimeFormat.remaining(position: position, duration: duration))
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(dragging ? .primary : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(PlaybackTimeFormat.accessibilityValue(position: position, duration: duration))
        .modifier(ScrubberAccessibility(isWired: isWired, canSeek: canSeek,
                                        step: { accessibilityStep($0) }))
        .accessibilityIdentifier("playback.progress")
    }

    @ViewBuilder
    private func track(fraction: Double, dragging: Bool) -> some View {
        let height = dragging ? Self.draggingTrackHeight : Self.trackHeight
        let thumb = dragging ? Self.draggingThumbSize : Self.thumbSize
        // The layout height stays the 4 pt of today's bar; the taller drag track and the
        // thumb draw in an overlay, so the chrome above and below never moves.
        Color.clear
            .frame(height: Self.trackHeight)
            .overlay {
                GeometryReader { geo in
                    let width = geo.size.width
                    ZStack(alignment: .leading) {
                        trackBackground
                        Capsule()
                            .fill(Color.primary.opacity(0.85))
                            .frame(width: max(height, width * fraction))
                            .animation(PlaybackProgressClock.animatesFill(reduceMotion: reduceMotion) && !dragging
                                       ? .linear(duration: 0.25) : nil, value: fraction)
                    }
                    .frame(width: width, height: height)
                    .position(x: width / 2, y: geo.size.height / 2)
                    .overlay {
                        if isWired {
                            Circle()
                                .fill(Color.white.opacity(dragging ? 0.55 : 0.95))
                                .scrubberGlass(Circle())
                                .shadow(color: .black.opacity(0.25), radius: dragging ? 4 : 1.5, y: 1)
                                .frame(width: thumb, height: thumb)
                                .position(x: min(max(0, width * fraction), width), y: geo.size.height / 2)
                        }
                    }
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: dragging)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trackBackground: some View {
        if isWired {
            Capsule()
                .fill(Color.secondary.opacity(0.2))
                .scrubberGlass(Capsule())
        } else {
            Capsule().fill(Color.secondary.opacity(0.25))
        }
    }

    // MARK: Interaction

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { value in
                guard let duration = time.duration() else { return }
                let target = ScrubberState.position(atX: value.location.x, width: trackWidth, duration: duration)
                if scrub.drag(to: target, duration: duration, canSeek: canSeek) {
                    dragStarts += 1
                }
            }
            .onEnded { _ in
                guard let target = scrub.endDrag(now: Self.now()) else { return }
                send(target, commitID: scrub.commitID)
            }
    }

    /// VoiceOver adjustable: ±15 s from what the bar shows, through the same commit path.
    private func accessibilityStep(_ delta: TimeInterval) {
        guard isInteractive, let duration = time.duration(), duration > 0 else { return }
        let now = Self.now()
        let current = scrub.displayedPosition(snapshotPosition: max(0, time.elapsed()), duration: duration, now: now)
        let target = scrub.commit(current + delta, duration: duration, now: now)
        send(target, commitID: scrub.commitID)
    }

    /// The one seek per release. A false result goes straight back to the snapshot.
    private func send(_ target: TimeInterval, commitID: Int) {
        commits += 1
        guard let onSeek else {
            scrub.seekFinished(commitID: commitID, succeeded: false)
            return
        }
        Task { @MainActor in
            let succeeded = await onSeek(target)
            scrub.seekFinished(commitID: commitID, succeeded: succeeded)
            guard succeeded else { return }
            try? await Task.sleep(for: .seconds(ScrubberState.holdTimeout))
            scrub.settle(snapshotPosition: max(0, time.elapsed()), now: Self.now())
        }
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// At least 44 pt tall for touch while the visible track stays thin: reaches 12 pt above the
/// track and below the time labels.
private struct ScrubberHitShape: Shape {
    func path(in rect: CGRect) -> Path {
        let height = max(44, rect.height + 20)
        return Path(CGRect(x: rect.minX, y: rect.minY - 12, width: rect.width, height: height))
    }
}

/// Adjustable action only once seeking is wired; a hint while it is unavailable.
private struct ScrubberAccessibility: ViewModifier {
    let isWired: Bool
    let canSeek: Bool
    let step: (TimeInterval) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isWired && canSeek {
            content.accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(ScrubberState.accessibilityStep)
                case .decrement: step(-ScrubberState.accessibilityStep)
                @unknown default: break
                }
            }
        } else if isWired {
            content.accessibilityHint(PlaybackScrubber.unavailableHint)
        } else {
            content
        }
    }
}

/// Liquid Glass on iOS 26+, a thin material before that, a plain fill with Reduce Transparency.
private struct ScrubberGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.thinMaterial, in: shape)
            }
            #else
            content.background(.thinMaterial, in: shape)
            #endif
        }
    }
}

private extension View {
    func scrubberGlass<S: Shape>(_ shape: S) -> some View {
        modifier(ScrubberGlass(shape: shape))
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

#if DEBUG
#Preview("Scrubber") {
    VStack(spacing: 28) {
        PlaybackScrubber(time: .fixture, transport: .playing, trackID: "a", canSeek: false, onSeek: nil)
        PlaybackScrubber(time: .fixture, transport: .playing, trackID: "a", canSeek: true, onSeek: { _ in true })
        PlaybackScrubber(time: .fixture, transport: .playing, trackID: "a", canSeek: false, onSeek: { _ in true })
    }
    .padding()
    .preferredColorScheme(.dark)
}
#endif

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
