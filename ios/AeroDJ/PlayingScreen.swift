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

    @SceneStorage("aerodj.studio.segment") private var segment: WorkspaceSegment = .queue
    @State private var showWorkspace = false
    @State private var searchQuery = ""
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            let mode = StudioLayoutMode.resolve(containerWidth: width,
                                                accessibilityTextSize: typeSize.isAccessibilitySize)
            layout(mode: mode, width: width, height: geo.size.height)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: mode)
            #if DEBUG
            .onAppear {
                if let initial = StudioCaptureSegment.initial {
                    segment = initial
                    StudioCaptureSegment.initial = nil
                    // Closed: the workspace is a sheet, so open it on that segment.
                    if mode == .compact { showWorkspace = true }
                }
            }
            #endif
            .onChange(of: mode) { _, newMode in
                // The compact sheet's content moves into Zone B on the same segment.
                if newMode != .compact { showWorkspace = false }
            }
        }
        .transaction { transaction in
            if reduceMotion { transaction.disablesAnimations = true }
        }
        .background(Color(.systemBackground))
        .environment(\.artStation, currentStation)
        .stationToolbar(currentStation, isTestStation: isTestStation)
        .sheet(isPresented: $showWorkspace) {
            NavigationStack {
                workspace
                    .environment(\.artStation, currentStation)
                    .padding(.horizontal, CGFloat(StudioLayoutMetrics.edgeInset))
                    .navigationTitle(snapshot.station?.name ?? station.name)
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
                          searchQuery: $searchQuery, artworkNamespace: morphNamespace,
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
            StudioStackedLayout(zoneA: zoneA(lockedHeight: height), workspace: workspace)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("layout.studioStacked")
        }
    }

    private var currentStation: StationRef { snapshot.station ?? station }

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

    private func zoneA(lockedHeight: CGFloat? = nil) -> NowPlayingPanel {
        NowPlayingPanel(station: currentStation, content: content, snapshot: snapshot,
                        actions: actions, dj: dj, soundTags: soundTags,
                        showsUpNext: segment != .queue,
                        artworkNamespace: morphNamespace, lockedHeight: lockedHeight,
                        onQueue: { segment = .queue }, onTune: { segment = .tune },
                        onReview: { segment = .connections })
    }

    private var workspace: WorkspaceView {
        WorkspaceView(studio: studio, content: content, snapshot: snapshot, actions: actions,
                      search: access == .authorized ? search : nil,
                      segment: $segment, searchQuery: $searchQuery)
    }
}

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
