import AeroDJCore
import SwiftUI

/// The playing screen: one `GeometryReader` decides compact (closed Duo) or Studio (open
/// Duo) through `DisplayContinuity.layout`, the same function the folded player uses.
/// Size class gates the Studio. Folding changes that class and the container. Nothing
/// here creates or restarts playback: the session is app-scoped (`AppDependencies.playback`)
/// and arrives as a snapshot plus actions.
///
/// State that must survive folding lives here, above the switch: the workspace segment
/// (`@SceneStorage`, so it also survives scene restoration), the player scroll anchor,
/// the opened station, the playback token, the search text and whether the compact
/// workspace sheet is open. Unfolding with that sheet open moves its content into
/// Zone B on the same segment. The layout `switch` does not own any of that state,
/// and nothing is keyed on the size class with `.id`.
struct PlayingScreen: View {
    let station: StationRef
    let access: PlaybackAccess
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let search: MusicSearch?
    let studio: StudioPresentationModel
    let isTestStation: Bool
    /// Capture/fixture progress only for now. Live stays nil until Atlas's read-only
    /// playbackTime/currentDuration can be polled (do not reference them here yet).
    var timeSource: PlaybackTimeSource? = nil
    /// Duo station dial. Empty keeps the player as it was.
    var stationStops: [DuoStationSwitch.Stop] = []
    /// The list's station-open action. The dial calls this and nothing else.
    var onOpenStation: ((String) async -> Void)? = nil

    @SceneStorage("aerodj.studio.segment") private var segment: WorkspaceSegment = .queue
    /// Survives the compact / Studio switch and a scene restore. Not `.id`'d on the size class.
    @SceneStorage("aerodj.player.scrollAnchor") private var storedScrollAnchor = ""
    /// Capture readouts only. Debug: the only reader is `StudioCapture`, so Release
    /// must not write the opened station or `transport|track` into scene storage.
    #if DEBUG
    @SceneStorage("aerodj.continuity.station") private var continuityStation = ""
    @SceneStorage("aerodj.continuity.playback") private var continuityPlayback = ""
    #endif
    @State private var showWorkspace = false
    /// Collapse on the unfolded rail shows the centred column. The container size stays,
    /// and nothing starts or stops. A real fold clears it.
    @State private var duoCollapsed = false
    /// One search session above the compact/Studio switch so a fold cannot wipe results.
    @StateObject private var studioSearch = StudioSearchModel()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// System Reduce Motion, or the capture launch flag. The system value is read-only,
    /// so a UI test turns the same paths on with `-AeroDJReduceMotion YES`.
    private var reduceMotion: Bool {
        #if DEBUG
        systemReduceMotion || UserDefaults.standard.bool(forKey: StudioCapture.reduceMotionKey)
        #else
        systemReduceMotion
        #endif
    }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var bleedArt

    private var morphNamespace: Namespace.ID? {
        // UI tests read frames on Zone A. A live matched-geometry effect keeps that
        // query from settling, so capture runs skip the morph. The app still animates it.
        if reduceMotion || ProcessInfo.processInfo.environment["STUDIO_SCREENSHOT_DIR"] != nil { return nil }
        return bleedArt
    }

    private var scrollAnchor: Binding<String?> {
        Binding(
            get: { storedScrollAnchor.isEmpty ? nil : storedScrollAnchor },
            set: { next in
                let stored = next ?? ""
                #if DEBUG
                // The continuity probe scrolls to a row, then the placement switch
                // builds a new scroll view. That view's first layout pass reports
                // the art id. Keep the row so the new view scrolls back to it.
                if storedScrollAnchor.hasPrefix("continuity.row."), !stored.hasPrefix("continuity.row.") {
                    return
                }
                #endif
                if stored != storedScrollAnchor { storedScrollAnchor = stored }
            }
        )
    }

    #if DEBUG
    /// `transport|track`. Only the debug capture reads this; Release does not store it.
    private var playbackToken: String {
        DisplayContinuity.playbackToken(transport: snapshot.transport, trackID: snapshot.nowPlaying?.id)
    }
    #endif

