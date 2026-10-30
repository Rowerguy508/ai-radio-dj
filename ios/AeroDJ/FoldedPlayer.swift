import AeroDJCore
import SwiftUI

// Folded (compact width) Now Playing, redesigned per wireframe 08-folded (owner, 28 Oct).
// UI only: every value here comes from the snapshot, `DJStatusPresentation` and the
// existing `PlaybackActions`. Nothing in this file starts, stops or seeks playback; the
// transport is the shared `TransportRow`, so its tap policy is unchanged.
//
// Design tokens: near-black #060607, dark glass (white 8% fill, 1 px white hairline at 10%),
// 8 pt grid, continuous corners (panel 30, card 24, field 14, capsule controls), monochrome
// SF Symbols. Colour comes only from the art. Amber is reserved for ON AIR, which is drawn
// only while `DJStudioState.isOnAir` (player-confirmed speech).

enum FoldedStyle {
    static let background = Color(red: 6 / 255, green: 6 / 255, blue: 7 / 255)
    static let glassFill = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.10)
    static let opaqueGlass = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let secondaryInk = Color.white.opacity(0.6)
    static let tertiaryInk = Color.white.opacity(0.5)
    /// ON AIR only.
    static let onAirAmber = Color(red: 1, green: 176 / 255, blue: 46 / 255)
    static let onAirTimer = Color(red: 1, green: 207 / 255, blue: 122 / 255)

    static let panelRadius: CGFloat = 30
    static let artRadius: CGFloat = 24
    static let fieldRadius: CGFloat = 14
    /// Content gutter on the 8 pt grid (wireframe: 32 pt art and title inset).
    static let contentInset: CGFloat = 32
    /// Toolbar gutter (wireframe: 16 pt).
    static let toolbarInset: CGFloat = 16
    static let toolbarHeight: CGFloat = 52
    static let artMaxSide: CGFloat = 420
    static let artMinSide: CGFloat = 140
}

/// Dark glass through the shared `aeroGlass`: Liquid Glass on iOS 26, the white 8 % fill plus a
/// 1 px hairline before that, and opaque under Reduce Transparency. Buttons pass `.control`.
extension View {
    func foldedGlass<S: InsettableShape>(_ shape: S, role: AeroGlassRole = .surface) -> some View {
        aeroGlass(shape, role: role, fallback: AnyShapeStyle(FoldedStyle.glassFill),
                  hairline: FoldedStyle.hairline, opaqueFill: FoldedStyle.opaqueGlass)
    }
}

/// Reduce Motion, including the capture launch flag the UI tests use.
private struct FoldedReduceMotion {
    static func resolve(_ system: Bool) -> Bool {
        #if DEBUG
        system || UserDefaults.standard.bool(forKey: StudioCapture.reduceMotionKey)
        #else
        system
        #endif
    }
}

// MARK: - Player

