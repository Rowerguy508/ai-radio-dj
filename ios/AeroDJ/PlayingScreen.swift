import AeroDJCore
import SwiftUI

/// The playing screen: one `GeometryReader` decides compact (closed Duo) or Studio (open
/// Duo) from the container width alone (`StudioLayoutMode.resolve`). Folding only changes
/// that width. Nothing here creates or restarts playback: the session is app-scoped
/// (`AppDependencies.playback`) and arrives as a snapshot plus actions.
///
/// State that must survive folding lives here, above the switch: the workspace segment
/// (`@SceneStorage`, so it also survives scene restoration), the search text and whether
/// the compact workspace sheet is open. Unfolding with that sheet open moves its content
/// into Zone B on the same segment.
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

    @SceneStorage("aerodj.studio.segment") private var segment: WorkspaceSegment = .queue
    @State private var showWorkspace = false
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

    var body: some View {
        GeometryReader { geo in
            let width = Double(geo.size.width)
            let mode = resolvedMode(containerWidth: width)
            layout(mode: mode, width: width, height: geo.size.height)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: mode)
            #if DEBUG
            .onAppear {
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
                // This must not search or play: folding only changes which column is visible.
                if newMode != .compact { showWorkspace = false }
            }
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
        // The opened station, never the playing one: build 9 kept "Morning Calm" here after the
        // owner opened Late Night, so the next song tap looked like a station jump.
        .stationToolbar(heading.header, isTestStation: isTestStation)
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

    @ViewBuilder
    private func layout(mode: StudioLayoutMode, width: Double, height: CGFloat) -> some View {
        switch mode {
        case .compact:
            CompactPlayer(station: currentStation, content: content, snapshot: snapshot,
                          actions: actions, dj: dj, soundTags: soundTags, search: search,
                          studioSearch: studioSearch, timeSource: timeSource,
                          artworkNamespace: morphNamespace,
                          extendsUnderSafeArea: true,
                          onOpenWorkspace: { segment = .queue; showWorkspace = true },
                          onTune: { segment = .tune; showWorkspace = true },
                          onReview: { segment = .connections; showWorkspace = true })
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("layout.compact")
        case .studio:
            if let widths = StudioZoneWidths.allocate(containerWidth: width) {
                StudioLayout(widths: widths, containerHeight: height,
                             zoneA: zoneA(),
                             workspace: workspace)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("layout.studio")
            }
        case .studioStacked:
            StudioStackedLayout(zoneA: zoneA(usesParentScroll: true), workspace: workspace)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("layout.studioStacked")
        }
    }

    /// Compact width class collapses to Listen. Otherwise the existing width rule decides
    /// Studio vs the stacked accessibility layout. No device size is named here.
    private func resolvedMode(containerWidth: Double) -> StudioLayoutMode {
        if horizontalSizeClass == .compact { return .compact }
        return StudioLayoutMode.resolve(containerWidth: containerWidth,
                                        accessibilityTextSize: typeSize.isAccessibilitySize)
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

    private var content: NowPlayingContent { NowPlayingContent.resolve(access: access, snapshot: snapshot) }

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