    var body: some View {
        GeometryReader { geo in
            let width = Double(geo.size.width)
            let mode = resolvedMode(containerWidth: width)
            layout(mode: mode, width: width, height: geo.size.height)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: mode)
            #if DEBUG
            .onAppear {
                // A UI test launch clears a scroll anchor left by the previous test.
                // Later appears of this screen (a fold that rebuilds it) do not clear.
                if DisplayContinuityLaunch.shouldReset("player-scroll") {
                    storedScrollAnchor = ""
                }
                if let initial = StudioCaptureSegment.initial {
                    segment = initial
                    StudioCaptureSegment.initial = nil
                    // Closed: the workspace is a sheet, so open it on that segment.
                    // Queue stays on the closed player. Tune and Connections open the sheet.
                    if mode == .compact, initial != .queue { showWorkspace = true }
                }
                // Keep the preview type in the Debug binary. Nothing reads it.
                _ = PlayingScreenPreviewLoader.self
            }
            #endif
            .onChange(of: mode) { _, newMode in
                // The compact sheet's content moves into Zone B on the same segment.
                // This must not search or play, and it must not clear the scroll anchor:
                // folding only changes which column is visible.
                if newMode != .compact { showWorkspace = false }
            }
            #if DEBUG
            .onChange(of: station.id, initial: true) { _, id in
                continuityStation = id
            }
            .onChange(of: playbackToken, initial: true) { _, token in
                continuityPlayback = token
            }
            #endif
        }
        .overlay(alignment: .topLeading) {
            // In front of the player, not in a background layer a pushed column can drop.
            // One element: the selection test counts identifiers that start with this prefix.
            ZStack(alignment: .topLeading) {
                if isTestStation {
                    Text("Studio")
                        .font(.system(size: 1))
                        .frame(width: 4, height: 4)
                        .accessibilityElement()
                        .accessibilityIdentifier(studioIdentity)
                        .accessibilityLabel("Studio")
                }
                if reduceMotion {
                    Text("Reduce Motion")
                        .font(.system(size: 1))
                        .opacity(0.02)
                        .accessibilityIdentifier("motion.reduced")
                        .accessibilityLabel("Reduce Motion")
                }
            }
            .allowsHitTesting(false)
        }
        .transaction(value: reduceMotion) { transaction in
            // Only when Reduce Motion is on. An unconditional transaction here was
            // swallowing the station-list → Studio push animation.
            if reduceMotion { transaction.disablesAnimations = true }
        }
        .background(Color(.systemBackground))
        .environment(\.artStation, currentStation)
        // #454: Try again on a failed station start (the placeholder reads it).
        .environment(\.stationStart, studio.stationStart)
        // #465 item 3: the hinge-detected tent pose swaps in the radio face. No hinge: unchanged.
        .modifier(TentPoseGate(player: tentPlayer))
        .sheet(isPresented: $showWorkspace) {
            NavigationStack {
                workspace
                    .environment(\.artStation, currentStation)
                    .padding(.horizontal, CGFloat(StudioLayoutMetrics.edgeInset))
                    .navigationTitle(heading.header.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showWorkspace = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Each branch sets its own navigation bar. Studio keeps `stationToolbar` with the opened
    /// station, never the playing one: build 9 kept "Morning Calm" there after the owner opened
    /// Late Night, so the next song tap looked like a station jump. Folded uses `foldedToolbar`
    /// (back + ⋯) and names the same opened station in its bottom chip.
    @ViewBuilder
    private func layout(mode: StudioLayoutMode, width: Double, height: CGFloat) -> some View {
        switch mode {
        case .compact:
            // Folded redesign (wireframe 08): back + ⋯ in the bar, the station chip below.
            // iPhone landscape stays the centred column. Only a wide-and-tall container
            // (the unfolded Duo) moves the controls to the right.
            let placement = DisplayContinuity.layout(
                hasRegularWidth: horizontalSizeClass == .regular,
                containerWidth: width,
                containerHeight: Double(height),
                accessibilityTextSize: typeSize.isAccessibilitySize
            ).controlPlacement ?? .phoneBottom
            // The 01-folded reskin draws back and ⋯ itself. FoldedPlayer.body picks its body
            // with the same rule (FoldedOuterLayout.usesOuterReskin: phone width and a track,
            // never height), so the bar and the body cannot disagree.
            let showsTrack: Bool = { if case .track = content { return true } else { return false } }()
            let usesOuterReskin = FoldedOuterLayout.usesOuterReskin(containerWidth: width, showsTrack: showsTrack)
            let showsRail = placement == .duoHorizontal && !duoCollapsed
            let movesMoreIntoThePlayer = placement != .phoneBottom || usesOuterReskin
            let openConnections = { segment = .connections; showWorkspace = true }
            let openQueue = { segment = .queue; showWorkspace = true }
            let openTune = { segment = .tune; showWorkspace = true }
            // Two panes only at regular width, and only for the tall listen layout.
            // Compact width keeps FoldedPlayer, including the phone path, unchanged.
            let arrangement = ArrangementPaneLayout.resolve(
                hasRegularWidth: horizontalSizeClass == .regular,
                containerWidth: width,
                containerHeight: Double(height),
                accessibilityTextSize: typeSize.isAccessibilitySize)
            if case .unchanged = arrangement {
                FoldedPlayer(station: currentStation, heading: heading, isTestStation: isTestStation,
                             content: content, snapshot: snapshot, actions: actions, dj: dj,
                             search: search, studioSearch: studioSearch, timeSource: timeSource,
                             artworkNamespace: morphNamespace, speechLevel: studio.dj,
                             moreMenu: movesMoreIntoThePlayer
                                ? FoldedMoreMenuItems(reviewCount: dj.reviewCount, onConnections: openConnections)
                                : nil,
                             onQueue: openQueue,
                             onTune: openTune,
                             onReview: { segment = .connections; showWorkspace = true },
                             showsUnfoldedRail: showsRail,
                             onCollapseRail: { duoCollapsed = true },
                             stationStops: stationStops,
                             onOpenStation: onOpenStation,
                             scrollAnchor: scrollAnchor)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("layout.compact")
                    .foldedToolbar(heading.header, reviewCount: dj.reviewCount,
                                   showsMore: !movesMoreIntoThePlayer,
                                   hidesSystemBack: showsRail || usesOuterReskin,
                                   onConnections: openConnections,
                                   systemRail: showsRail ? DuoRailHooks(
                                        dj: dj, reviewCount: dj.reviewCount, upNext: snapshot.upNext,
                                        onConnections: openConnections, onQueue: openQueue, onTune: openTune,
                                        onCollapse: { duoCollapsed = true }, pause: { actions.pause() },
                                        transport: snapshot.transport, startTimedOut: snapshot.startTimedOut,
                                        showsTransport: content.showsTransport,
                                        cancelStart: { actions.cancelStart() },
                                        resume: { await actions.resume() },
                                        skip: { await actions.skip() }) : nil,
                                   keepSystemVerticalBar: placement == .duoHorizontal)
                    .onChange(of: placement) { _, new in
                        if new != .duoHorizontal { duoCollapsed = false }
                    }
            } else {
                ArrangementListenPlayer(station: currentStation, heading: heading,
                                        isTestStation: isTestStation, content: content,
                                        snapshot: snapshot, actions: actions, dj: dj,
                                        search: search, timeSource: timeSource,
                                        decision: arrangement,
                                        onQueue: { segment = .queue; showWorkspace = true },
                                        onTune: { segment = .tune; showWorkspace = true },
                                        onConnections: openConnections)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("layout.compact")
                    .foldedToolbar(heading.header, reviewCount: dj.reviewCount,
                                   showsMore: false,
                                   hidesSystemBack: true,
                                   onConnections: openConnections)
            }
        case .studio:
            if let widths = StudioZoneWidths.allocatePanes(containerWidth: width) {
                StudioLayout(widths: widths, containerHeight: height,
                             zoneA: zoneA(),
                             workspace: workspace)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("layout.studio")
                    .stationToolbar(heading.header, isTestStation: isTestStation)
            }
        case .studioStacked:
            StudioStackedLayout(zoneA: zoneA(usesParentScroll: true), workspace: workspace)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("layout.studioStacked")
                .stationToolbar(heading.header, isTestStation: isTestStation)
        }
    }

    /// Only a regular width class can open the Studio; compact or no size class (nil)
    /// collapses to Listen. Otherwise the existing width rule decides Studio vs the stacked
    /// accessibility layout. No device size is named here. The same `DisplayContinuity.layout`
    /// call the folded player makes; height is not an input of this gate.
    private func resolvedMode(containerWidth: Double) -> StudioLayoutMode {
        switch DisplayContinuity.layout(hasRegularWidth: horizontalSizeClass == .regular,
                                        containerWidth: containerWidth,
                                        containerHeight: 0,
                                        accessibilityTextSize: typeSize.isAccessibilitySize) {
        case .studio: .studio
        case .studioStacked: .studioStacked
        case .phoneBottom, .centredColumn, .duoHorizontal: .compact
        }
    }

    private var studioIdentity: String {
        "studio.model.\(String(describing: ObjectIdentifier(studio)))"
    }

    /// Header = the opened station. `currentStation` labels the now-playing track only.
    private var heading: StationHeading { StationHeading(opened: station, playing: snapshot.station) }
    private var currentStation: StationRef { heading.nowPlaying }

    /// Saved genres and moods: identity only. Song picking doesn't use them yet.
    private var soundTags: [String] {
        let active = studio.station.active
        return Array((active.genres + active.moods).prefix(4))
    }

    /// #454: a station row tap shows that station's start state (Starting / Couldn't start /
    /// can't start yet) here, never the empty search screen.
    private var content: NowPlayingContent {
        let start = StationStartStatus.shown(studio.stationStart.state, openedStationID: station.id,
                                             nowPlaying: snapshot.nowPlaying)
        return NowPlayingContent.resolve(access: access, snapshot: snapshot, start: start)
    }

    /// DJ activity comes only from the Studio model (`studio.djState`), which the player
    /// feeds from real audio callbacks. `PlaybackSnapshot.dj` is not used, and no caption
    /// is shown: the contract exposes no clip text.
    private var dj: DJStatusPresentation { DJStatusPresentation(state: studio.djState) }

    private func zoneA(usesParentScroll: Bool = false) -> NowPlayingPanel {
        NowPlayingPanel(station: currentStation, content: content, snapshot: snapshot,
                        actions: actions, dj: dj, soundTags: soundTags,
                        studioSearch: studioSearch, timeSource: timeSource,
                        showsUpNext: segment != .queue,
                        artworkNamespace: morphNamespace,
                        extendsUnderSafeArea: false, usesParentScroll: usesParentScroll,
                        onQueue: { segment = .queue }, onTune: { segment = .tune },
                        onReview: { segment = .connections })
    }

    private var workspace: WorkspaceView {
        WorkspaceView(studio: studio, content: content, snapshot: snapshot, actions: actions,
                      search: access == .authorized ? search : nil,
                      studioSearch: studioSearch, segment: $segment)
    }

    /// The tent face (#465 item 3). Same values and sheet actions as the folded player.
    private var tentPlayer: TentPosePlayer {
        TentPosePlayer(station: currentStation, heading: heading, content: content, snapshot: snapshot,
                       actions: actions, dj: dj, speechLevel: studio.dj,
                       stationStops: stationStops, onOpenStation: onOpenStation,
                       onQueue: { segment = .queue; showWorkspace = true },
                       onTune: { segment = .tune; showWorkspace = true })
    }
}

/// The search field's only stored value. Not `@SceneStorage`, which pushes a stale
/// string back into the field while the next characters are still being typed.
enum SearchText {
    static let key = "aerodj.studio.search"
    static var stored: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

#if DEBUG
#Preview("Playing screen") {
    PlayingScreenPreviewLoader()
}

struct PlayingScreenPreviewLoader: View {
    @State private var studio: StudioPresentationModel?

    var body: some View {
        Group {
            if let studio {
                PlayingScreen(station: PlaybackFixtures.station, access: .authorized,
                              snapshot: PlaybackFixtures.playing, actions: .preview, search: nil,
                              studio: studio, isTestStation: true)
            } else {
                ProgressView()
            }
        }
        .task { studio = await StudioPresentationModel.preview() }
    }
}
#endif