/// Closed Duo / compact width. Art card, left-aligned title, the DJ status slot, then a pinned
/// bottom: progress, one primary action (Play/Pause) plus Skip, and a toolbar with the station
/// chip, Queue and Tune. The navigation bar carries back and ⋯ (`foldedToolbar`).
///
/// Wide container (`FoldedColumnLayout.isWide`, e.g. the unfolded Duo's split view): the same
/// pieces in one centred column the width of the art, title and DJ status centred, the
/// controls right under them (no gap down to a pinned bottom), and ⋯ in a header row aligned
/// to the column instead of the far corner of the navigation bar. Phone widths are unchanged.
struct FoldedPlayer: View {
    /// The station the now-playing track belongs to (art fallback colours).
    let station: StationRef
    /// The opened station names the chip, the same rule as the Studio header.
    let heading: StationHeading
    let isTestStation: Bool
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    let search: MusicSearch?
    @ObservedObject var studioSearch: StudioSearchModel
    var timeSource: PlaybackTimeSource? = nil
    var artworkNamespace: Namespace.ID? = nil
    /// Fry's DJ voice level for the on-air orb. Read only; nil (previews) is a quiet orb.
    var speechLevel: DJPresentationStore? = nil
    /// ⋯ drawn in the column's header row when the container is wide. The caller hides the
    /// navigation bar's ⋯ at the same width (`foldedToolbar(showsMore:)`), so there is one.
    var moreMenu: FoldedMoreMenuItems? = nil
    let onQueue: () -> Void
    let onTune: () -> Void
    let onReview: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geo in
            if FoldedColumnLayout.isWide(containerWidth: Double(geo.size.width)) {
                wideBody(in: geo.size)
            } else {
                compactBody(in: geo.size)
            }
        }
        .background {
            FoldedBackdrop(track: heroTrack, station: station)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.onSlab, true)
    }

    /// Phone width: unchanged from wireframe 08 (scrolling upper, pinned controls).
    private func compactBody(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                upper(artSide: artSide(in: size), centered: false)
                    .padding(.horizontal, FoldedStyle.contentInset)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollContentBackground(.hidden)
            controls(contentInset: FoldedStyle.contentInset, toolbarInset: FoldedStyle.toolbarInset,
                     spacing: 16, balancesTransport: false)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Wide container: header (⋯), art, title, status and controls as one centred column,
    /// vertically centred while it fits and scrolling as one piece when it doesn't.
    private func wideBody(in size: CGSize) -> some View {
        let reserve: Double = typeSize.isAccessibilitySize ? 620 : 380
        let m = FoldedColumnLayout.metrics(containerWidth: Double(size.width),
                                           containerHeight: Double(size.height),
                                           reserveBelowArt: reserve,
                                           artMin: Double(FoldedStyle.artMinSide),
                                           artMax: Double(FoldedStyle.artMaxSide))
        let column = CGFloat(m.column)
        typealias Gap = FoldedColumnLayout.Spacing
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                wideHeader
                    .frame(height: CGFloat(FoldedColumnLayout.headerHeight))
                upper(artSide: CGFloat(m.artSide), centered: true)
                    .padding(.top, CGFloat(Gap.headerToArt))
                controls(contentInset: 0, toolbarInset: 0,
                         spacing: CGFloat(Gap.betweenControls), balancesTransport: true)
                    .padding(.top, CGFloat(Gap.statusToControls))
            }
            .frame(width: column)
            // The column itself, not the full-width scroll view: UI tests read its width and
            // centre (#207). `.contain` keeps every control its own element.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("folded.wideColumn")
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: size.height, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        .frame(width: size.width, height: size.height)
    }

    /// ⋯ at the column's trailing edge. Empty (same height) when the caller keeps ⋯ in the bar.
    @ViewBuilder
    private var wideHeader: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let moreMenu {
                FoldedMoreMenu(reviewCount: moreMenu.reviewCount, onConnections: moreMenu.onConnections)
            }
        }
    }

    private var heroTrack: TrackInfo? {
        if case .track(let track) = content { return track }
        return nil
    }

    /// Square art: the column width less the gutters, capped so the title and the pinned
    /// controls stay on screen. Only the container decides; no device size is named.
    private func artSide(in size: CGSize) -> CGFloat {
        let byWidth = size.width - FoldedStyle.contentInset * 2
        let reserve: CGFloat = typeSize.isAccessibilitySize ? 560 : 430
        let byHeight = size.height - reserve
        return max(FoldedStyle.artMinSide, min(byWidth, byHeight, FoldedStyle.artMaxSide))
    }

    // MARK: Upper (scrolls at large text sizes)

    @ViewBuilder
    private func upper(artSide: CGFloat, centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 0) {
            switch content {
            case .track(let track):
                FoldedArtCard(track: track, station: station, isOnAir: dj.state.isOnAir,
                              side: artSide, namespace: artworkNamespace, speechLevel: speechLevel)
                    .frame(maxWidth: .infinity)
                FoldedTitleBlock(track: track, isTestStation: isTestStation, centered: centered)
                    .padding(.top, centered ? CGFloat(FoldedColumnLayout.Spacing.artToTitle) : 24)
                FoldedDJStatus(dj: dj)
                    .padding(.top, centered ? CGFloat(FoldedColumnLayout.Spacing.titleToStatus) : 16)
            case .nothingPlaying:
                testTag
                NowPlayingPlaceholder(content: content, actions: actions)
                    .padding(.top, 24)
                if let search {
                    StartListeningView(search: search, model: studioSearch)
                        .padding(.top, 16)
                }
            default:
                testTag
                NowPlayingPlaceholder(content: content, actions: actions)
                    .padding(.top, 24)
            }
        }
    }

    @ViewBuilder
    private var testTag: some View {
        if isTestStation { FoldedTestStationTag() }
    }

    // MARK: Pinned controls

    private var showsProgress: Bool {
        guard content.showsTransport, let timeSource else { return false }
        return timeSource.duration().map { $0 > 0 } ?? false
    }

    /// Queue and Tune open the existing workspace sheet. Shown when there is a station
    /// session to look at (a track, or authorized with nothing queued).
    private var showsWorkspaceButtons: Bool {
        switch content {
        case .track, .nothingPlaying: true
        default: false
        }
    }

    /// Phone: inset by the wireframe gutters and pinned under the scroll. Wide: no inset (the
    /// column already sets the width) and Play/Pause centred on the column.
    private func controls(contentInset: CGFloat, toolbarInset: CGFloat, spacing: CGFloat,
                          balancesTransport: Bool) -> some View {
        VStack(spacing: spacing) {
            PlaybackErrorBanner(error: snapshot.error, actions: actions)
                .padding(.horizontal, contentInset)
            if showsProgress, let timeSource {
                // One seek per release, for the track on screen (#171's stale-scrub guard).
                // The scrubber dims itself and drops the gesture while canSeek is false (DJ break).
                PlaybackScrubber(time: timeSource, transport: snapshot.transport,
                                 trackID: snapshot.nowPlaying?.id,
                                 canSeek: snapshot.canSeek,
                                 onSeek: { await actions.seek(to: $0, trackID: $1) },
                                 isDJSpeaking: dj.state.isOnAir)
                    .padding(.horizontal, contentInset)
            }
            if content.showsTransport {
                // No Tune here (moved to the toolbar) and no Previous: PlaybackActions has none.
                TransportRow(transport: snapshot.transport, startTimedOut: snapshot.startTimedOut,
                             actions: actions, onTune: nil, balancesSides: balancesTransport)
                    .padding(.horizontal, contentInset)
            }
            FoldedToolbar(heading: heading, upNext: snapshot.upNext,
                          showsWorkspaceButtons: showsWorkspaceButtons,
                          onQueue: onQueue, onTune: onTune)
                .padding(.horizontal, toolbarInset)
                .padding(.top, balancesTransport
                         ? CGFloat(FoldedColumnLayout.Spacing.transportToToolbar) - spacing : 0)
        }
        .padding(.top, balancesTransport ? 0 : 8)
        .padding(.bottom, 8)
    }
}

