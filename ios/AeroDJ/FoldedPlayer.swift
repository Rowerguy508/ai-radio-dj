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
    /// Phone width at accessibility text sizes only (#310): the art gives way first so the
    /// title block fits above the pinned controls.
    static let artMinSideAccessibility: CGFloat = 72
    /// Height kept clear of the art on a phone at accessibility text sizes (#310): pinned
    /// controls with the DJ status, plus the title block at AX5.
    static let artReserveAccessibility: CGFloat = 700
}

/// Dark glass through the shared `aeroGlass`: Liquid Glass on iOS 26, the white 8 % fill plus a
/// 1 px hairline before that, and opaque under Reduce Transparency. Buttons pass `.control`.
extension View {
    func foldedGlass<S: InsettableShape>(_ shape: S, role: AeroGlassRole = .surface) -> some View {
        aeroGlass(shape, role: role, fallback: AnyShapeStyle(FoldedStyle.glassFill),
                  hairline: FoldedStyle.hairline, opaqueFill: FoldedStyle.opaqueGlass)
    }
}

/// The continuity capture names the player scroll so a test can swipe it.
/// Other launches leave the accessibility tree as it was.
private struct ContinuityScrollerID: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityIdentifier("continuity.scroller")
        } else {
            content
        }
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
/// Wide and short (`FoldedColumnLayout.centredColumn`, iPhone landscape): one centred
/// column, controls under the art. Wide and tall (the unfolded Duo): full width,
/// horizontal. Artwork and the title stay in the left half. The right half is a content
/// column plus the vertical rail. Phone portrait is unchanged.
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
    /// False shows the centred column in a container that is still the unfolded Duo.
    /// Phone portrait and landscape ignore it. Playback is not involved.
    var showsUnfoldedRail: Bool = true
    var onCollapseRail: () -> Void = {}
    /// Build 51 (-Atlas): brings the rail back after Collapse. Nil where there is no rail to show.
    var onExpandRail: (() -> Void)? = nil
    /// Build 51 (-Atlas): the open Duo with the Stations sidebar open (`FoldedColumnLayout.usesRailColumn`):
    /// the centred column beside the rail, or (collapsed) the pinned column. False everywhere else.
    var railColumn: Bool = false
    /// The container `PlayingScreen` routed with: the reader plus its vertical safe-area insets
    /// (`FoldedColumnLayout.routingHeight`). Nil reads this view's own reader, as before.
    var placementSize: CGSize? = nil
    /// Stations the Duo dial can open. Empty on phone widths and when no list was passed.
    var stationStops: [DuoStationSwitch.Stop] = []
    /// The station-row open path. Nil hides the dial.
    var onOpenStation: ((String) async -> Void)? = nil
    /// Outer edge while the window is a split. Nil keeps the symbol bar on the trailing side.
    var splitBarEdge: SplitViewLayout.BarEdge? = nil
    /// The split container, when the host is adapting. Nil uses the reader, which is the phone.
    var layoutSize: CGSize? = nil
    /// Insets the split host reported. Nil on the phone and the full-screen Duo, so those
    /// readers never see a split measurement.
    var splitHost: SplitMeasure? = nil
    /// Owned by `PlayingScreen`, above the layout switch. A placement change
    /// rebuilds the scroll view and reads this same anchor back.
    var scrollAnchor: Binding<String?> = .constant(Optional<String>.none)

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The 01-folded reskin header draws its own back button (#491).
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var moreOpen = false
    /// Book pose only. Empty on this SDK, so `wideBody` keeps the centred gutter.
    @State private var foldHinge: FoldAwareness.HingeSample?
    @State private var foldDivisions: [FoldAwareness.Division] = []
    /// Studio capture only (mockup D shots): a forced hinge and fold. Nil in the app.
    @Environment(\.foldPoseOverride) private var foldPoseOverride
    /// Build 54 follow-up: the open-Duo window as `StationSplitRoot` measured it (nil elsewhere,
    /// including every capture without the split).
    @Environment(\.openDuoWindow) private var openDuoWindow

    private var effectiveFoldHinge: FoldAwareness.HingeSample? {
        foldPoseOverride.map { $0.hinge } ?? foldHinge
    }

    private var effectiveFoldDivisions: [FoldAwareness.Division] {
        foldPoseOverride?.divisions ?? foldDivisions
    }

    /// `DisplayContinuity.layout` with this container and the width class. Studio
    /// results are not drawn here (the screen embeds this player only for a
    /// compact decision); those fall through to the geometry-only column, which
    /// is the phone path this view had before the size class was an input.
    private func playerPlacement(in size: CGSize) -> FoldedColumnLayout.ControlPlacement {
        let decision = DisplayContinuity.layout(
            hasRegularWidth: horizontalSizeClass == .regular,
            containerWidth: Double(size.width),
            containerHeight: Double(size.height),
            accessibilityTextSize: typeSize.isAccessibilitySize,
            isPhoneIdiom: DeviceIdiom.isPhone)
        if let placement = decision.controlPlacement { return placement }
        return FoldedColumnLayout.controlPlacement(containerWidth: Double(size.width),
                                                   containerHeight: Double(size.height))
    }

    private var continuityProbe: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: DisplayContinuityLaunch.probeKey)
        #else
        false
        #endif
    }

    var body: some View {
        if let layoutSize {
            // The container is split.container. The reader under the bar is shorter
            // than duoMinHeight, and ignoresSafeArea on this view inflates the frame.
            splitMeasured(layoutSize)
        } else {
            phoneBody
        }
    }

    /// Phone and every non-split window. The reader decides the layout.
    private var phoneBody: some View {
        GeometryReader { geo in
            let placement = playerPlacement(in: placementSize ?? geo.size)
            if railColumn, placement != .duoHorizontal {
                // Build 51: the sidebar-open open Duo keeps the rail (Play and Skip on it).
                if showsUnfoldedRail {
                    railColumnBody(in: geo.size)
                } else {
                    pinnedColumnBody(in: geo.size)
                        .onAppear { moreOpen = false }
                }
            } else {
                switch placement {
                case .phoneBottom:
                    // 01-folded reskin (iPhone and folded Duo) whenever a track is showing.
                    // PlayingScreen.layout(mode:) uses the same rule to hide the system back
                    // and move ⋯ in. Other states keep compactBody.
                    if FoldedOuterLayout.usesOuterReskin(containerWidth: Double(geo.size.width), showsTrack: heroTrack != nil) {
                        foldedOuterBody(in: geo.size)
                    } else {
                        compactBody(in: geo.size)
                    }
                case .centredColumn:
                    centredColumnBody(in: geo.size)
                case .duoHorizontal:
                    if showsUnfoldedRail {
                        wideBody(in: geo.size, readerMinY: geo.frame(in: .global).minY)
                    } else {
                        // Build 51: the collapsed rail pins the transport; the scrolling centred
                        // column left Play and Skip below the 820 × 640 window.
                        pinnedColumnBody(in: geo.size, foldAware: true,
                                         placementHeight: (placementSize ?? geo.size).height)
                            .onAppear { moreOpen = false }
                    }
                }
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

    /// Split host. Placement uses the full container, so 540×760 stays the Duo rail.
    /// The reader under the navigation bar is shorter, and that is the height that
    /// is drawn, so the bottom controls stay inside the container. The backdrop's
    /// safe-area ignore is only the background layer.
    ///
    /// The rail is framed to that raw container, so the host's safe-area inset does
    /// not move it. The symbol bar was then the 16 pt design gutter in from the
    /// edge (18 pt once the 52 pt buttons sit centred in the 56 pt column), inside
    /// the leading inset the host reported. The Duo rail shifts in by those insets.
    /// The phone column and the centred column stay on the raw width: a narrow
    /// split has no symbol bar, and the phone reader never calls this.
    private func splitMeasured(_ container: CGSize) -> some View {
        GeometryReader { geo in
            let shortfall = max(0, container.height - geo.size.height)
            let height = max(0, container.height - shortfall)
            let placement = FoldedColumnLayout.controlPlacement(
                containerWidth: Double(container.width),
                containerHeight: Double(container.height))
            if placement == .duoHorizontal, let measure = splitHost {
                let rail = SplitViewLayout.railFrame(containerWidth: Double(container.width),
                                                     leadingInset: measure.leading,
                                                     trailingInset: measure.trailing)
                let fitted = CGSize(width: CGFloat(rail.width), height: height)
                laidOut(in: fitted, placement: container)
                    .frame(width: fitted.width, height: fitted.height, alignment: .top)
                    .padding(.leading, CGFloat(rail.leading))
                    .padding(.trailing, CGFloat(rail.trailing))
                    .frame(width: container.width, height: height, alignment: .topLeading)
            } else {
                let fitted = CGSize(width: container.width, height: height)
                laidOut(in: fitted, placement: container)
                    .frame(width: fitted.width, height: fitted.height, alignment: .top)
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

    @ViewBuilder
    private func laidOut(in size: CGSize, placement: CGSize? = nil) -> some View {
        let decision = placement ?? size
        switch FoldedColumnLayout.controlPlacement(containerWidth: Double(decision.width),
                                                   containerHeight: Double(decision.height)) {
        case .phoneBottom:
            compactBody(in: size)
        case .centredColumn:
            centredColumnBody(in: size)
        case .duoHorizontal:
            // Same collapse rule as phoneBody (#479): a collapsed rail shows the centred column,
            // with the transport pinned (build 51).
            if showsUnfoldedRail {
                wideBody(in: size)
            } else {
                pinnedColumnBody(in: size, foldAware: true, placementHeight: decision.height)
                    .onAppear { moreOpen = false }
            }
        }
    }

    /// Phone width: unchanged from wireframe 08 (scrolling upper, pinned controls).
    private func compactBody(in size: CGSize) -> some View {
        // #310: at accessibility sizes the art shrinks (72 pt floor) so the title block fits,
        // and the DJ status / ON AIR line moves into the pinned controls above the scrubber,
        // so it is always visible without scrolling. Anything still taller (a very long
        // title) scrolls, with the indicator shown. Default sizes are unchanged.
        let accessibilityText = typeSize.isAccessibilitySize
        let art = artSide(in: size)
        return VStack(spacing: 0) {
            if accessibilityText {
                // The pinned status makes the controls taller, so the space above them can
                // shrink below the title block even with the art at its 72 pt floor; the scroll
                // then cut the TEST STATION tag off behind the ON AIR pill (#345 review). The
                // art gives way next: title, artist and tag unscrolled with the art, then
                // without it, and only if neither fits, everything scrolls as before.
                ViewThatFits(in: .vertical) {
                    compactUpper(artSide: art, includesArt: true, includesStatus: false)
                    compactUpper(artSide: art, includesArt: false, includesStatus: false)
                    compactUpperScroll(artSide: art, showsIndicators: true, includesStatus: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                compactUpperScroll(artSide: art, showsIndicators: false, includesStatus: true)
            }
            controls(contentInset: FoldedStyle.contentInset, toolbarInset: FoldedStyle.toolbarInset,
                     spacing: 16, balancesTransport: false, pinsStatus: accessibilityText)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Phone-width upper part with the wireframe gutters. `includesArt` false is only used at
    /// accessibility sizes, when the title block would not otherwise fit above the controls.
    private func compactUpper(artSide: CGFloat, includesArt: Bool, includesStatus: Bool) -> some View {
        upper(artSide: artSide, centered: false, includesStatus: includesStatus, includesArt: includesArt)
            .padding(.horizontal, FoldedStyle.contentInset)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Phone width: the scrolling upper part (wireframe 08). Default sizes always use this.
    private func compactUpperScroll(artSide: CGFloat, showsIndicators: Bool,
                                    includesStatus: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: showsIndicators) {
            compactUpper(artSide: artSide, includesArt: true, includesStatus: includesStatus)
                .scrollTargetLayout()
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        .scrollPosition(id: scrollAnchor)
        .modifier(ContinuityScrollerID(enabled: continuityProbe))
    }

    /// iPhone landscape: one centred column, the layout this width had before the Duo rail.
    /// ⋯ is in the column header. Controls sit under the art. No fold gutter, no top clearance.
    /// Mockup D (-Nova, Fry's #558 nit 4): no rail at this width, so the horizontal scrubber
    /// stays; D has no iPhone-landscape frame.
    private func centredColumnBody(in size: CGSize) -> some View {
        let reserve: Double = typeSize.isAccessibilitySize ? FoldedColumnLayout.centredColumnReserveBelowArtAccessibility : FoldedColumnLayout.centredColumnReserveBelowArt
        let m = FoldedColumnLayout.metrics(containerWidth: Double(size.width),
                                           containerHeight: Double(size.height),
                                           reserveBelowArt: reserve,
                                           artMin: Double(FoldedStyle.artMinSide),
                                           artMax: Double(FoldedStyle.artMaxSide))
        let column = CGFloat(m.column)
        typealias Gap = FoldedColumnLayout.Spacing
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if let moreMenu {
                        FoldedMoreMenu(reviewCount: moreMenu.reviewCount, onConnections: moreMenu.onConnections)
                    }
                }
                .frame(height: CGFloat(FoldedColumnLayout.headerHeight))
                upper(artSide: CGFloat(m.artSide), centered: true)
                    .padding(.top, CGFloat(Gap.headerToArt))
                controls(contentInset: 0, toolbarInset: 0,
                         spacing: CGFloat(Gap.betweenControls), balancesTransport: true)
                    .padding(.top, CGFloat(Gap.statusToControls))
            }
            .frame(width: column)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("folded.wideColumn")
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: size.height, alignment: .center)
            .scrollTargetLayout()
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        .scrollPosition(id: scrollAnchor)
        .frame(width: size.width, height: size.height)
    }

    /// Full-width Duo. The centre gutter is the fold: no control sits in it.
    /// In book pose the gutter is the division region instead of that centred band,
    /// and the player stays on its leading side. A column with no width is omitted
    /// so a 44 pt button is not laid out on the crease.
    ///
    /// Mockup D (-Nova): the rail carries the vertical song-position bar; the station name heads
    /// the track column. Portrait keeps the art, title and DJ chip on the leading side. Landscape
    /// with a track is the L1 book spread (art leading; title, artist, DJ chip and Up next
    /// trailing, left-aligned) unless the Duo is known to be flat, which gets L2
    /// (`RailDLayout.openArrangement`).
    ///
    /// Open Duo (`FoldedColumnLayout.usesOpenDuoRail`, build 54 follow-up, -Nova): the body spans
    /// the window's trailing unsafe column (`openDuoWindow.trailingInset`), so the fold sits on the
    /// window's centre and the rail is `RailDLayout.trailingInset` (8 pt) from the window edge, as
    /// on Stations. The content column takes the 8 pt the rail gives back, so nothing sits under
    /// the rail. The rail's top is the Stations rail's (`openDuoWindow.railTop`, global), the
    /// thumbnail replaces the chevron, and the day-wash panel that stopped short of the rail is
    /// gone. Full-screen iPads and the split host keep the old body.
    private func wideBody(in readerSize: CGSize, readerMinY: CGFloat? = nil) -> some View {
        // The phone idiom or a reported hinge (no iPad has either), at an open-Duo size.
        let openDuo = FoldedColumnLayout.usesOpenDuoRail(containerWidth: Double(readerSize.width),
                                                         containerHeight: Double(readerSize.height))
            && (DeviceIdiom.isPhone || effectiveFoldHinge != nil)
        let window: OpenDuoWindowMetrics? = openDuo ? openDuoWindow : nil
        let extend: CGFloat = window.map { max(0, $0.trailingInset) } ?? 0
        let size = CGSize(width: readerSize.width + extend, height: readerSize.height)
        let base = FoldAwareness.resolve(containerWidth: Double(size.width),
                                         containerHeight: Double(size.height),
                                         hinge: effectiveFoldHinge,
                                         divisions: effectiveFoldDivisions,
                                         artMin: Double(FoldedStyle.artMinSide),
                                         artMax: Double(FoldedStyle.artMaxSide)).metrics
        let layout = openDuo
            ? FoldedColumnLayout.DuoHorizontal(edgeInset: base.edgeInset, leftWidth: base.leftWidth,
                                               foldGutter: base.foldGutter,
                                               contentWidth: max(0, base.contentWidth + base.edgeInset
                                                                 - RailDLayout.trailingInset),
                                               barWidth: base.barWidth, topClearance: base.topClearance,
                                               artSide: base.artSide)
            : base
        let trailingInset = CGFloat(openDuo ? RailDLayout.trailingInset : layout.edgeInset)
        let railTop: CGFloat = {
            guard let window, let readerMinY else { return CGFloat(layout.topClearance) }
            return max(0, window.railTop - readerMinY)
        }()
        let thumbnail: StationRef? = openDuo ? heading.nowPlaying : nil
        let gap = CGFloat(FoldedColumnLayout.Spacing.betweenControls)
        // 27.1 draws the rail as the system vertical bar, outside this width.
        // 26.5 keeps the custom rail in `layout.barWidth`.
        let systemBar = DuoVerticalRail.usesSystemBar
        let contentWidth = layout.contentWidth + (systemBar ? layout.barWidth : 0)
        let arrangement: RailDLayout.OpenArrangement = heroTrack == nil
            ? .portrait
            : RailDLayout.openArrangement(containerWidth: Double(size.width),
                                          containerHeight: Double(size.height),
                                          hinge: effectiveFoldHinge,
                                          divisions: effectiveFoldDivisions)
        return Group {
            if arrangement == .centred {
                openCentredBody(in: size, layout: layout, systemBar: systemBar, gap: gap,
                                trailingInset: trailingInset, railTop: railTop, thumbnail: thumbnail,
                                showsWash: !openDuo)
            } else {
                openHalvesBody(in: size, layout: layout, systemBar: systemBar, gap: gap,
                               contentWidth: contentWidth, spread: arrangement == .spread,
                               trailingInset: trailingInset, railTop: railTop, thumbnail: thumbnail,
                               showsWash: !openDuo)
            }
        }
        .frame(width: size.width, height: size.height)
        // Open Duo: into the trailing unsafe column (0 everywhere else, so nothing moves).
        .padding(.trailing, -extend)
        .overlay {
            if moreOpen, !systemBar, layout.barWidth > 0 {
                railMorePanel(in: size)
            }
        }
        .modifier(SplitLeadingBar(enabled: splitBarEdge == .leading))
        .background {
            FoldDivisionProbe(hinge: $foldHinge, divisions: $foldDivisions)
        }
    }

    /// Portrait and the L1 spread: track column, fold gutter, content column, rail.
    private func openHalvesBody(in size: CGSize, layout: FoldedColumnLayout.DuoHorizontal, systemBar: Bool,
                                gap: CGFloat, contentWidth: Double, spread: Bool,
                                trailingInset: CGFloat, railTop: CGFloat, thumbnail: StationRef?,
                                showsWash: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if layout.leftWidth > 0 {
                ScrollView(.vertical, showsIndicators: false) {
                    // An explicit column width. A vertical scroll view otherwise offers an
                    // unbounded width, the placeholder lays out on one line, and a centred
                    // overflow puts the leading edge off the column.
                    Group {
                        if spread, let track = heroTrack {
                            spreadArtColumn(track: track, leftWidth: layout.leftWidth, height: size.height)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                RailDStationHeader(name: heading.header.name)
                                upper(artSide: CGFloat(min(layout.artSide, layout.leftWidth)), centered: false,
                                      includesStatus: true, keepArtVisible: true, includesSearch: false,
                                      titleSize: openTitleSize(column: layout.leftWidth), compactStatus: true)
                            }
                        }
                    }
                    .frame(width: CGFloat(layout.leftWidth), alignment: .leading)
                    .scrollTargetLayout()
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollContentBackground(.hidden)
                .scrollPosition(id: scrollAnchor)
                .modifier(ContinuityScrollerID(enabled: continuityProbe))
                .frame(width: CGFloat(layout.leftWidth), height: size.height, alignment: .topLeading)
                .background { if showsWash { dayWash.accessibilityHidden(true) } }
                // .contain first, then the identifier. An identifier on a container without
                // .contain is copied onto every control inside it. The element is the column,
                // not a clear layer over the rating button. The ScrollView is not the element:
                // that also exposes the scroll view.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("folded.trackColumn")
                .accessibilitySortPriority(2)
                .modifier(SplitColumnText(enabled: splitBarEdge == .leading))
            }

            Color.clear
                .frame(width: CGFloat(layout.foldGutter), height: size.height)
                .accessibilityHidden(true)
                .accessibilityIdentifier("folded.fold")
                .modifier(SplitColumnText(enabled: splitBarEdge == .leading))

            if contentWidth > 0 {
                Group {
                    if spread {
                        spreadContent(gap: gap, height: size.height)
                    } else {
                        wideContent(gap: gap, top: CGFloat(layout.topClearance))
                    }
                }
                .frame(width: CGFloat(contentWidth), height: size.height, alignment: .top)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("folded.contentColumn")
                .accessibilitySortPriority(1)
                .modifier(SplitColumnText(enabled: splitBarEdge == .leading))
            }

            if !systemBar, layout.barWidth > 0 {
                unfoldedRail(width: CGFloat(layout.barWidth), height: size.height,
                             top: railTop, thumbnail: thumbnail)
            }
        }
        .padding(.leading, CGFloat(layout.edgeInset))
        .padding(.trailing, trailingInset)
    }

    /// L1: the station header, then the art centred in the leading half. No control here.
    private func spreadArtColumn(track: TrackInfo, leftWidth: Double, height: CGFloat) -> some View {
        let side = CGFloat(RailDLayout.spreadArtSide(leftWidth: leftWidth, containerHeight: Double(height),
                                                     minSide: Double(FoldedStyle.artMinSide),
                                                     maxSide: Double(FoldedStyle.artMaxSide)))
        return VStack(spacing: 0) {
            RailDStationHeader(name: heading.header.name)
            Spacer(minLength: CGFloat(RailDLayout.spreadArtVerticalInset))
            FoldedArtCard(track: track, station: station, isOnAir: false,
                          side: side, namespace: artworkNamespace, speechLevel: speechLevel)
                .frame(maxWidth: .infinity)
                .id(DisplayContinuity.artAnchor)
            Spacer(minLength: CGFloat(RailDLayout.spreadArtVerticalInset))
        }
        .frame(minHeight: height)
    }

    /// L1 trailing half: title, artist, the DJ chip (left-aligned with the title, the mock's
    /// centred chip was wrong) and Up next, vertically centred to the art (the same header
    /// height above both). Then the error banner and the station dial.
    private func spreadContent(gap: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: CGFloat(RailDLayout.openHeaderHeight))
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                if let track = heroTrack {
                    FoldedTitleBlock(track: track, isTestStation: isTestStation,
                                     displaySize: CGFloat(RailDLayout.openTitlePointSize))
                }
                FoldedDJStatus(dj: dj, fitsOneLine: true)
                    .padding(.top, CGFloat(FoldedColumnLayout.Spacing.titleToStatus))
                if DuoPresentation.showsVisualizer(isOnAir: dj.state.isOnAir), let track = heroTrack {
                    DJLavaOrb(track: track, station: station, levels: speechLevel)
                        .frame(width: 120, height: 120)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("folded.visualizer")
                        .padding(.top, gap)
                }
                PlaybackErrorBanner(error: snapshot.error, actions: actions)
                    .duoColumnWidth()
                    .padding(.top, gap)
                DuoUpNextList(dj: dj, track: heroTrack, queued: snapshot.upNext, onOpen: onQueue)
                    .padding(.top, gap)
                if stationStops.count > 1, let onOpenStation {
                    DuoStationDial(stops: stationStops, openedID: heading.opened.id,
                                   playingID: StationTapRoute.dialPlayingID(snapshot), onOpen: onOpenStation)
                        .padding(.top, gap)
                }
            }
            Spacer(minLength: gap)
        }
        .padding(.leading, CGFloat(RailDLayout.spreadTrailingInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// L2 (fold inactive: the Duo is flat): art and title centred across the player area, the
    /// DJ chip, Up next, the banner and the dial shifted into the trailing half, after the fold
    /// band, so even here no control sits on the centre line.
    private func openCentredBody(in size: CGSize, layout: FoldedColumnLayout.DuoHorizontal,
                                 systemBar: Bool, gap: CGFloat,
                                 trailingInset: CGFloat, railTop: CGFloat, thumbnail: StationRef?,
                                 showsWash: Bool) -> some View {
        let playerWidth = layout.leftWidth + layout.foldGutter + layout.contentWidth
            + (systemBar ? layout.barWidth : 0)
        let side = CGFloat(RailDLayout.centredArtSide(playerWidth: playerWidth, containerHeight: Double(size.height),
                                                      minSide: Double(FoldedStyle.artMinSide),
                                                      maxSide: Double(FoldedStyle.artMaxSide)))
        let trailingStart = CGFloat(layout.leftWidth + layout.foldGutter + RailDLayout.spreadTrailingInset)
        return HStack(alignment: .top, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        RailDStationHeader(name: heading.header.name)
                            .frame(width: CGFloat(layout.leftWidth), alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let track = heroTrack {
                            FoldedArtCard(track: track, station: station, isOnAir: false,
                                          side: side, namespace: artworkNamespace, speechLevel: speechLevel)
                                .id(DisplayContinuity.artAnchor)
                            FoldedTitleBlock(track: track, isTestStation: isTestStation, centered: true,
                                             displaySize: CGFloat(RailDLayout.openTitlePointSize))
                                .padding(.top, CGFloat(FoldedColumnLayout.Spacing.artToTitle))
                                .id(DisplayContinuity.titleAnchor)
                        }
                    }
                    .frame(width: CGFloat(playerWidth))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("folded.trackColumn")
                    .accessibilitySortPriority(2)
                    VStack(alignment: .leading, spacing: gap) {
                        FoldedDJStatus(dj: dj, fitsOneLine: true)
                        PlaybackErrorBanner(error: snapshot.error, actions: actions)
                            .duoColumnWidth()
                        DuoUpNextList(dj: dj, track: heroTrack, queued: snapshot.upNext, onOpen: onQueue)
                        if stationStops.count > 1, let onOpenStation {
                            DuoStationDial(stops: stationStops, openedID: heading.opened.id,
                                           playingID: StationTapRoute.dialPlayingID(snapshot), onOpen: onOpenStation)
                        }
                    }
                    .padding(.top, gap)
                    .frame(width: CGFloat(playerWidth) - trailingStart, alignment: .leading)
                    .padding(.leading, trailingStart)
                    .frame(width: CGFloat(playerWidth), alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("folded.contentColumn")
                    .accessibilitySortPriority(1)
                }
                .frame(width: CGFloat(playerWidth))
                .frame(minHeight: size.height, alignment: .center)
                .scrollTargetLayout()
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollContentBackground(.hidden)
            .scrollPosition(id: scrollAnchor)
            .frame(width: CGFloat(playerWidth), height: size.height, alignment: .top)
            .background { if showsWash { dayWash.accessibilityHidden(true) } }

            if !systemBar, layout.barWidth > 0 {
                unfoldedRail(width: CGFloat(layout.barWidth), height: size.height,
                             top: railTop, thumbnail: thumbnail)
            }
        }
        .padding(.leading, CGFloat(layout.edgeInset))
        .padding(.trailing, trailingInset)
    }

    /// 34 pt in a two-halves column, 28 pt where the column is narrow (D's sidebar frame).
    private func openTitleSize(column: Double) -> CGFloat {
        CGFloat(column >= RailDLayout.largeTitleMinColumn
                ? RailDLayout.openTitlePointSize : RailDLayout.railColumnTitlePointSize)
    }

    /// The rail's vertical song-position bar (mockup D): the same inputs as the horizontal
    /// scrubber it replaces. Nil with no track or no known duration.
    private var railScrubber: RailScrubberInput? {
        guard showsProgress, let timeSource else { return nil }
        return RailScrubberInput(time: timeSource, transport: snapshot.transport,
                                 trackID: snapshot.nowPlaying?.id,
                                 canSeek: snapshot.canSeek,
                                 onSeek: { await actions.seek(to: $0, trackID: $1) },
                                 isDJSpeaking: dj.state.isOnAir)
    }

    /// The rail's ⋯ panel over the player, inside the safe box, inward of the rail.
    private func railMorePanel(in size: CGSize) -> some View {
        let menu = DuoMoreMenuLayout.resolve(safeWidth: Double(size.width), safeHeight: Double(size.height))
        return ZStack(alignment: .topTrailing) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { moreOpen = false }
                .accessibilityHidden(true)
            DuoRailMorePanel(reviewCount: moreMenu?.reviewCount,
                             width: CGFloat(menu.width),
                             maxHeight: CGFloat(menu.maxHeight),
                             onConnections: moreMenu?.onConnections ?? {},
                             onTune: onTune,
                             dismiss: { moreOpen = false })
                .modifier(SplitColumnText(enabled: splitBarEdge == .leading))
                .padding(.top, CGFloat(menu.topGap))
                .padding(.trailing, CGFloat(menu.trailingGap))
        }
    }

    /// The unfolded rail itself, the same in `railColumnBody` as in `wideBody`. Sorts last.
    private func unfoldedRail(width: CGFloat, height: CGFloat, top: CGFloat,
                              thumbnail: StationRef? = nil) -> some View {
        DuoVerticalRail(dj: dj, reviewCount: moreMenu?.reviewCount, upNext: snapshot.upNext,
                        onCollapse: onCollapseRail,
                        onConnections: moreMenu?.onConnections ?? {},
                        onQueue: onQueue, onTune: onTune, pause: { actions.pause() },
                        transport: snapshot.transport, startTimedOut: snapshot.startTimedOut,
                        showsTransport: content.showsTransport,
                        cancelStart: { actions.cancelStart() },
                        resume: { await actions.resume() },
                        skip: { await actions.skip() },
                        moreOpen: $moreOpen,
                        scrubber: railScrubber,
                        thumbnail: thumbnail)
            .padding(.top, top)
            .padding(.bottom, 8)
            .frame(width: width, height: height, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("folded.systemBar")
            .accessibilitySortPriority(0)
            .modifier(SplitColumnText(enabled: splitBarEdge == .leading))
    }

    /// Build 51 (-Atlas): the open Duo with the Stations sidebar open. The detail is regular and
    /// window-tall but too narrow for the two halves, so the player is one column beside the same
    /// rail as `wideBody`, which carries Play/Pause, Skip, Queue, ⋯, Collapse and (mockup D, -Nova)
    /// the vertical song-position bar. No Playing-from bar or Queue/Tune buttons: every control
    /// lives in the rail. The column scrolls if the window is short; the rail never does.
    ///
    /// Mockup D (-Nova): tighter insets (16 leading, 12 gutter, 8 trailing) give the column the
    /// width for the DJ chip on one line; the station name heads it; art, title (28 pt when the
    /// column is narrow) and the chip are left-aligned. Side by side, no overlay, in portrait
    /// and landscape alike.
    private func railColumnBody(in size: CGSize) -> some View {
        let gutter = CGFloat(RailDLayout.railColumnGutter)
        // As in `wideBody` (-Atlas): 27.1 draws the rail as the system vertical bar, outside
        // this width.
        let systemBar = DuoVerticalRail.usesSystemBar
        let bar = systemBar ? 0 : FoldedColumnLayout.duoBarWidth
        let column = CGFloat(RailDLayout.railColumnWidth(detailWidth: Double(size.width), barWidth: bar))
        // Header, title and DJ chip under the art. The reserve is Atlas's Core constant
        // (`FoldedColumnLayout.railColumnReserveBelowArt`); only the column is D's.
        let art = CGFloat(RailDLayout.railColumnArtSide(column: Double(column),
                                                        containerHeight: Double(size.height),
                                                        accessibilityTextSize: typeSize.isAccessibilitySize,
                                                        artMin: Double(FoldedStyle.artMinSide),
                                                        artMax: Double(FoldedStyle.artMaxSide)))
        return HStack(alignment: .top, spacing: gutter) {
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        RailDStationHeader(name: heading.header.name)
                        upper(artSide: art, centered: false,
                              titleSize: openTitleSize(column: Double(column)), compactStatus: true,
                              statusWithoutTrack: true)
                    }
                    .frame(width: column)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollContentBackground(.hidden)
                .scrollPosition(id: scrollAnchor)
                .modifier(ContinuityScrollerID(enabled: continuityProbe))
                PlaybackErrorBanner(error: snapshot.error, actions: actions)
                    .padding(.vertical, 12)
                    .frame(width: column)
            }
            .frame(width: column, height: size.height, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("folded.railColumn")
            .accessibilitySortPriority(1)

            if !systemBar {
                unfoldedRail(width: CGFloat(bar), height: size.height, top: 8)
            }
        }
        .padding(.leading, CGFloat(RailDLayout.railColumnLeadingInset))
        .padding(.trailing, CGFloat(RailDLayout.trailingInset))
        .frame(width: size.width, height: size.height)
        .overlay {
            if moreOpen, !systemBar { railMorePanel(in: size) }
        }
    }

    /// Build 51 (-Atlas): the collapsed rail on the open Duo (and the sidebar-open detail). The
    /// centred column with its header row (⋯, then Show rail) pinned at the top and the controls
    /// (scrubber, Play/Skip, the station bar) pinned at the bottom; only the art and title between
    /// them scroll. The scrolling `centredColumnBody` (iPhone landscape) put the transport below
    /// the 820 × 640 window and centred ⋯ halfway down the screen.
    ///
    /// Mockup D (-Nova, Fry's #558 nit 4): deliberately keeps the horizontal scrubber. Collapse
    /// hides the rail, so there is no rail for the vertical bar; Atlas's #552 guarantee is that
    /// Play/Skip and the scrubber stay on screen here. Not one of D's frames.
    ///
    /// `foldAware` is true only on the two `.duoHorizontal` collapsed branches (#507 / #548). In
    /// book pose (`FoldAwareness.bookColumn`) the column moves to one side of the fold and, per
    /// the owner's Nov 17 call, carries the closed screen's Rail D with the song position in the
    /// rail (`bookRailColumnBody`). Outside book pose, and on the sidebar-open detail (false),
    /// this is integration's pinned column unchanged.
    ///
    /// `placementHeight` is the height the caller chose `.duoHorizontal` from (the route height,
    /// `placementSize`). The reader under the navigation bar is shorter (820 x 576 in the 820 x 640
    /// landscape window), and `FoldAwareness.bookColumn` re-checks `.duoHorizontal` on the height
    /// it is given, so the drawn height made book pose fall back to the centred column. -Nova
    private func pinnedColumnBody(in size: CGSize, foldAware: Bool = false,
                                  placementHeight: CGFloat? = nil) -> some View {
        let reserve: Double = typeSize.isAccessibilitySize ? FoldedColumnLayout.centredColumnReserveBelowArtAccessibility : FoldedColumnLayout.centredColumnReserveBelowArt
        let m = FoldedColumnLayout.metrics(containerWidth: Double(size.width),
                                           containerHeight: Double(size.height),
                                           reserveBelowArt: reserve,
                                           artMin: Double(FoldedStyle.artMinSide),
                                           artMax: Double(FoldedStyle.artMaxSide))
        let book: FoldAwareness.BookColumn? = foldAware
            ? FoldAwareness.bookColumn(containerWidth: Double(size.width),
                                       containerHeight: Double(placementHeight ?? size.height),
                                       hinge: effectiveFoldHinge, divisions: effectiveFoldDivisions,
                                       column: m.column, artSide: m.artSide)
            : nil
        let split = book.flatMap { FoldAwareness.bookRailColumn($0) }
        return Group {
            if let split {
                bookRailColumnBody(in: size, split: split)
            } else {
                centredPinnedColumn(in: size, metrics: m)
            }
        }
        .background {
            if foldAware {
                FoldDivisionProbe(hinge: $foldHinge, divisions: $foldDivisions)
            }
        }
    }

    /// Integration's pinned column (build 51, #552): header row, scrolling art and title, then
    /// the horizontal scrubber, Play/Skip and the station bar pinned at the bottom.
    private func centredPinnedColumn(in size: CGSize, metrics m: (artSide: Double, column: Double)) -> some View {
        let column = CGFloat(m.column)
        typealias Gap = FoldedColumnLayout.Spacing
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let moreMenu {
                    FoldedMoreMenu(reviewCount: moreMenu.reviewCount, onConnections: moreMenu.onConnections)
                }
                if let onExpandRail {
                    expandRailButton(onExpandRail)
                }
            }
            .frame(height: CGFloat(FoldedColumnLayout.headerHeight))
            .padding(.horizontal, CGFloat(FoldedColumnLayout.duoEdgeInset))
            ScrollView(.vertical, showsIndicators: false) {
                upper(artSide: CGFloat(m.artSide), centered: true, statusWithoutTrack: true)
                    .padding(.top, CGFloat(Gap.headerToArt))
                    .frame(width: column)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollContentBackground(.hidden)
            .scrollPosition(id: scrollAnchor)
            controls(contentInset: 0, toolbarInset: 0,
                     spacing: CGFloat(Gap.betweenControls), balancesTransport: true)
                .padding(.top, 8)
                .frame(width: column)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folded.wideColumn")
    }

    /// #548, owner's Nov 17 9:53 AM call: the open Duo in book pose with the rail collapsed. The
    /// column sits on one side of the fold (`FoldAwareness.bookColumn`) with the closed screen's
    /// Rail D (`ClosedVerticalRail`: ⋯, Play/Pause, Skip, Queue, Sleep, the vertical song-position
    /// bar, the live dot) on its trailing side, inside the same span. No horizontal scrubber,
    /// transport row or station bar in the column: the rail carries them, and Tune is in the
    /// rail's ⋯ as on the closed screen. Show rail stays in the column's header. -Nova
    private func bookRailColumnBody(in size: CGSize, split: FoldAwareness.BookRailColumn) -> some View {
        typealias Gap = FoldedColumnLayout.Spacing
        let column = CGFloat(split.columnWidth)
        return HStack(alignment: .top, spacing: CGFloat(split.railMinX - split.columnMaxX)) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if let onExpandRail {
                        expandRailButton(onExpandRail)
                    }
                }
                .frame(height: CGFloat(FoldedColumnLayout.headerHeight))
                ScrollView(.vertical, showsIndicators: false) {
                    upper(artSide: CGFloat(split.artSide), centered: true, statusWithoutTrack: true)
                        .padding(.top, CGFloat(Gap.headerToArt))
                        .frame(width: column)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollContentBackground(.hidden)
                .scrollPosition(id: scrollAnchor)
                PlaybackErrorBanner(error: snapshot.error, actions: actions)
                    .padding(.vertical, 12)
            }
            .frame(width: column, height: size.height, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("folded.bookColumn.column")
            .accessibilitySortPriority(1)
            ClosedVerticalRail(dj: dj, upNext: snapshot.upNext,
                               transport: snapshot.transport, startTimedOut: snapshot.startTimedOut,
                               showsTransport: content.showsTransport,
                               pause: { actions.pause() },
                               cancelStart: { actions.cancelStart() },
                               resume: { await actions.resume() },
                               skip: { await actions.skip() },
                               onQueue: onQueue,
                               scrubber: railScrubber) {
                if let moreMenu {
                    FoldedMoreMenu(reviewCount: moreMenu.reviewCount, onConnections: moreMenu.onConnections,
                                   closedItems: closedMoreItems)
                } else {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            }
            .padding(.vertical, CGFloat(RailDLayout.closedVerticalInset))
            .frame(width: CGFloat(split.railWidth), height: size.height)
            .accessibilitySortPriority(0)
        }
        .padding(.leading, CGFloat(split.columnMinX))
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folded.bookColumn")
    }

    /// Show rail (build 51, -Atlas): brings the rail back after Collapse. 44 × 44.
    private func expandRailButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show rail")
        .accessibilityHint("Shows the controls rail. Music continues.")
        .accessibilityIdentifier("folded.expandRail")
    }

    /// Horizontal scrubber, station, and the DJ chip. Play/pause and skip live on the
    /// rail, not in this column. Nothing playing puts Search Apple Music here too: the
    /// left column is artwork and the title, and this column is the only place a
    /// non-rail control is allowed. Each control takes the column width and may grow
    /// downward, so an ideal width cannot centre itself off the column.
    /// The orb appears here only while the DJ is actually on air, and it does not cover the artwork.
    private func wideContent(gap: CGFloat, top: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            if DuoPresentation.showsVisualizer(isOnAir: dj.state.isOnAir), let track = heroTrack {
                DJLavaOrb(track: track, station: station, levels: speechLevel)
                    .frame(width: 120, height: 120)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("folded.visualizer")
            }
            // Mockup D: the DJ chip sits under the title in the track column. Nothing playing
            // still shows its status here.
            if heroTrack == nil {
                FoldedDJStatus(dj: dj)
                    .duoColumnWidth()
            }
            PlaybackErrorBanner(error: snapshot.error, actions: actions)
                .duoColumnWidth()
            if case .nothingPlaying = content, search != nil {
                ViewThatFits(in: .horizontal) {
                    SearchAppleMusicButton(action: onQueue)
                    SearchAppleMusicButton(action: onQueue, title: "Search", showsTitle: true)
                    SearchAppleMusicButton(action: onQueue, title: "Search", showsTitle: false)
                }
                .duoColumnWidth()
            }
            // Mockup D: the song position is the rail's vertical bar; the station name heads the
            // track column (`RailDStationHeader`) and Queue is on the rail, so no chip here.
            if stationStops.count > 1, let onOpenStation {
                DuoStationDial(stops: stationStops, openedID: heading.opened.id,
                               playingID: StationTapRoute.dialPlayingID(snapshot), onOpen: onOpenStation)
            }
            DuoUpNextList(dj: dj, track: heroTrack, queued: snapshot.upNext, onOpen: onQueue)
            Spacer(minLength: gap)
        }
        .padding(.top, top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A still wash behind the art, from the clock's day part. It does not animate.
    /// The day part is re-read at the top of each calendar hour so the tint does not go stale.
    private var dayWash: some View {
        let calendar = Calendar.current
        return TimelineView(CalendarHourSchedule()) { context in
            let hour = calendar.component(.hour, from: context.date)
            let opacity = DuoPresentation.washOpacity(reduceTransparency: reduceTransparency)
            DuoDayWashFill(part: DayPart(hour: hour))
                .opacity(opacity)
                .allowsHitTesting(false)
                .accessibilityIdentifier("folded.dayWash")
        }
        // A parent transaction must not animate the hourly gradient swap.
        .transaction { $0.disablesAnimations = true }
    }

    private var heroTrack: TrackInfo? {
        if case .track(let track) = content { return track }
        return nil
    }

    /// Square art: the column width less the gutters, capped so the title and the pinned
    /// controls stay on screen. Only the container decides; no device size is named.
    private func artSide(in size: CGSize) -> CGFloat {
        let byWidth = size.width - FoldedStyle.contentInset * 2
        if typeSize.isAccessibilitySize {
            // #310: phone width at accessibility sizes only.
            let byHeight = size.height - FoldedStyle.artReserveAccessibility
            return max(FoldedStyle.artMinSideAccessibility, min(byWidth, byHeight, FoldedStyle.artMaxSide))
        }
        let byHeight = size.height - 430
        return max(FoldedStyle.artMinSide, min(byWidth, byHeight, FoldedStyle.artMaxSide))
    }

    // MARK: Upper (scrolls at large text sizes)

    /// `includesStatus` false: the caller pins the DJ status in the controls instead (#310).
    /// `includesArt` false: phone width at accessibility sizes when the title block would not
    /// fit under the art (#345 review); the title then starts at the top.
    /// `includesSearch` is false on the Duo: Search Apple Music lives in the content column.
    @ViewBuilder
    private func upper(artSide: CGFloat, centered: Bool, includesStatus: Bool = true,
                       includesArt: Bool = true, keepArtVisible: Bool = false,
                       includesSearch: Bool = true, titleSize: CGFloat? = nil,
                       compactStatus: Bool = false, statusWithoutTrack: Bool = false) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 0) {
            switch content {
            case .track(let track):
                if includesArt {
                    FoldedArtCard(track: track, station: station,
                                  isOnAir: keepArtVisible ? false : dj.state.isOnAir,
                                  side: artSide, namespace: artworkNamespace, speechLevel: speechLevel)
                        .frame(maxWidth: .infinity)
                        .id(DisplayContinuity.artAnchor)
                }
                FoldedTitleBlock(track: track, isTestStation: isTestStation, centered: centered,
                                 displaySize: titleSize)
                    .padding(.top, includesArt
                             ? (centered ? CGFloat(FoldedColumnLayout.Spacing.artToTitle) : 24) : 0)
                    .id(DisplayContinuity.titleAnchor)
                if includesStatus {
                    FoldedDJStatus(dj: dj, fitsOneLine: compactStatus)
                        .padding(.top, centered ? CGFloat(FoldedColumnLayout.Spacing.titleToStatus) : 16)
                }
            case .nothingPlaying:
                testTag
                NowPlayingPlaceholder(content: content, actions: actions)
                    .padding(.top, 24)
                idleStatus(statusWithoutTrack, compact: compactStatus)
                // #454: search is never a station's empty state; it sits behind an explicit
                // button that opens the Queue workspace (where `StartListeningView` lives).
                if includesSearch, search != nil {
                    SearchAppleMusicButton(action: onQueue)
                        .padding(.top, 16)
                }
            default:
                testTag
                NowPlayingPlaceholder(content: content, actions: actions)
                    .padding(.top, 24)
                idleStatus(statusWithoutTrack, compact: compactStatus)
            }
            if continuityProbe { continuityRows }
        }
        .scrollTargetLayout()
    }

    /// Echo (#558): with no track the rail column and the collapsed pinned column still show
    /// the DJ chip, as `wideContent` does when `heroTrack == nil`. Off everywhere else.
    @ViewBuilder
    private func idleStatus(_ shows: Bool, compact: Bool) -> some View {
        if shows {
            FoldedDJStatus(dj: dj, fitsOneLine: compact)
                .padding(.top, 16)
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
        // #454: a starting or failed station still offers its Queue and Tune.
        case .track, .nothingPlaying, .starting, .startFailed, .startUnavailable: true
        default: false
        }
    }

    /// Phone: inset by the wireframe gutters and pinned under the scroll. Wide: no inset (the
    /// column already sets the width) and Play/Pause centred on the column.
    /// `pinsStatus`: phone width at accessibility sizes (#310), the DJ status sits here, above
    /// the scrubber, instead of in the scrolling upper part. Idle draws nothing.
    private func controls(contentInset: CGFloat, toolbarInset: CGFloat, spacing: CGFloat,
                          balancesTransport: Bool, pinsStatus: Bool = false) -> some View {
        VStack(spacing: spacing) {
            if pinsStatus, case .track = content {
                FoldedDJStatus(dj: dj)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, contentInset)
            }
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


extension FoldedPlayer {
    /// 01-folded outer-screen reskin. Called at phone width whenever a track is showing
    /// (`FoldedOuterLayout.usesOuterReskin`). Transport still goes through `TransportTapPolicy`.
    /// There is no Previous: `PlaybackActions` has none. The mockup's tab bar is not
    /// drawn; the existing Queue / Tune toolbar stays, restyled as a glass capsule.
    ///
    /// Same structure as `compactBody`: a scrolling upper part over pinned controls. At
    /// accessibility sizes (#310 / #345) the DJ status moves into the pinned controls above
    /// the scrubber, and the upper part drops the art, then scrolls, so the title, the
    /// TEST STATION tag and Play/Pause all stay on screen.
    ///
    /// Mockup D (-Nova): one 56 pt glass rail runs the full height on the trailing side (⋯,
    /// Play/Pause, Skip, Queue, Sleep, the vertical song-position bar, the live dot). The
    /// horizontal scrubber is gone; the header (Back, station) and the column sit beside the
    /// rail, and the freed row goes to a bigger title (40 / 17).
    private func foldedOuterBody(in size: CGSize) -> some View {
        let inset = CGFloat(FoldedOuterLayout.contentInset)
        let accessibilityText = typeSize.isAccessibilitySize
        let art = outerArtSide(in: size)
        let railInset = CGFloat(RailDLayout.closedVerticalInset)
        return HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                FoldedOuterHeader(heading: heading, dismiss: { dismiss() })
                    .padding(.leading, inset)
                    .padding(.top, 8)
                VStack(spacing: 0) {
                    if accessibilityText {
                        ViewThatFits(in: .vertical) {
                            outerUpper(artSide: art, includesArt: true, pinsStatus: true)
                            outerUpper(artSide: art, includesArt: false, pinsStatus: true)
                            outerUpperScroll(artSide: art, showsIndicators: true, pinsStatus: true)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        outerUpperScroll(artSide: art, showsIndicators: false, pinsStatus: false)
                    }
                    // At accessibility sizes the controls keep their full height, so the pinned
                    // ON AIR pill stays on screen. The upper area shrinks or scrolls.
                    outerControls(pinsStatus: accessibilityText)
                        .fixedSize(horizontal: false, vertical: accessibilityText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilitySortPriority(1)
            ClosedVerticalRail(dj: dj, upNext: snapshot.upNext,
                               transport: snapshot.transport, startTimedOut: snapshot.startTimedOut,
                               showsTransport: content.showsTransport,
                               pause: { actions.pause() },
                               cancelStart: { actions.cancelStart() },
                               resume: { await actions.resume() },
                               skip: { await actions.skip() },
                               onQueue: onQueue,
                               scrubber: railScrubber) {
                // #537's ⋯ (Tune, the star, Connections) moves from the header to the rail top.
                if let moreMenu {
                    FoldedMoreMenu(reviewCount: moreMenu.reviewCount, onConnections: moreMenu.onConnections,
                                   closedItems: closedMoreItems)
                } else {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            }
            .padding(.vertical, railInset)
            .padding(.trailing, CGFloat(RailDLayout.trailingInset))
            .accessibilitySortPriority(0)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folded.outer")
    }

    /// Art for the reskin: the column beside the closed rail less its insets, capped by height
    /// like `artSide(in:)` so the title, the DJ line and the pinned controls fit. At
    /// accessibility sizes it uses compactBody's #310 floor and reserve.
    private func outerArtSide(in size: CGSize) -> CGFloat {
        let byWidth = CGFloat(FoldedOuterLayout.columnWidthBesideRail(containerWidth: Double(size.width))
                              - FoldedOuterLayout.artInsetBesideRail * 2)
        if typeSize.isAccessibilitySize {
            let byHeight = size.height - FoldedStyle.artReserveAccessibility
            return max(FoldedStyle.artMinSideAccessibility, min(byWidth, byHeight, FoldedStyle.artMaxSide))
        }
        // #537: the freed rows go to the art; the trailing rail takes its width. D: the
        // scrubber row goes too, less what the 40 / 17 title takes back.
        return CGFloat(RailDLayout.closedArtSide(containerWidth: Double(size.width),
                                                 containerHeight: Double(size.height),
                                                 minSide: Double(FoldedStyle.artMinSide),
                                                 maxSide: Double(FoldedStyle.artMaxSide)))
    }

    /// #537: what the closed ⋯ menu adds (Queue, Tune, the star). Queue and Tune keep their
    /// ids and actions; the star is the same rating controller the title row used.
    private var closedMoreItems: FoldedClosedMoreItems {
        FoldedClosedMoreItems(track: heroTrack, upNext: snapshot.upNext,
                              showsWorkspaceButtons: showsWorkspaceButtons,
                              onQueue: onQueue, onTune: onTune,
                              queueOnRail: true)
    }

    /// Art, title row and (default sizes) the quiet DJ line. `pinsStatus`: the status pill and
    /// the DJ line are drawn in `outerControls` instead.
    private func outerUpper(artSide: CGFloat, includesArt: Bool, pinsStatus: Bool) -> some View {
        let inset = CGFloat(FoldedOuterLayout.contentInset)
        return VStack(spacing: 0) {
            if let track = heroTrack {
                if includesArt {
                    FoldedArtCard(track: track, station: station,
                                  isOnAir: dj.state.onAirLabel != nil,
                                  side: artSide, namespace: artworkNamespace, speechLevel: speechLevel,
                                  cornerRadius: CGFloat(FoldedOuterLayout.artRadius))
                        // #537: the MIC chip is a badge on the art corner, only while live.
                        .overlay(alignment: .topLeading) {
                            if let badge = FoldedOuterLayout.artBadge(for: FoldedOuterLayout.status(of: dj.state),
                                                                      statusPinned: pinsStatus) {
                                FoldedOuterStatusPill(status: badge)
                                    .padding(12)
                            }
                        }
                        .padding(.top, 12)
                        .padding(.horizontal, CGFloat(FoldedOuterLayout.artInsetBesideRail))
                }
                FoldedOuterTitleRow(track: track, isTestStation: isTestStation,
                                    statusPinned: pinsStatus)
                    .padding(.horizontal, inset)
                    .padding(.top, includesArt ? 16 : 8)
                if !pinsStatus {
                    FoldedOuterDJLine(dj: dj)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, inset)
                        .padding(.top, 12)
                    // #545: the voice-unavailable caption stays with the DJ line, above the
                    // rail's Play/Pause, so VoiceOver reads it before the transport.
                    if showsCaptionInUpper(pinsStatus: pinsStatus) {
                        PlaybackErrorBanner(error: snapshot.error, actions: actions)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, inset)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The continuity capture's scroll rows (probe launches only). Shared by compactBody and
    /// the outer reskin, so the folded phone keeps the scroll anchor whichever body draws it.
    private var continuityRows: some View {
        ForEach(0..<8, id: \.self) { index in
            Text("Continuity row \(index)")
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
                .id(DisplayContinuity.rowAnchor(index))
                .accessibilityIdentifier(DisplayContinuity.rowAnchor(index))
        }
    }

    /// Scrolls like compactUpperScroll: the same anchor binding and probe id, so #501's
    /// scroll continuity holds on the reskinned folded phone too (#535).
    private func outerUpperScroll(artSide: CGFloat, showsIndicators: Bool, pinsStatus: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: showsIndicators) {
            VStack(spacing: 0) {
                outerUpper(artSide: artSide, includesArt: true, pinsStatus: pinsStatus)
                if continuityProbe {
                    continuityRows.padding(.horizontal, CGFloat(FoldedOuterLayout.contentInset))
                }
            }
            .scrollTargetLayout()
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        .scrollPosition(id: scrollAnchor)
        .modifier(ContinuityScrollerID(enabled: continuityProbe))
    }

    /// #545: at default sizes a caption-style error (speechFailed) is drawn under the DJ line
    /// in the upper part, not in the pinned controls, which now sit level with the rail's
    /// Play/Pause. Banners (with Retry / Dismiss) stay above the scrubber.
    private func showsCaptionInUpper(pinsStatus: Bool) -> Bool {
        guard !pinsStatus, heroTrack != nil, let p = PlaybackErrorPresentation(snapshot.error) else { return false }
        return p.style == .caption
    }

    /// Pinned under the upper part. `pinsStatus` (accessibility sizes): the status pill and the
    /// quiet DJ line sit here, above the scrubber, so ON AIR is on screen without scrolling.
    private func outerControls(pinsStatus: Bool) -> some View {
        let inset = CGFloat(FoldedOuterLayout.contentInset)
        return VStack(spacing: 0) {
            if pinsStatus {
                VStack(alignment: .leading, spacing: 8) {
                    // #537: ON AIR only; Mic down draws no chip.
                    if let pill = FoldedOuterLayout.pinnedPill(for: FoldedOuterLayout.status(of: dj.state)) {
                        FoldedOuterStatusPill(status: pill)
                    }
                    FoldedOuterDJLine(dj: dj)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inset)
                .padding(.top, 8)
                // 16, as compactBody's pinned status: the scrubber's frame starts above its track.
                .padding(.bottom, 16)
            }
            if !showsCaptionInUpper(pinsStatus: pinsStatus) {
                PlaybackErrorBanner(error: snapshot.error, actions: actions)
                    .padding(.horizontal, inset)
            }
            // Mockup D: the song position is the rail's vertical bar (`RailScrubber`), not a
            // horizontal scrubber here.
            // #537: Play/Pause and Skip are on the trailing rail (`ClosedVerticalRail`).
            // #537: no NEXT row and no Playing-from row when closed. Their Queue and Tune
            // actions are in the rail's ⋯ menu (`FoldedClosedMoreItems`); D puts Queue on the rail.
        }
        .padding(.bottom, 16)
    }
}

private extension View {
    /// Take the proposed column width and the view's own height. An ideal width then
    /// cannot centre the control past the column's leading edge.
    func duoColumnWidth() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}


// MARK: - 01-folded outer reskin

/// Back, the opened station, and ⋯. Replaces the system navigation bar while the reskin shows.
/// Mockup D (-Nova): ⋯ moved to the top of the closed rail; a 44 pt clear slot keeps the
/// station name centred between Back and the rail.
private struct FoldedOuterHeader: View {
    let heading: StationHeading
    let dismiss: () -> Void
    @ScaledMetric(relativeTo: .headline) private var stationNameSize: CGFloat = 17

    var body: some View {
        HStack(spacing: 8) {
            Button(action: dismiss) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .foldedGlass(Circle(), role: .control)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("folded.back")
            Spacer(minLength: 0)
            VStack(spacing: 3) {
                Text("Station")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(red: FoldedOuterLayout.playRingRed,
                                           green: FoldedOuterLayout.playRingGreen,
                                           blue: FoldedOuterLayout.playRingBlue))
                Text(heading.header.name)
                    .font(.system(size: stationNameSize, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Station, \(heading.header.name)")
            .accessibilityAddTraits(.isHeader)
            // #537: the header names the station now that the Playing-from chip is gone.
            .accessibilityIdentifier("station.title")
            Spacer(minLength: 0)
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
    }
}

/// #537: one-line title and one-line artist. The On Air chip is an art badge and the star
/// is in the ⋯ menu, so neither is drawn here.
private struct FoldedOuterTitleRow: View {
    let track: TrackInfo
    let isTestStation: Bool
    /// True at accessibility sizes: ON AIR is pinned above the scrubber, so the tag leads.
    var statusPinned = false
    // Mockup D (-Nova): 40 / 17, up from #537's 34 / 15; the scrubber row's height went to the type.
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = CGFloat(RailDLayout.closedTitlePointSize)
    @ScaledMetric(relativeTo: .subheadline) private var artistSize = CGFloat(RailDLayout.closedArtistPointSize)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Accessibility sizes (pill pinned in the controls): the tag leads the row, so it
            // stays on screen above ON AIR when a long AX5 title pushes the rest out of view.
            if isTestStation, statusPinned {
                FoldedTestStationTag().padding(.bottom, 2)
            }
            Text(track.title)
                .font(.system(size: titleSize, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(.white)
                .lineLimit(FoldedOuterLayout.titleLineLimit)
                .truncationMode(.tail)
            Text(track.artistName)
                .font(.system(size: artistSize, weight: .semibold))
                .foregroundStyle(FoldedStyle.secondaryInk)
                .lineLimit(FoldedOuterLayout.artistLineLimit)
                .truncationMode(.tail)
            if isTestStation, !statusPinned {
                FoldedTestStationTag().padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.title), \(track.artistName)")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("folded.titleBlock")
    }
}

/// The quiet DJ line under the title: ready ("DJ break after this song", Fry #161), preparing,
/// or a voice/budget failure, exactly as `compactBody` draws it (`FoldedDJStatus`, same ids).
/// Speaking draws nothing here: the status pill carries ON AIR and its timer.
private struct FoldedOuterDJLine: View {
    let dj: DJStatusPresentation

    var body: some View {
        if case .speaking = dj.state {
            EmptyView()
        } else {
            FoldedDJStatus(dj: dj)
        }
    }
}

/// On Air (with the same timer and VoiceOver value as `FoldedOnAirPill`: "On Air, 0:12") or
/// Mic down. Text scales with Dynamic Type; the 28 pt height is a floor.
private struct FoldedOuterStatusPill: View {
    let status: FoldedOuterLayout.Status
    @State private var startedAt = Date()
    @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 9

    var body: some View {
        switch status {
        case .onAir(let text):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let time = PlaybackTimeFormat.label(FoldedOnAirPill.elapsed(at: context.date, since: startedAt))
                pill(text: text, time: time)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(text), \(time)")
            }
            .accessibilityIdentifier("dj.onAir")
        case .micDown:
            pill(text: label, time: nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibility)
                .accessibilityIdentifier(identifier)
        }
    }

    private func pill(text: String, time: String?) -> some View {
        HStack(spacing: 8) {
            ember
            Text(text)
                .font(.system(size: labelSize, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
            if let time {
                Text(time)
                    .font(.system(size: labelSize, weight: .bold).monospacedDigit())
                    .foregroundStyle(FoldedStyle.onAirTimer)
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(minHeight: CGFloat(FoldedOuterLayout.statusPillHeight))
        .background(Color(red: 17 / 255, green: 21 / 255, blue: 28 / 255), in: Capsule())
    }

    private var label: String {
        switch status {
        case .onAir(let text): text
        case .micDown: "Mic down"
        }
    }

    private var accessibility: String {
        switch status {
        case .onAir(let text): text
        case .micDown: "Mic down"
        }
    }

    private var identifier: String {
        switch status {
        case .onAir: "dj.onAir"
        case .micDown: "dj.micDown"
        }
    }

    private var ink: Color {
        switch status {
        case .onAir: FoldedStyle.onAirAmber
        case .micDown: Color.white.opacity(0.62)
        }
    }

    @ViewBuilder
    private var ember: some View {
        switch status {
        case .onAir:
            Circle().fill(FoldedStyle.onAirAmber).frame(width: 8, height: 8)
        case .micDown:
            Circle()
                .fill(RadialGradient(colors: [
                    Color(red: 0.54, green: 0.29, blue: 0.17),
                    Color(red: 0.29, green: 0.13, blue: 0.09),
                ], center: .center, startRadius: 0, endRadius: 6))
                .frame(width: 12, height: 12)
        }
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

/// Album art (or station art) in a 24 pt card with one soft glow. While ON AIR the art and its
/// glow are gone and only the lava-lamp orb (`DJLavaOrb`) shows in the card's frame, coloured
/// by the same art and driven by the DJ voice level (owner, Nov 9 2026). They cross-fade
/// (`FoldedArtCardLayers`); the frame keeps its size, so the layout never jumps.
private struct FoldedArtCard: View {
    let track: TrackInfo
    let station: StationRef?
    let isOnAir: Bool
    let side: CGFloat
    let namespace: Namespace.ID?
    var speechLevel: DJPresentationStore? = nil
    /// Default is the compact-path 24 pt token. The 01-folded reskin passes 28.
    var cornerRadius: CGFloat = FoldedStyle.artRadius

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var layers: FoldedArtCardLayers { .layers(isOnAir: isOnAir) }

    var body: some View {
        ZStack {
            // One soft glow from the same art (none on air).
            BleedArtwork(track: track, station: station)
                .frame(width: side * 0.88, height: side * 0.9)
                .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                .blur(radius: 34)
                .opacity(layers.glowOpacity)
                .offset(y: 20)
            card
                .frame(width: side, height: side)
                .modifier(BleedArtFrame(namespace: namespace))
        }
        .frame(width: side, height: side)
        .animation(.easeInOut(duration: FoldedArtCardLayers.crossfadeSeconds), value: isOnAir)
        // VoiceOver never sees the card. XCUITest can't query a hidden element either
        // (iOS 43658288607: no folded.artCard.* in the tree), so only the Debug on-air
        // capture exposes it, as a label-less element. The id follows the visible layers
        // so the capture can assert orb-only (`folded.artCard.orb`) versus art
        // (`folded.artCard.artwork`). Accessibility only; no pixel changes.
        .modifier(ArtCardTestExposure(identifier: Self.testIdentifier(layers: layers)))
    }

    /// `folded.artCard.orb` when only the orb is showing; `folded.artCard.artwork` when
    /// only the art is showing. Mixed opacity during the cross-fade uses `folded.artCard`.
    private static func testIdentifier(layers: FoldedArtCardLayers) -> String {
        if layers.showsOrb && layers.artworkOpacity == 0 { return "folded.artCard.orb" }
        if !layers.showsOrb && layers.artworkOpacity > 0 { return "folded.artCard.artwork" }
        return "folded.artCard"
    }

    /// The art and the orb in one fixed frame, so the swap never changes the card's size.
    private var card: some View {
        ZStack {
            BleedArtwork(track: track, station: station)
                .clipShape(shape)
                .overlay(shape.strokeBorder(FoldedStyle.hairline, lineWidth: 1))
                .opacity(layers.artworkOpacity)
            if layers.showsOrb {
                DJLavaOrb(track: track, station: station, levels: speechLevel)
                    .frame(width: side * FoldedArtCardLayers.orbFraction, height: side * FoldedArtCardLayers.orbFraction)
                    .transition(.opacity)
            }
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
    /// Mockup D (-Nova): the open Duo's display title (34 pt, 28 pt in the narrow rail column),
    /// scaled with Dynamic Type. Nil keeps title2 / body, as before.
    var displaySize: CGFloat? = nil
    /// Station ratings (-Nova, PR B). Nil or unavailable: the block is exactly the labels, as before.
    @Environment(\.songRating) private var songRating
    @ScaledMetric(relativeTo: .largeTitle) private var displayScale: CGFloat = 1

    private var titleFont: Font {
        guard let displaySize else { return .system(.title2, weight: .bold) }
        return .system(size: displaySize * displayScale, weight: .heavy)
    }

    private var artistFont: Font {
        displaySize == nil ? .body : .title3.weight(.semibold)
    }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 4) {
            if let songRating, songRating.isAvailable {
                // Station ratings (-Nova, PR B): the button trails the artist line (under the
                // centred labels in the wide column); the labels stay one accessibility element.
                if centered {
                    labels
                    SongRatingButton(controller: songRating, track: track, ink: FoldedStyle.secondaryInk)
                } else {
                    HStack(alignment: .foldedRatingArtistLine, spacing: 8) {
                        labels.frame(maxWidth: .infinity, alignment: .leading)
                        SongRatingButton(controller: songRating, track: track, ink: FoldedStyle.secondaryInk)
                            .alignmentGuide(.foldedRatingArtistLine) { $0[VerticalAlignment.center] }
                    }
                }
            } else {
                labels
            }
            if isTestStation {
                FoldedTestStationTag().padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private var labels: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 4) {
            Text(track.title)
                .font(titleFont)
                .tracking(-0.4)
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(track.artistName)
                .font(artistFont)
                .foregroundStyle(FoldedStyle.secondaryInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                // Read only by the rated row above; no effect on the plain block.
                .alignmentGuide(.foldedRatingArtistLine) { $0[VerticalAlignment.center] }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track.title), \(track.artistName)")
        .accessibilityAddTraits(.isHeader)
        // Mockup D (-Nova): new id so the UI tests can line the DJ chip up with the title.
        .accessibilityIdentifier("folded.titleBlock")
    }
}

private extension VerticalAlignment {
    /// The artist line's centre: where the folded rating button sits (-Nova, PR B).
    enum FoldedRatingArtistLine: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let foldedRatingArtistLine = VerticalAlignment(FoldedRatingArtistLine.self)
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
            .accessibilityIdentifier("folded.testStation")
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
    /// Mockup D (-Nova): the open Duo's chip. Keep it on one line where it can: the full chip,
    /// then a compact one (smaller type and padding), and only then let it wrap.
    var fitsOneLine = false

    var body: some View {
        switch dj.state {
        case .preparing:
            if let headline = dj.headline {
                capsule(headline: headline, systemImage: "scope", identifier: "dj.preparing")
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
                capsule(headline: headline, systemImage: "clock", identifier: "dj.ready")
            }
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private func capsule(headline: String, systemImage: String, identifier: String) -> some View {
        let full = FoldedStatusCapsule(headline: headline, accessibilityLabel: dj.accessibilityLabel,
                                       systemImage: systemImage, animates: dj.animatesActivity,
                                       identifier: identifier)
        if fitsOneLine {
            let compact = FoldedStatusCapsule(headline: headline, accessibilityLabel: dj.accessibilityLabel,
                                              systemImage: systemImage, animates: dj.animatesActivity,
                                              identifier: identifier, compact: true)
            ViewThatFits(in: .horizontal) {
                full.fixedSize(horizontal: true, vertical: false)
                compact.fixedSize(horizontal: true, vertical: false)
                compact
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            full
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
    /// Mockup D (-Nova): footnote type and tighter padding so a narrow column keeps one line.
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { FoldedReduceMotion.resolve(systemReduceMotion) }

    var body: some View {
        let font: Font = compact ? .footnote.weight(.medium) : .subheadline.weight(.medium)
        return HStack(spacing: compact ? 6 : 8) {
            Image(systemName: systemImage)
                .font(font)
                .accessibilityHidden(true)
            Text(headline)
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.white.opacity(0.85))
        .padding(.leading, compact ? 10 : 12)
        .padding(.trailing, compact ? 12 : 16)
        .frame(minHeight: 32)
        .background { shimmer }
        .foldedGlass(Capsule())
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        // #558 (-Nova): without this the element's frame is the union of the icon and the
        // text (37.3 pt, 18 pt tall on the iPhone), not the 32 pt capsule that is drawn at the
        // title's leading edge (24 pt), so XCUI read the chip 13 pt right of the title.
        // Accessibility only: hit-testing and the drawing are unchanged.
        .contentShape(.accessibility, Capsule())
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
/// view saw that state.
private struct FoldedOnAirPill: View {
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = Self.elapsed(at: context.date, since: startedAt)
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
        .accessibilityIdentifier("dj.onAir")
    }

    /// Seconds on air. Debug only: the `onAir` Studio capture freezes it
    /// (`StudioCaptureOnAir.frozenElapsed`) so `closed-ax5-onair` is the same every run.
    @MainActor
    fileprivate static func elapsed(at now: Date, since startedAt: Date) -> TimeInterval {
        #if DEBUG
        if let frozen = StudioCaptureOnAir.frozenElapsed { return frozen }
        #endif
        return max(0, now.timeIntervalSince(startedAt))
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

/// Horizontal snap between stations. Scrolling only moves the highlight. A station
/// opens on a tap, or on Tune for the highlighted stop, through `onOpen`. A newer
/// tap cancels a pending open. A started open is not cancelled.
private struct DuoStationDial: View {
    let stops: [DuoStationSwitch.Stop]
    let openedID: String
    /// #454: the station actually playing (`StationTapRoute.dialPlayingID`), "" when none. Only that
    /// stop is not reopened; the opened station after a restore is idle and its stop starts it.
    let playingID: String
    let onOpen: (String) async -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Survives the dial being created again when the horizontal layout appears.
    /// `onAppear` must not write the opened station over a stored anchor.
    @SceneStorage("aerodj.duo.dialAnchor") private var storedSnap = ""
    @State private var flight = DuoStationSwitch.Flight(highlightID: "")
    @State private var openTask: Task<Void, Never>?

    private var reduceMotion: Bool { FoldedReduceMotion.resolve(systemReduceMotion) }
    private var snapped: String? { storedSnap.isEmpty ? nil : storedSnap }
    private var highlightedID: String { snapped ?? openedID }

    private var snapBinding: Binding<String?> {
        Binding(
            get: { storedSnap.isEmpty ? nil : storedSnap },
            set: { storedSnap = $0 ?? "" }
        )
    }
    private var highlightedName: String {
        stops.first { $0.id == highlightedID }?.name ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stops) { stop in
                        let selected = stop.id == highlightedID
                        Button {
                            open(stop.id)
                        } label: {
                            Text(stop.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .frame(minWidth: 44, minHeight: 44)
                                .foregroundStyle(.white.opacity(selected ? 1 : 0.72))
                                .foldedGlass(Capsule(), role: .control)
                        }
                        .buttonStyle(.plain)
                        // #562 (-Nova): the 44 pt floor has to be on the button, as in
                        // StudioCapture's split.show buttons. On the iOS 26.5 plain style the
                        // label's minHeight draws the 44 pt capsule but left the stop's
                        // accessibility frame at the text height (18 pt). Same size as the
                        // label, so nothing moves or redraws.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel(stop.name)
                        .accessibilityHint("Plays the station now.")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("duo.station.\(stop.id)")
                        .id(stop.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: snapBinding)
            .scrollBounceBehavior(.basedOnSize)

            Button {
                open(highlightedID)
            } label: {
                Text("Tune")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.horizontal, 8)
                    .foregroundStyle(.white)
                    .foldedGlass(Capsule(), role: .control)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tune \(highlightedName)")
            .accessibilityHint("Plays the highlighted station.")
            .accessibilityIdentifier("duo.stationTune")
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duo.stationDial")
        .accessibilityLabel("Stations")
        .accessibilityValue(highlightedName)
        .accessibilityHint("Swipe up or down to move. Double-tap to play the highlighted station.")
        .accessibilityAdjustableAction { direction in
            guard let index = stops.firstIndex(where: { $0.id == highlightedID }) else { return }
            let next: Int
            switch direction {
            case .increment: next = min(stops.count - 1, index + 1)
            case .decrement: next = max(0, index - 1)
            @unknown default: return
            }
            storedSnap = stops[next].id
        }
        .accessibilityAction(.default) { open(highlightedID) }
        .onAppear {
            #if DEBUG
            if DisplayContinuityLaunch.shouldReset("dial") { storedSnap = "" }
            #endif
            // A stored highlight wins. The opened station is only the default
            // when the dial has never been scrolled, including the first time
            // the horizontal layout creates this view.
            let session = DisplayContinuity.Session(
                selectedStationID: openedID,
                scrollAnchor: storedSnap.isEmpty ? nil : storedSnap,
                playbackToken: "",
                loadCount: 0
            ).appeared(defaultAnchor: openedID)
            if let anchor = session.scrollAnchor, anchor != storedSnap { storedSnap = anchor }
            flight = DuoStationSwitch.Flight(highlightID: storedSnap.isEmpty ? openedID : storedSnap)
        }
        .onChange(of: openedID) { _, id in storedSnap = id }
        .onChange(of: storedSnap) { _, id in
            guard !id.isEmpty else { return }
            _ = flight.receive(.snap(id), playingID: playingID)
        }
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
    }

    /// Tap or Tune. A swipe never reaches this. A newer tap cancels a pending open.
    private func open(_ id: String) {
        storedSnap = id
        guard let token = flight.receive(.tap(id), playingID: playingID) else { return }
        openTask?.cancel()
        openTask = Task {
            guard flight.accepts(token), !Task.isCancelled else { return }
            await onOpen(id)
        }
    }
}


/// Current song, a ready DJ break, and the queued songs. One button: it opens the queue.
/// Nothing here animates, so Reduce Motion changes nothing.
private struct DuoUpNextList: View {
    let dj: DJStatusPresentation
    let track: TrackInfo?
    let queued: [TrackInfo]
    let onOpen: () -> Void

    private var readyBreak: String? {
        if case .ready = dj.state { return dj.headline }
        return nil
    }

    private var lines: [DuoUpNextTimeline.Line] {
        guard let track else { return [] }
        return DuoUpNextTimeline.lines(
            now: .init(title: track.title, artist: track.artistName),
            readyBreak: readyBreak,
            queued: queued.map { .init(title: $0.title, artist: $0.artistName) })
    }

    var body: some View {
        let rows = lines
        return Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(line.title)
                            .font(.subheadline.weight(line.role == .nowPlaying ? .semibold : .regular))
                            .lineLimit(1)
                        if !line.detail.isEmpty {
                            Text(line.detail)
                                .font(.caption)
                                .foregroundStyle(FoldedStyle.secondaryInk)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("duo.upNext.\(line.role.rawValue)")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foldedGlass(RoundedRectangle(cornerRadius: FoldedStyle.fieldRadius, style: .continuous), role: .surface)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(rows.map { $0.detail.isEmpty ? $0.title : "\($0.title), \($0.detail)" }.joined(separator: ". "))
        .accessibilityHint("Opens the queue")
        .accessibilityIdentifier("duo.upNext")
    }
}

/// Yields the start of the current hour, then each following hour start, from `Calendar.current`.
/// A fixed 3600-second period can land up to 59 minutes late and skips or duplicates an hour around DST.
private struct CalendarHourSchedule: TimelineSchedule {
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> some Sequence<Date> {
        DayWashSchedule.hourStarts(from: startDate, calendar: .current)
    }
}

/// Still day-part tint behind Duo artwork. No animation, so Reduce Motion changes nothing.
/// Colours come from `DayWashPalette` so the values stay identical to #462 and Linux can test them.
private struct DuoDayWashFill: View {
    let part: DayPart

    var body: some View {
        let colors = DayWashPalette.colors(for: part)
        LinearGradient(colors: [Color(colors.top).opacity(0.9), Color(colors.bottom).opacity(0)],
                       startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }
}

private extension Color {
    init(_ rgb: DayWashPalette.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
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
            .frame(maxWidth: .infinity, minHeight: FoldedStyle.toolbarHeight, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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
                       hidesSystemBack: Bool = false,
                       onConnections: @escaping () -> Void,
                       systemRail: DuoRailHooks? = nil,
                       keepSystemVerticalBar: Bool = false,
                       barEdge: SplitViewLayout.BarEdge? = nil) -> some View {
        navigationTitle(station.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(hidesSystemBack)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                if showsMore {
                    ToolbarItem(placement: SplitToolbar.placement(
                        preferred: .trailing, edge: barEdge,
                        leading: .topBarLeading, trailing: .topBarTrailing)) {
                        // A split bar copies an identifier on the menu onto the bar item
                        // and the button. The button keeps it. Nil edge is the phone menu.
                        FoldedMoreMenu(reviewCount: reviewCount, onConnections: onConnections,
                                       identifierOnButton: barEdge != nil)
                            .modifier(SplitMinimumTarget(enabled: barEdge != nil))
                    }
                }
            }
            .duoSystemVerticalRail(systemRail, keepBehavior: keepSystemVerticalBar)
    }
}

/// What ⋯ needs when the wide player draws it in its column header.
struct FoldedMoreMenuItems {
    let reviewCount: Int?
    let onConnections: () -> Void
}

/// #537: the closed reskin's extra ⋯ rows. Every other ⋯ passes nil and is unchanged.
struct FoldedClosedMoreItems {
    let track: TrackInfo?
    let upNext: [TrackInfo]
    let showsWorkspaceButtons: Bool
    let onQueue: () -> Void
    let onTune: () -> Void
    /// Mockup D: Queue is a rail button, so ⋯ leaves it out.
    var queueOnRail = false
}

private struct FoldedMoreMenu: View {
    let reviewCount: Int?
    let onConnections: () -> Void
    /// The phone menu and the symbol-bar menu leave this false, so the identifier
    /// stays on the menu. A split navigation bar sets it: the system bar item was
    /// copying the menu's identifier onto an Other and the Button.
    var identifierOnButton = false
    /// #537: Queue, Tune and the star from the closed reskin's removed rows. Nil elsewhere.
    var closedItems: FoldedClosedMoreItems? = nil
    @Environment(\.songRating) private var songRating
    @State private var confirmingClearStation = false

    private var moreLabel: String {
        reviewCount.map { $0 > 0 ? "More, \($0) to review" : "More" } ?? "More"
    }

    var body: some View {
        if identifierOnButton {
            menu(identifierOnLabel: true)
                .accessibilityLabel(moreLabel)
        } else {
            menu(identifierOnLabel: false)
                .accessibilityLabel(moreLabel)
                .accessibilityIdentifier("folded.more")
        }
    }

    private func menu(identifierOnLabel: Bool) -> some View {
        Menu {
            if let closedItems {
                closedRows(closedItems)
                Divider()
            }
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
                .modifier(FoldedMoreButtonIdentifier(enabled: identifierOnLabel))
        }
        .confirmationDialog(SongRatingPresentation.clearStationTitle, isPresented: $confirmingClearStation,
                            titleVisibility: .visible) {
            if let songRating {
                Button(SongRatingPresentation.clearStationTitle, role: .destructive) {
                    Task { await songRating.clearStation() }
                }
            }
        }
    }

    /// Same ids and actions the removed rows had: `queue.affordance` (the Playing-from chip and
    /// the Queue button both opened the queue), `transport.tune`, and `nowPlaying.rating`.
    @ViewBuilder
    private func closedRows(_ items: FoldedClosedMoreItems) -> some View {
        let rating = items.track.flatMap { track in songRating.map { (track, $0) } }
        let available = FoldedOuterLayout.closedMoreItems(
            showsWorkspaceButtons: items.showsWorkspaceButtons,
            canRate: rating.map { $0.1.isAvailable } ?? false,
            queueOnRail: items.queueOnRail)
        ForEach(available, id: \.self) { item in
            switch item {
            case .queue:
                Button(action: items.onQueue) {
                    Label("Queue", systemImage: "list.bullet")
                }
                .accessibilityLabel(items.upNext.first.map { "Queue. Up next: \($0.title) by \($0.artistName)" }
                                    ?? "Queue. Up next: nothing queued")
                .accessibilityIdentifier("queue.affordance")
            case .tune:
                Button(action: items.onTune) {
                    Label("Tune station", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("transport.tune")
            case .rating:
                if case let (track, controller)? = rating {
                    ratingMenu(track: track, controller: controller)
                }
            }
        }
    }

    /// The star's menu, nested in ⋯ (#537). Same rows as `SongRatingButton`.
    private func ratingMenu(track: TrackInfo, controller: SongRatingController) -> some View {
        let current = controller.rating(for: track.id)
        return Menu {
            ForEach(SongRatingPresentation.menuOrder, id: \.self) { level in
                Button(role: level == .never ? .destructive : nil) {
                    Task { await controller.rate(level, songID: track.id, artistName: track.artistName) }
                } label: {
                    Label(SongRatingPresentation.title(level), systemImage: SongRatingPresentation.symbol(level))
                }
                .accessibilityAddTraits(current == level ? .isSelected : [])
            }
            if current != nil {
                Button {
                    Task { await controller.clearRating(songID: track.id) }
                } label: {
                    Label(SongRatingPresentation.clearTitle, systemImage: SongRatingPresentation.clearSymbol)
                }
            }
            Divider()
            Button(SongRatingPresentation.clearStationTitle, role: .destructive) { confirmingClearStation = true }
        } label: {
            // The visible row is the VoiceOver label ("Rate song, current: …"), so the
            // current rating reads the same with and without VoiceOver.
            Label(SongRatingPresentation.accessibilityLabel(current), systemImage: SongRatingPresentation.symbol(current))
        }
        .accessibilityIdentifier("nowPlaying.rating")
    }
}

/// Puts `folded.more` on the menu label. Disabled is the label unchanged, which
/// is the phone menu and the symbol bar.
private struct FoldedMoreButtonIdentifier: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityIdentifier("folded.more")
        } else {
            content
        }
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

#Preview("01-folded reskin") {
    NavigationStack {
        FoldedPlayer(station: PlaybackFixtures.station,
                     heading: StationHeading(opened: PlaybackFixtures.station, playing: PlaybackFixtures.station),
                     isTestStation: false,
                     content: .track(PlaybackFixtures.songs[0]),
                     snapshot: PlaybackFixtures.playing, actions: .preview,
                     dj: .init(state: .idle), search: nil,
                     studioSearch: StudioSearchModel(query: ""), timeSource: .fixture,
                     moreMenu: FoldedMoreMenuItems(reviewCount: nil, onConnections: {}),
                     onQueue: {}, onTune: {}, onReview: {})
    }
}

#endif

/// Hidden from VoiceOver everywhere. In Debug, while the `onAir` capture has frozen the
/// ON AIR timer, the art card is exposed to XCUITest under its layer id. Release and every
/// other run keep it hidden.
private struct ArtCardTestExposure: ViewModifier {
    let identifier: String

    func body(content: Content) -> some View {
        #if DEBUG
        if StudioCaptureOnAir.frozenElapsed != nil {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(identifier)
        } else {
            content.accessibilityHidden(true).accessibilityIdentifier(identifier)
        }
        #else
        content.accessibilityHidden(true).accessibilityIdentifier(identifier)
        #endif
    }
}

/// Build 54 follow-up (-Nova): the open-Duo window as `StationSplitRoot` measured it, for the
/// player's rail. `trailingInset` is the window's trailing unsafe width (the device's status
/// column); `railTop` is the Stations rail glass's top in global points, so the player's rail
/// starts at the same y. Nil on every other window and in captures without the split.
struct OpenDuoWindowMetrics: Equatable, Sendable {
    var trailingInset: CGFloat
    var railTop: CGFloat
}

private struct OpenDuoWindowKey: EnvironmentKey {
    static let defaultValue: OpenDuoWindowMetrics? = nil
}

extension EnvironmentValues {
    var openDuoWindow: OpenDuoWindowMetrics? {
        get { self[OpenDuoWindowKey.self] }
        set { self[OpenDuoWindowKey.self] = newValue }
    }
}