// MARK: - Backdrop

/// Near-black with one soft, static wash taken from the art. It never animates, so it is
/// already still under Reduce Motion.
private struct FoldedBackdrop: View {
    let track: TrackInfo?
    let station: StationRef?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .top) {
            FoldedStyle.background
            if !reduceTransparency {
                GeometryReader { geo in
                    BleedArtwork(track: track, station: station)
                        .frame(width: geo.size.width + 80, height: geo.size.height * 0.72)
                        .blur(radius: 60)
                        .opacity(0.30)
                        .offset(x: -40, y: -60)
                    LinearGradient(stops: [.init(color: FoldedStyle.background.opacity(0), location: 0),
                                           .init(color: FoldedStyle.background, location: 0.45)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * 0.65)
                        .offset(y: geo.size.height * 0.35)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Art card

/// Album art (or station art) in a 24 pt card with one soft glow. While ON AIR the card
/// shows the lava-lamp orb (`DJLavaOrb`), coloured by the same art and driven by the DJ
/// voice level.
private struct FoldedArtCard: View {
    let track: TrackInfo
    let station: StationRef?
    let isOnAir: Bool
    let side: CGFloat
    let namespace: Namespace.ID?
    var speechLevel: DJPresentationStore? = nil

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: FoldedStyle.artRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            // One soft glow from the same art.
            BleedArtwork(track: track, station: station)
                .frame(width: side * 0.88, height: side * 0.9)
                .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                .blur(radius: 34)
                .opacity(isOnAir ? 0.25 : 0.5)
                .offset(y: 20)
            card
                .frame(width: side, height: side)
                .modifier(BleedArtFrame(namespace: namespace))
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var card: some View {
        if isOnAir {
            ZStack {
                BleedArtwork(track: track, station: station).opacity(0.18)
                DJLavaOrb(track: track, station: station, levels: speechLevel)
                    .frame(width: side * 0.72, height: side * 0.72)
            }
            .clipShape(shape)
            .foldedGlass(shape)
        } else {
            BleedArtwork(track: track, station: station)
                .clipShape(shape)
                .overlay(shape.strokeBorder(FoldedStyle.hairline, lineWidth: 1))
        }
    }
}

// MARK: - Title

/// Song title and artist, left-aligned. The station is not repeated here (the chip names it).
/// The debug TEST STATION tag sits under the title.
private struct FoldedTitleBlock: View {
    let track: TrackInfo
    let isTestStation: Bool
    /// Wide column: centred under the centred art.
    var centered = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 4) {
            VStack(alignment: centered ? .center : .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(.title2, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(track.artistName)
                    .font(.body)
                    .foregroundStyle(FoldedStyle.secondaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(centered ? .center : .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(track.title), \(track.artistName)")
            .accessibilityAddTraits(.isHeader)
            if isTestStation {
                FoldedTestStationTag().padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

/// Debug fixture label so a screenshot can't pass for a listener's real station.
private struct FoldedTestStationTag: View {
    var body: some View {
        Text("TEST STATION")
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(FoldedStyle.secondaryInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .accessibilityLabel("Test station")
    }
}

// MARK: - DJ status slot

/// Only real DJ state draws here. Idle draws nothing. Preparing and ready get a quiet capsule
/// with the presentation's headline; its shimmer runs only when
/// `DJStatusPresentation.animatesActivity` says so (On Air only today, so both are static) and
/// never under Reduce Motion. Speaking gets the amber ON AIR pill; voice or budget failures
/// reuse the shared `DJStatusLine`. Shared items to review live in the ⋯ menu.
private struct FoldedDJStatus: View {
    let dj: DJStatusPresentation

    var body: some View {
        switch dj.state {
        case .preparing:
            if let headline = dj.headline {
                FoldedStatusCapsule(headline: headline, accessibilityLabel: dj.accessibilityLabel,
                                    systemImage: "scope", animates: dj.animatesActivity,
                                    identifier: "dj.preparing")
            }
        case .speaking:
            FoldedOnAirPill()
        case .failed:
            if dj.reviewCount == nil {
                DJStatusLine(presentation: dj)
            }
        case .ready:
            // Quiet, static line so the owner can see a break is queued ("DJ break after this
            // song"). Folded only; `DJStatusLine` (Studio) still hides `.ready` per f65ff0d.
            if let headline = dj.headline {
                FoldedStatusCapsule(headline: headline, accessibilityLabel: dj.accessibilityLabel,
                                    systemImage: "clock", animates: dj.animatesActivity,
                                    identifier: "dj.ready")
            }
        case .idle:
            EmptyView()
        }
    }
}

/// Quiet status capsule for preparing and ready. The shimmer is drawn only when the caller passes the
/// presentation's `animatesActivity` as true and Reduce Motion is off.
private struct FoldedStatusCapsule: View {
    let headline: String
    let accessibilityLabel: String
    let systemImage: String
    let animates: Bool
    let identifier: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { FoldedReduceMotion.resolve(systemReduceMotion) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.medium))
                .accessibilityHidden(true)
            Text(headline)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.white.opacity(0.85))
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(minHeight: 32)
        .background { shimmer }
        .foldedGlass(Capsule())
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel.isEmpty ? headline : accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    /// Bound to `DJStatusPresentation.animatesActivity`; nothing animates under Reduce Motion.
    @ViewBuilder
    private var shimmer: some View {
        if animates && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                GeometryReader { geo in
                    let period = 1.8
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    let band = max(60, geo.size.width * 0.5)
                    LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.2),
                                           .init(color: .white.opacity(0.22), location: 0.5),
                                           .init(color: .white.opacity(0), location: 0.8)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + (geo.size.width + band) * t)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The only amber on screen. Drawn only in `.speaking`; the timer counts from the moment this
/// view saw that state. Debug capture (`djSpeaking`) pins the timer instead, so a screenshot
/// or the App Store video always reads the same time (`StudioCapture.onAirElapsed`).
private struct FoldedOnAirPill: View {
    @State private var startedAt = Date()
    #if DEBUG
    @Environment(\.studioCaptureOnAirElapsed) private var captureElapsed
    #endif

    var body: some View {
        Group {
            #if DEBUG
            if let captureElapsed {
                pill(elapsed: captureElapsed)
            } else {
                live
            }
            #else
            live
            #endif
        }
        .accessibilityIdentifier("dj.onAir")
    }

    private var live: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            pill(elapsed: max(0, context.date.timeIntervalSince(startedAt)))
        }
    }

    private func pill(elapsed: TimeInterval) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(FoldedStyle.onAirAmber)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("ON AIR")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(FoldedStyle.onAirAmber)
            Text(PlaybackTimeFormat.label(elapsed))
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(FoldedStyle.onAirTimer)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 32)
        .background(FoldedStyle.onAirAmber.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(FoldedStyle.onAirAmber.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("On Air, \(PlaybackTimeFormat.label(elapsed))")
    }
}

// MARK: - Bottom toolbar

/// Station chip ("Playing from ‹Station›", opens the queue), Queue and Tune. Each 52 pt.
private struct FoldedToolbar: View {
    let heading: StationHeading
    let upNext: [TrackInfo]
    let showsWorkspaceButtons: Bool
    let onQueue: () -> Void
    let onTune: () -> Void

    var body: some View {
        // One glass family on iOS 26, so the chip and the round buttons read as one bar.
        AeroGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                FoldedStationChip(heading: heading, action: onQueue)
                if showsWorkspaceButtons {
                    FoldedToolbarButton(systemImage: "list.bullet",
                                        label: upNext.first.map { "Up next: \($0.title) by \($0.artistName)" } ?? "Up next: nothing queued",
                                        hint: "Opens the queue, tuner and connections",
                                        identifier: "queue.affordance", action: onQueue)
                    FoldedToolbarButton(systemImage: "slider.horizontal.3", label: "Tune station",
                                        hint: "Opens the tuner. Music continues.",
                                        identifier: "transport.tune", action: onTune)
                }
            }
        }
    }
}

private struct FoldedStationChip: View {
    let heading: StationHeading
    let action: () -> Void

    /// "Playing from" only when the session really is this station; otherwise just its name.
    private var caption: String {
        heading.playing?.id == heading.opened.id ? "Playing from" : "Station"
    }

    var body: some View {
        Button(action: action) {
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
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: FoldedStyle.toolbarHeight)
            .foldedGlass(Capsule(), role: .control)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption) \(heading.opened.name)")
        .accessibilityHint("Opens the queue")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("station.title")
    }
}

private struct FoldedToolbarButton: View {
    let systemImage: String
    let label: String
    let hint: String
    let identifier: String
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: FoldedStyle.toolbarHeight, height: FoldedStyle.toolbarHeight)
                .foldedGlass(Circle(), role: .control)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Navigation bar (back + ⋯)

extension View {
    /// Folded navigation bar: the system back button and a ⋯ menu for Connections and
    /// review. No title view (the station chip names the station); the title string stays
    /// for the back button and VoiceOver. The bar is transparent over the near-black backdrop.
    /// `showsMore: false` when the player draws ⋯ in its own column header (wide container).
    func foldedToolbar(_ station: StationRef, reviewCount: Int?, showsMore: Bool = true,
                       onConnections: @escaping () -> Void) -> some View {
        navigationTitle(station.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                if showsMore {
                    ToolbarItem(placement: .topBarTrailing) {
                        FoldedMoreMenu(reviewCount: reviewCount, onConnections: onConnections)
                    }
                }
            }
    }
}

/// What ⋯ needs when the wide player draws it in its column header.
struct FoldedMoreMenuItems {
    let reviewCount: Int?
    let onConnections: () -> Void
}

private struct FoldedMoreMenu: View {
    let reviewCount: Int?
    let onConnections: () -> Void

    var body: some View {
        Menu {
            Button(action: onConnections) {
                Label("Connections", systemImage: "link")
            }
            .accessibilityIdentifier("more.connections")
            if let reviewCount, reviewCount > 0 {
                Button(action: onConnections) {
                    Label("Review \(reviewCount) shared \(reviewCount == 1 ? "item" : "items")",
                          systemImage: "exclamationmark.bubble")
                }
                .accessibilityIdentifier("more.review")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .modifier(LegacyToolbarGlass())
                .overlay(alignment: .topTrailing) {
                    if let reviewCount, reviewCount > 0 {
                        Circle().fill(.white).frame(width: 8, height: 8).offset(x: -6, y: 6)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Circle())
        }
        .accessibilityLabel(reviewCount.map { $0 > 0 ? "More, \($0) to review" : "More" } ?? "More")
        .accessibilityIdentifier("folded.more")
    }
}

/// iOS 26 draws toolbar items on Liquid Glass already; before that, draw the dark glass circle.
private struct LegacyToolbarGlass: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
        } else {
            content.foldedGlass(Circle())
        }
        #else
        content.foldedGlass(Circle())
        #endif
    }
}

#if DEBUG
#Preview("Folded playing") {
    NavigationStack {
        FoldedPlayer(station: PlaybackFixtures.station,
                     heading: StationHeading(opened: PlaybackFixtures.station, playing: PlaybackFixtures.station),
                     isTestStation: true,
                     content: .track(PlaybackFixtures.songs[0]),
                     snapshot: PlaybackFixtures.playing, actions: .preview,
                     dj: .init(state: .idle), search: nil, studioSearch: StudioSearchModel(query: ""),
                     timeSource: .fixture,
                     onQueue: {}, onTune: {}, onReview: {})
            .foldedToolbar(PlaybackFixtures.station, reviewCount: nil, onConnections: {})
    }
}

#Preview("Folded preparing") {
    NavigationStack {
        FoldedPlayer(station: PlaybackFixtures.station,
                     heading: StationHeading(opened: PlaybackFixtures.station, playing: PlaybackFixtures.station),
                     isTestStation: false,
                     content: .track(PlaybackFixtures.songs[0]),
                     snapshot: PlaybackFixtures.playing, actions: .preview,
                     dj: .init(state: .preparing(includesBriefing: false)), search: nil,
                     studioSearch: StudioSearchModel(query: ""), timeSource: .fixture,
                     onQueue: {}, onTune: {}, onReview: {})
            .foldedToolbar(PlaybackFixtures.station, reviewCount: nil, onConnections: {})
    }
}

#Preview("Folded ready") {
    NavigationStack {
        FoldedPlayer(station: PlaybackFixtures.station,
                     heading: StationHeading(opened: PlaybackFixtures.station, playing: PlaybackFixtures.station),
                     isTestStation: false,
                     content: .track(PlaybackFixtures.songs[0]),
                     snapshot: PlaybackFixtures.playing, actions: .preview,
                     dj: .init(state: .ready(includesBriefing: false, seconds: 24)), search: nil,
                     studioSearch: StudioSearchModel(query: ""), timeSource: .fixture,
                     onQueue: {}, onTune: {}, onReview: {})
            .foldedToolbar(PlaybackFixtures.station, reviewCount: nil, onConnections: {})
    }
}

#Preview("Folded wide (open Duo split view)", traits: .fixedLayout(width: 640, height: 820)) {
    NavigationStack {
        FoldedPlayer(station: PlaybackFixtures.station,
                     heading: StationHeading(opened: PlaybackFixtures.station, playing: PlaybackFixtures.station),
                     isTestStation: false,
                     content: .track(PlaybackFixtures.songs[0]),
                     snapshot: PlaybackFixtures.playing, actions: .preview,
                     dj: .init(state: .ready(includesBriefing: false, seconds: 24)), search: nil,
                     studioSearch: StudioSearchModel(query: ""), timeSource: .fixture,
                     moreMenu: FoldedMoreMenuItems(reviewCount: nil, onConnections: {}),
                     onQueue: {}, onTune: {}, onReview: {})
            .foldedToolbar(PlaybackFixtures.station, reviewCount: nil, showsMore: false, onConnections: {})
    }
}

#Preview("Folded on air") {
    NavigationStack {
        FoldedPlayer(station: PlaybackFixtures.station,
                     heading: StationHeading(opened: PlaybackFixtures.station, playing: PlaybackFixtures.station),
                     isTestStation: false,
                     content: .track(PlaybackFixtures.songs[1]),
                     snapshot: PlaybackFixtures.djSpeaking, actions: .preview,
                     dj: .init(state: .speaking(includesBriefing: false)), search: nil,
                     studioSearch: StudioSearchModel(query: ""), timeSource: .fixture,
                     onQueue: {}, onTune: {}, onReview: {})
            .foldedToolbar(PlaybackFixtures.station, reviewCount: 2, onConnections: {})
    }
}
#endif
