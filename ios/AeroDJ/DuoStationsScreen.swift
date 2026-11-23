import AeroDJCore
import SwiftUI

// Open-Duo Stations (owner, 2026-11-17 10:24 ET): the three mockup designs, A tile grid
// (default), B Daytime / After dark list and C featured card plus "Switch to", chosen in
// Settings > Stations layout. Rail D on the right: the player's open-Duo rail (⋯, Play/Pause,
// Skip, Queue, sleep timer, the song bar with its times, the live dot), except that its top
// slot is the 44 pt now-playing thumbnail that opens the player (the player's rail keeps
// Collapse). Replaces
// #551's open-Duo carousel. Only `StationSplitRoot` draws this, and only when
// `DuoStationsLayout.usesOpenDuoStations` (the open Duo, compact class): every iPhone, the
// closed Duo and regular width keep today's Stations. Numbers live in `DuoStationsLayout`
// (AeroDJCore, Linux tested). No shadows; 28 pt radii; every control at least 44 pt;
// nothing tappable on the fold band. -Nova

/// What the open-Duo Stations screen shows about playback. Built from the one shared
/// `PlaybackSnapshot`; nothing here starts or stops anything.
struct DuoStationsNowPlaying: Equatable {
    var stationID: String?
    var stationName: String?
    var trackTitle: String?
    var artistName: String?
    var trackID: String?
    var upNext: [TrackInfo]
    var transport: TransportState
    var startTimedOut: Bool
    var canSeek: Bool

    init(snapshot: PlaybackSnapshot) {
        stationID = snapshot.station?.id
        stationName = snapshot.station?.name
        trackTitle = snapshot.nowPlaying?.title
        artistName = snapshot.nowPlaying?.artistName
        trackID = snapshot.nowPlaying?.id
        upNext = snapshot.upNext
        transport = snapshot.transport
        startTimedOut = snapshot.startTimedOut
        canSeek = snapshot.canSeek
    }
}

/// One-shot: a Stations rail control that lives in the player's workspace (Queue, Tune,
/// Connections) asks the player it is about to push to open that segment, exactly as the
/// player's own rail does (`segment = …; showWorkspace = true`). `PlayingScreen` takes it on
/// appear; nil, the default, changes nothing anywhere else.
@MainActor
enum PlayerWorkspaceRequest {
    static var pending: WorkspaceSegment?

    static func take() -> WorkspaceSegment? {
        defer { pending = nil }
        return pending
    }
}

/// The rail's Play/Pause, Skip, sleep timer and song bar: the same `PlaybackActions` the
/// player's rail uses. Main actor, like `PlaybackActions`, whose closures it copies.
@MainActor
struct DuoStationsRailActions {
    var pause: () -> Void
    var resume: () async -> Void
    var skip: () async -> Void
    var cancelStart: () -> Void
    var seek: PlaybackScrubber.Seek

    init(_ actions: PlaybackActions) {
        pause = actions.pause
        resume = actions.resume
        skip = actions.skip
        cancelStart = actions.cancelStart
        seek = { await actions.seek(to: $0, trackID: $1) }
    }
}

/// Handed to `StationSplitRoot` by `StationListView` (live) and the Debug captures. Nil, the
/// default, keeps today's picker in every width class, so the other captures are unchanged.
struct DuoStationsSource {
    /// Live: observed, so the chips and the rail follow the player.
    var music: MusicKitService?
    /// Captures: a fixed snapshot instead of `music`.
    var fixture: PlaybackSnapshot?
    var actions: DuoStationsRailActions?
    /// The song bar's clock (`.live` in the app, the fixture in captures). Nil hides the bar.
    var timeSource: PlaybackTimeSource?
    /// Live: the live dot and ⋯'s review count follow the DJ (observed).
    var studio: StudioPresentationModel?
    /// Captures: a fixed DJ state instead of `studio`.
    var fixtureDJ: DJStudioState = .idle
    /// Captures pin a design; nil reads Settings > Stations layout.
    var pinnedStyle: StationsLayoutStyle?
    /// B's Daytime / After dark. Built-ins are known; created stations balance the groups.
    var daypart: (Station) -> DuoStationsLayout.Daypart? = { DuoStationsLayout.builtInDaypart(id: $0.id) }
}

/// Reads the playback source and the saved design, then draws `DuoStationsScreen`.
struct DuoStationsHost: View {
    let source: DuoStationsSource
    let stations: [Station]
    let onSelect: (Station.ID) -> Void
    let onOpenPlayer: (Station.ID) -> Void
    let onOpenSettings: (() -> Void)?
    let onAddStation: (() -> Void)?
    let onSharedInbox: (() -> Void)?
    /// False while the player is pushed over Stations: the host stays, drops the song bar's clock
    /// so nothing ticks unseen, and turns the rail's sleep timer Off (it never pauses unseen).
    var isShown: Bool = true

    @AppStorage(StationsLayoutStyle.defaultsKey) private var storedStyle = StationsLayoutStyle.defaultStyle.rawValue

    private var style: StationsLayoutStyle {
        source.pinnedStyle ?? StationsLayoutStyle.resolve(raw: storedStyle)
    }

    var body: some View {
        Group {
            if let music = source.music {
                DuoStationsLiveSnapshot(music: music) { screen($0) }
            } else {
                screen(source.fixture ?? PlaybackSnapshot())
            }
        }
        // Back on Stations: a workspace request the player never took must not open a sheet later.
        .onChange(of: isShown) { _, shown in
            if shown { PlayerWorkspaceRequest.pending = nil }
        }
    }

    private func screen(_ snapshot: PlaybackSnapshot) -> some View {
        DuoStationsScreen(stations: stations, style: style, nowPlaying: DuoStationsNowPlaying(snapshot: snapshot),
                          actions: source.actions,
                          dj: DJStatusPresentation(state: source.studio?.djState ?? source.fixtureDJ),
                          timeSource: isShown ? source.timeSource : nil,
                          isShown: isShown,
                          daypart: source.daypart,
                          onSelect: onSelect, onOpenPlayer: onOpenPlayer, onOpenSettings: onOpenSettings,
                          onAddStation: onAddStation, onSharedInbox: onSharedInbox)
    }
}

private struct DuoStationsLiveSnapshot<Content: View>: View {
    @ObservedObject var music: MusicKitService
    @ViewBuilder let content: (PlaybackSnapshot) -> Content

    var body: some View { content(music.snapshot) }
}

/// The screen itself: pages either side of the fold (book pose) or one page (upright), and
/// Rail D on the trailing edge.
struct DuoStationsScreen: View {
    let stations: [Station]
    let style: StationsLayoutStyle
    let nowPlaying: DuoStationsNowPlaying
    let actions: DuoStationsRailActions?
    var dj = DJStatusPresentation(state: .idle)
    var timeSource: PlaybackTimeSource? = nil
    /// False while the player is pushed over Stations: the rail's sleep timer turns Off, so a
    /// hidden Stations timer never pauses playback under the player's rail (which shows Off).
    var isShown: Bool = true
    let daypart: (Station) -> DuoStationsLayout.Daypart?
    let onSelect: (Station.ID) -> Void
    let onOpenPlayer: (Station.ID) -> Void
    let onOpenSettings: (() -> Void)?
    let onAddStation: (() -> Void)?
    let onSharedInbox: (() -> Void)?

    @Environment(\.foldPoseOverride) private var foldOverride
    /// #507 rest: the system's hinge and divisions in this screen's own points
    /// (`FoldDivisionProbe`). Empty on SDKs without the API. Only the open Duo draws this screen,
    /// so no iPhone or closed-Duo layout reads them.
    @State private var foldHinge: FoldAwareness.HingeSample?
    @State private var foldDivisions: [FoldAwareness.Division] = []
    /// The rail's ⋯ panel, as on the player (`FoldedPlayer.moreOpen`).
    @State private var moreOpen = false

    private var playingIndex: Int? {
        DuoStationsLayout.nowPlayingIndex(stationIDs: stations.map(\.id.uuidString),
                                          snapshotStationID: nowPlaying.stationID)
    }

    private var playingStation: Station? { playingIndex.map { stations[$0] } }

    var body: some View {
        GeometryReader { proxy in
            let width = Double(proxy.size.width)
            let height = Double(proxy.size.height)
            // Build 54: the reader spans the window's width (see `ignoresSafeArea` below), so its
            // origin is the window's leading edge and a reported division needs no shift.
            // #507 rest: the player's book-pose gates (`FoldAwareness.bookPoseFold`) on the
            // capture's forced pose or the probe's reading. No book-pose fold is today's centred
            // band. A status column on the leading edge (the Duo turned the other way) moves the
            // leading page in; 0 in every capture.
            let geometry = DuoStationsLayout.bookGeometry(containerWidth: width, containerHeight: height,
                                                          hinge: effectiveFoldHinge,
                                                          divisions: effectiveFoldDivisions,
                                                          leadingInset: Double(proxy.safeAreaInsets.leading))
            let inset = CGFloat(DuoStationsLayout.railVerticalInset)
            let pageHeight = max(0, proxy.size.height - inset * 2)
            // Below the trailing status column when there is one; `inset` everywhere else.
            let railTop = CGFloat(DuoStationsLayout.railTopInset(
                trailingUnsafeWidth: Double(proxy.safeAreaInsets.trailing)))
            let railHeight = max(0, proxy.size.height - railTop - inset)
            ZStack(alignment: .topLeading) {
                FoldedStyle.background
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                content(geometry, pageHeight: Double(pageHeight))
                    .padding(.top, inset)
                // Not built while the player is pushed over Stations: nothing of the rail stays
                // in the accessibility tree under the player, and its sleep timer goes with it,
                // which is the Off that `DuoRailSleepTimerState.setShown(false)` gives. -Nova
                if isShown {
                    DuoStationsRail(nowPlaying: nowPlaying, playing: playingStation, actions: actions,
                                    dj: dj, scrubber: railScrubber, isShown: isShown, moreOpen: $moreOpen,
                                    onOpenPlayer: onOpenPlayer, onOpenWorkspace: openWorkspace)
                        .frame(width: CGFloat(RailDLayout.railWidth), height: railHeight)
                        .padding(.leading, CGFloat(geometry.railMinX))
                        .padding(.top, railTop)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .overlay {
                if moreOpen { morePanel(geometry, width: width, height: Double(railHeight), top: railTop) }
            }
            // Same frame as the pages, so a division arrives in the points `geometry` uses.
            .background {
                FoldDivisionProbe(hinge: $foldHinge, divisions: $foldDivisions)
            }
        }
        // Build 54 (-Nova): flush to the window's trailing edge, not the safe area's. Vertical
        // safe areas still apply. In every capture the horizontal insets are 0, so nothing moves.
        .ignoresSafeArea(.container, edges: .horizontal)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stations.duo.\(style.rawValue)")
    }

    /// The rail's song bar: the same inputs as the player's (`FoldedPlayer.railScrubber`). Nil with
    /// nothing playing or no known duration; the rail then keeps its spacer above the live dot.
    private var railScrubber: RailScrubberInput? {
        guard playingStation != nil, let timeSource, let actions,
              timeSource.duration().map({ $0 > 0 }) ?? false else { return nil }
        return RailScrubberInput(time: timeSource, transport: nowPlaying.transport,
                                 trackID: nowPlaying.trackID, canSeek: nowPlaying.canSeek,
                                 onSeek: actions.seek, isDJSpeaking: dj.state.isOnAir)
    }

    /// Queue, Tune and Connections live in the player's workspace: push the playing station's
    /// player and open it there, as the player's rail would.
    private func openWorkspace(_ segment: WorkspaceSegment) {
        guard let playing = playingStation else { return }
        moreOpen = false
        PlayerWorkspaceRequest.pending = segment
        onOpenPlayer(playing.id)
    }

    /// Rail D's ⋯ panel (`DuoRailMorePanel`), inward of the rail and level with its top, never
    /// wider than the page it opens over, so it stays off the fold. A tap outside closes it.
    private func morePanel(_ geometry: DuoStationsLayout.Geometry, width: Double, height: Double,
                           top: CGFloat) -> some View {
        let frame = DuoStationsLayout.morePanelFrame(geometry, containerWidth: width)
        return ZStack(alignment: .topTrailing) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { moreOpen = false }
                .accessibilityHidden(true)
            DuoRailMorePanel(reviewCount: dj.reviewCount,
                             width: CGFloat(frame.width),
                             maxHeight: CGFloat(height),
                             onConnections: { openWorkspace(.connections) },
                             onTune: { openWorkspace(.tune) },
                             dismiss: { moreOpen = false })
                .padding(.top, top)
                .padding(.trailing, CGFloat(frame.trailingGap))
        }
    }

    /// The capture's forced pose (`FoldPoseOverride`), else the probe's reading. Nil and empty on
    /// this SDK, which keeps the centred band.
    private var effectiveFoldHinge: FoldAwareness.HingeSample? {
        foldOverride.map { $0.hinge } ?? foldHinge
    }

    private var effectiveFoldDivisions: [FoldAwareness.Division] {
        foldOverride?.divisions ?? foldDivisions
    }

    @ViewBuilder
    private func content(_ geometry: DuoStationsLayout.Geometry, pageHeight: Double) -> some View {
        switch style {
        case .tiles:
            DuoStationsTiles(stations: stations, geometry: geometry, pageHeight: pageHeight,
                             playingID: playingStation?.id, trackTitle: nowPlaying.trackTitle,
                             header: header, onSelect: onSelect)
        case .editorial:
            DuoStationsEditorial(stations: stations, geometry: geometry, pageHeight: pageHeight,
                                 playingID: playingStation?.id, trackTitle: nowPlaying.trackTitle,
                                 daypart: daypart, header: header, onSelect: onSelect)
        case .featured:
            DuoStationsFeatured(stations: stations, geometry: geometry, pageHeight: pageHeight,
                                playingIndex: playingIndex, nowPlaying: nowPlaying,
                                header: header, onSelect: onSelect, onOpenPlayer: onOpenPlayer)
        }
    }

    private var header: DuoStationsHeaderActions {
        DuoStationsHeaderActions(count: stations.count, onOpenSettings: onOpenSettings,
                                 onAddStation: onAddStation, onSharedInbox: onSharedInbox)
    }
}

// MARK: - Shared pieces

/// The header's buttons, drawn on the trailing page (book) or beside the title (upright).
struct DuoStationsHeaderActions {
    let count: Int
    let onOpenSettings: (() -> Void)?
    let onAddStation: (() -> Void)?
    let onSharedInbox: (() -> Void)?

    var subtitle: String {
        count == 1 ? "1 station · tap it to tune in" : "\(count) stations · tap one to tune in"
    }
}

enum DuoStationsStyle {
    static let accent = Color(red: FoldedOuterLayout.playRingRed, green: FoldedOuterLayout.playRingGreen,
                              blue: FoldedOuterLayout.playRingBlue)
    static let onAccent = Color(red: 3 / 255, green: 35 / 255, blue: 30 / 255)
    static var radius: CGFloat { CGFloat(DuoStationsLayout.tileCornerRadius) }
    static let headerHeight: CGFloat = 52

    static func ref(_ station: Station) -> StationRef {
        StationRef(id: station.id.uuidString, name: station.name)
    }

    /// The tile and art colour: the station's own palette (`StationArtStyle`), darkened until
    /// white text passes contrast. Flat: no gradient sheen, no shadow.
    static func fill(_ station: Station) -> Color {
        AeroDJPalette.backing(forLightText: StationArtStyle.station(ref(station)).color(0))
    }
}

/// "Stations" in the open title size (34 pt, scaled with Dynamic Type).
struct DuoStationsTitle: View {
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = CGFloat(RailDLayout.openTitlePointSize)

    var body: some View {
        Text("Stations")
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("stations.duo.title")
    }
}

/// Settings, Shared Items (live only) and + New station. Plain glass fills and a hairline,
/// no shadow; each at least 44 × 44.
struct DuoStationsHeaderButtons: View {
    let actions: DuoStationsHeaderActions
    /// C's book pose splits them: Settings (and Shared Items) beside "Stations", a round +
    /// beside "Switch to", so neither 300 pt page header overflows.
    var showsSettings = true
    var showsAdd = true
    var roundAdd = false

    var body: some View {
        HStack(spacing: 10) {
            if showsSettings, let onSharedInbox = actions.onSharedInbox {
                circle(systemImage: "square.and.arrow.up", label: "Shared Items",
                       identifier: "stations.duo.sharedItems", action: onSharedInbox)
            }
            if showsSettings, let onOpenSettings = actions.onOpenSettings {
                circle(systemImage: "gearshape", label: "Settings",
                       identifier: "stations.duo.settings", action: onOpenSettings)
            }
            if showsAdd, roundAdd, let onAddStation = actions.onAddStation {
                circle(systemImage: "plus", label: "Add station",
                       identifier: "stations.duo.addStation", action: onAddStation)
                    .accessibilityHint("Build a new station from artists, a genre or a playlist")
            } else if showsAdd, let onAddStation = actions.onAddStation {
                Button(action: onAddStation) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.body.weight(.bold))
                        Text("New station").font(.subheadline.weight(.bold)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 14)
                    .padding(.trailing, 18)
                    .frame(minHeight: 44)
                    .background(FoldedStyle.glassFill, in: Capsule())
                    .overlay { Capsule().strokeBorder(FoldedStyle.hairline, lineWidth: 1) }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add station")
                .accessibilityHint("Build a new station from artists, a genre or a playlist")
                .accessibilityIdentifier("stations.duo.addStation")
            }
        }
    }

    private func circle(systemImage: String, label: String, identifier: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(FoldedStyle.glassFill, in: Circle())
                .overlay { Circle().strokeBorder(FoldedStyle.hairline, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// A station's flat art plate: its colour and monogram. Custom drawing, no emoji, no shadow.
struct DuoStationMark: View {
    let station: Station
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(DuoStationsStyle.fill(station))
            DuoStationGlyph(station: station, size: side * 0.38)
        }
        .foregroundStyle(.white)
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// `DuoStationMark` from a `StationRef` (the player's snapshot has no `Station`): the same
/// fill and monogram rules. The player rail's now-playing thumbnail (build 54 follow-up). -Nova
struct DuoStationRefMark: View {
    let ref: StationRef
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        let style = StationArtStyle.station(ref)
        let glyph = side * 0.38
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(AeroDJPalette.backing(forLightText: style.color(0)))
            if style.monogram == "♪" {
                Image(systemName: "music.note").font(.system(size: glyph * 1.1, weight: .bold))
            } else {
                Text(style.monogram)
                    .font(.system(size: glyph, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The station's monogram as a glyph (a drawn music note when there is nothing to abbreviate).
struct DuoStationGlyph: View {
    let station: Station
    let size: CGFloat

    var body: some View {
        let monogram = StationArtStyle.station(DuoStationsStyle.ref(station)).monogram
        Group {
            if monogram == "♪" {
                Image(systemName: "music.note").font(.system(size: size * 1.1, weight: .bold))
            } else {
                Text(monogram)
                    .font(.system(size: size, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The teal "Playing" chip.
struct DuoStationsPlayingChip: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform").font(.caption.weight(.bold))
            Text("Playing").font(.footnote.weight(.heavy))
        }
        .foregroundStyle(DuoStationsStyle.onAccent)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(DuoStationsStyle.accent, in: Capsule())
        .accessibilityHidden(true)
    }
}

/// VoiceOver for a station button: name, its line, and whether it is the one playing.
private func stationLabel(_ station: Station, isPlaying: Bool) -> String {
    var parts = [station.name]
    if let description = station.description, !description.isEmpty { parts.append(description) }
    if isPlaying { parts.append("Playing") }
    return parts.joined(separator: ", ")
}

private extension View {
    /// One button element per station, with the same hint as the list row and carousel card.
    func duoStationButton(_ station: Station, isPlaying: Bool, identifier: String) -> some View {
        self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stationLabel(station, isPlaying: isPlaying))
            .accessibilityHint(station.openHint)
            .accessibilityAddTraits(isPlaying ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier(identifier)
    }

    func duoPage(_ page: DuoStationsLayout.Page, height: Double) -> some View {
        frame(width: CGFloat(page.width), height: CGFloat(height), alignment: .topLeading)
            .padding(.leading, CGFloat(page.minX))
    }
}

// MARK: - A: tile grid

struct DuoStationsTiles: View {
    let stations: [Station]
    let geometry: DuoStationsLayout.Geometry
    let pageHeight: Double
    let playingID: Station.ID?
    let trackTitle: String?
    let header: DuoStationsHeaderActions
    let onSelect: (Station.ID) -> Void

    /// Title (52) plus the subtitle line (40), as the mock.
    private static let headerBlock: Double = 92

    var body: some View {
        let pages = DuoStationsLayout.pageSplit(stations, pose: geometry.pose)
        let columns = DuoStationsLayout.tileColumns(pose: geometry.pose)
        let rows = geometry.pose == .book ? 2 : 3
        let tileHeight = DuoStationsLayout.tileHeight(available: pageHeight - Self.headerBlock, rows: rows)
        ZStack(alignment: .topLeading) {
            ForEach(Array(geometry.pages.enumerated()), id: \.offset) { index, page in
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader(index)
                        .frame(height: CGFloat(Self.headerBlock), alignment: .top)
                    ScrollView(.vertical) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CGFloat(DuoStationsLayout.tileGap)),
                                                 count: columns),
                                  spacing: CGFloat(DuoStationsLayout.tileGap)) {
                            ForEach(index < pages.count ? pages[index] : []) { station in
                                tile(station, height: tileHeight)
                            }
                        }
                        // Room for the playing ring, which sits outside the tile.
                        .padding(6)
                        .padding(.bottom, 8)
                    }
                    .padding(.horizontal, -6)
                    .scrollIndicators(.hidden)
                }
                .duoPage(page, height: pageHeight)
            }
        }
    }

    @ViewBuilder
    private func pageHeader(_ index: Int) -> some View {
        if geometry.pose == .book {
            if index == 0 {
                VStack(alignment: .leading, spacing: 0) {
                    DuoStationsTitle().frame(height: DuoStationsStyle.headerHeight, alignment: .leading)
                    Text(header.subtitle).font(.subheadline.weight(.medium)).foregroundStyle(FoldedStyle.secondaryInk)
                }
            } else {
                HStack { Spacer(minLength: 0); DuoStationsHeaderButtons(actions: header) }
                    .frame(height: DuoStationsStyle.headerHeight)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    DuoStationsTitle()
                    Spacer(minLength: 12)
                    DuoStationsHeaderButtons(actions: header)
                }
                .frame(height: DuoStationsStyle.headerHeight)
                Text(header.subtitle).font(.subheadline.weight(.medium)).foregroundStyle(FoldedStyle.secondaryInk)
            }
        }
    }

    private func tile(_ station: Station, height: Double) -> some View {
        let isPlaying = station.id == playingID
        let shape = RoundedRectangle(cornerRadius: DuoStationsStyle.radius, style: .continuous)
        return Button { onSelect(station.id) } label: {
            ZStack(alignment: .topLeading) {
                shape.fill(DuoStationsStyle.fill(station))
                HStack(alignment: .top) {
                    DuoStationGlyph(station: station, size: 30)
                        .frame(minWidth: 0, alignment: .leading)
                    Spacer(minLength: 8)
                    // Keep "Playing" whole; the monogram scales down when the tile is tight. -Nova
                    if isPlaying {
                        DuoStationsPlayingChip()
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                .padding(18)
                VStack(alignment: .leading, spacing: 5) {
                    Spacer(minLength: 0)
                    Text(station.name)
                        .font(.system(size: 23, weight: .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if let description = station.description, !description.isEmpty {
                        Text(description).font(.subheadline.weight(.semibold)).opacity(0.85).lineLimit(2)
                    }
                    if isPlaying, let trackTitle {
                        Text("Now: \(trackTitle)").font(.subheadline.weight(.semibold)).opacity(0.85).lineLimit(1)
                    }
                }
                .padding(18)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: CGFloat(height), maxHeight: CGFloat(height))
            .overlay {
                if isPlaying {
                    RoundedRectangle(cornerRadius: DuoStationsStyle.radius + 5, style: .continuous)
                        .strokeBorder(DuoStationsStyle.accent, lineWidth: 3)
                        .padding(-5)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .duoStationButton(station, isPlaying: isPlaying, identifier: "stations.tile.\(station.id.uuidString)")
    }
}

// MARK: - B: Daytime / After dark

struct DuoStationsEditorial: View {
    let stations: [Station]
    let geometry: DuoStationsLayout.Geometry
    let pageHeight: Double
    let playingID: Station.ID?
    let trackTitle: String?
    let daypart: (Station) -> DuoStationsLayout.Daypart?
    let header: DuoStationsHeaderActions
    let onSelect: (Station.ID) -> Void

    var body: some View {
        let groups = DuoStationsLayout.group(stations, known: daypart)
        ZStack(alignment: .topLeading) {
            if geometry.pose == .book {
                ForEach(Array(geometry.pages.enumerated()), id: \.offset) { index, page in
                    VStack(alignment: .leading, spacing: 12) {
                        Group {
                            if index == 0 {
                                DuoStationsTitle().padding(.leading, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                HStack { Spacer(minLength: 0); DuoStationsHeaderButtons(actions: header) }
                            }
                        }
                        .frame(height: DuoStationsStyle.headerHeight)
                        ScrollView(.vertical) {
                            if index < groups.count {
                                section(groups[index], page: index)
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    .duoPage(page, height: pageHeight)
                }
            } else if let page = geometry.pages.first {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        DuoStationsTitle().padding(.leading, 12)
                        Spacer(minLength: 12)
                        DuoStationsHeaderButtons(actions: header)
                    }
                    .frame(height: DuoStationsStyle.headerHeight)
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in section(group, page: 0) }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .duoPage(page, height: pageHeight)
            }
        }
    }

    private func section(_ group: (DuoStationsLayout.Daypart, [Station]), page: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(group.0.title)
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(FoldedStyle.secondaryInk)
                Rectangle().fill(FoldedStyle.hairline).frame(height: 1)
            }
            .frame(height: 28)
            .padding(.leading, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(group.0.title)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("stations.section.\(group.0.rawValue)")
            ForEach(group.1) { station in row(station, page: page) }
        }
        .padding(.bottom, 8)
    }

    private func row(_ station: Station, page: Int) -> some View {
        let isPlaying = station.id == playingID
        let art = CGFloat(DuoStationsLayout.editorialArtSide(pose: geometry.pose, page: page, isPlaying: isPlaying))
        let shape = RoundedRectangle(cornerRadius: DuoStationsStyle.radius, style: .continuous)
        return Button { onSelect(station.id) } label: {
            HStack(spacing: 16) {
                DuoStationMark(station: station, side: art, radius: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name)
                        .font(.system(size: 23, weight: .heavy))
                        .lineLimit(1)
                    if let description = station.description, !description.isEmpty {
                        Text(description).font(.subheadline.weight(.semibold)).opacity(0.88).lineLimit(1)
                    }
                    if isPlaying {
                        HStack(spacing: 8) {
                            DuoStationsPlayingChip()
                            if let trackTitle {
                                Text(trackTitle).font(.subheadline.weight(.bold))
                                    .foregroundStyle(DuoStationsStyle.accent).lineLimit(1)
                            }
                        }
                        .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: max(56, art + 16), alignment: .leading)
            .background {
                if isPlaying { shape.fill(DuoStationsStyle.accent.opacity(0.13)) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .duoStationButton(station, isPlaying: isPlaying, identifier: "stations.listRow.\(station.id.uuidString)")
    }
}

// MARK: - C: featured + Switch to

struct DuoStationsFeatured: View {
    let stations: [Station]
    let geometry: DuoStationsLayout.Geometry
    let pageHeight: Double
    let playingIndex: Int?
    let nowPlaying: DuoStationsNowPlaying
    let header: DuoStationsHeaderActions
    let onSelect: (Station.ID) -> Void
    let onOpenPlayer: (Station.ID) -> Void

    private var featuredIndex: Int? {
        DuoStationsLayout.featuredIndex(count: stations.count, playing: playingIndex)
    }

    private var others: [Station] {
        guard let featuredIndex else { return stations }
        return stations.enumerated().filter { $0.offset != featuredIndex }.map(\.element)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if geometry.pose == .book, geometry.pages.count == 2 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        DuoStationsTitle()
                        Spacer(minLength: 12)
                        DuoStationsHeaderButtons(actions: header, showsAdd: false)
                    }
                    .frame(height: DuoStationsStyle.headerHeight)
                    if let featuredIndex { card(stations[featuredIndex], compact: false) }
                }
                .duoPage(geometry.pages[0], height: pageHeight)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        switchTitle
                        Spacer(minLength: 12)
                        DuoStationsHeaderButtons(actions: header, showsSettings: false, roundAdd: true)
                    }
                    .frame(height: DuoStationsStyle.headerHeight)
                    ScrollView(.vertical) { list }.scrollIndicators(.hidden)
                }
                .duoPage(geometry.pages[1], height: pageHeight)
            } else if let page = geometry.pages.first {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        DuoStationsTitle()
                        Spacer(minLength: 12)
                        DuoStationsHeaderButtons(actions: header)
                    }
                    .frame(height: DuoStationsStyle.headerHeight)
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 20) {
                            if let featuredIndex {
                                card(stations[featuredIndex], compact: true)
                                    .frame(height: CGFloat(DuoStationsLayout.portraitFeaturedHeight))
                            }
                            switchTitle
                            list
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .duoPage(page, height: pageHeight)
            }
        }
    }

    private var switchTitle: some View {
        Text("Switch to")
            .font(.title2.weight(.heavy))
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)
    }

    private var isPlayingFeatured: Bool { playingIndex != nil && playingIndex == featuredIndex }

    private func card(_ station: Station, compact: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: DuoStationsStyle.radius, style: .continuous)
        let playing = isPlayingFeatured
        return VStack(alignment: .leading, spacing: 0) {
            if playing { DuoStationsPlayingChip() }
            Spacer(minLength: 12)
            if !compact {
                DuoStationMark(station: station, side: 88, radius: 24).padding(.bottom, 14)
            }
            Text(station.name)
                .font(.system(size: compact ? 30 : 40, weight: .heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            if let description = station.description, !description.isEmpty {
                Text(description).font(.subheadline.weight(.semibold)).opacity(0.85).lineLimit(2).padding(.top, 4)
            }
            Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1).padding(.vertical, compact ? 12 : 16)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playing ? "On now" : "Tap to tune in")
                        .font(.caption.weight(.bold)).tracking(1.4).textCase(.uppercase).opacity(0.72)
                    if playing, let title = nowPlaying.trackTitle {
                        Text(nowPlaying.artistName.map { "\(title) · \($0)" } ?? title)
                            .font(.headline).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    if playing { onOpenPlayer(station.id) } else { onSelect(station.id) }
                } label: {
                    Text(playing ? "Open player" : "Play")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255))
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .background(Color.white, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "Open player" : "Play \(station.name)")
                .accessibilityIdentifier(playing ? "stations.featured.openPlayer" : "stations.featured.play")
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DuoStationsStyle.fill(station), in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stations.featured")
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(others) { station in
                Button { onSelect(station.id) } label: {
                    HStack(spacing: 14) {
                        DuoStationMark(station: station, side: 44, radius: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.name).font(.system(size: 18, weight: .heavy)).lineLimit(1)
                            if let description = station.description, !description.isEmpty {
                                Text(description).font(.subheadline.weight(.medium))
                                    .foregroundStyle(FoldedStyle.secondaryInk).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "play.fill")
                            .font(.body.weight(.bold))
                            .frame(width: 44, height: 44)
                            .overlay { Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1) }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(DuoStationsLayout.switchRowMinHeight), alignment: .leading)
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(FoldedStyle.hairline).frame(height: 1) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .duoStationButton(station, isPlaying: false, identifier: "stations.switchRow.\(station.id.uuidString)")
            }
        }
    }
}

// MARK: - Rail D on Stations

/// Rail D on the Stations screen: the player's open-Duo rail (`DuoVerticalRail`) with the
/// now-playing thumbnail in Collapse's slot (it opens the player). Then ⋯ (Rail D's panel:
/// Connections, Review, Tune), Play/Pause and Skip while a station is loaded, Queue, the sleep
/// timer, the vertical song bar with its times and the live dot: the same views and behaviour,
/// the same 56 pt glass column, 28 pt radius, 44 pt plates and 10 pt gaps (`DuoRailGlass`,
/// `DuoRailLayout`). Queue and ⋯'s rows open the playing station's player on that segment.
struct DuoStationsRail: View {
    let nowPlaying: DuoStationsNowPlaying
    let playing: Station?
    let actions: DuoStationsRailActions?
    let dj: DJStatusPresentation
    let scrubber: RailScrubberInput?
    /// False while the player is pushed over Stations (see `DuoSleepTimerButton`).
    var isShown: Bool = true
    @Binding var moreOpen: Bool
    let onOpenPlayer: (Station.ID) -> Void
    let onOpenWorkspace: (WorkspaceSegment) -> Void

    /// ⋯ and Queue open the playing station's player, so they wait for one.
    private var canOpenPlayer: Bool { playing != nil }

    var body: some View {
        let slots = DuoStationsLayout.railSlots(hasNowPlaying: playing != nil && actions != nil,
                                                showsScrubber: scrubber != nil)
        // `DuoVerticalRail`'s stack with the thumbnail in Collapse's place: the same views,
        // 44 pt plates and 10 pt gaps.
        VStack(spacing: CGFloat(DuoRailLayout.spacing)) {
            thumbnail
            DuoRailMoreButton(open: $moreOpen, reviewCount: dj.reviewCount)
                .disabled(!canOpenPlayer)
            if slots.contains(.playPause), let actions {
                DuoRailPlayPauseButton(transport: nowPlaying.transport, startTimedOut: nowPlaying.startTimedOut,
                                       pause: actions.pause, cancelStart: actions.cancelStart, resume: actions.resume)
            }
            if slots.contains(.skip), let actions {
                DuoRailIconButton(systemImage: "forward.fill", label: "Skip", hint: "Skips this song.",
                                  identifier: "transport.skip", action: { Task { await actions.skip() } })
            }
            DuoRailIconButton(systemImage: "list.bullet", label: DuoVerticalRail.queueLabel(nowPlaying.upNext),
                              hint: "Opens the queue",
                              identifier: "queue.affordance", action: { onOpenWorkspace(.queue) })
                .disabled(!canOpenPlayer)
            DuoSleepTimerButton(pause: actions?.pause ?? {}, isShown: isShown)
            if slots.contains(.scrubber), let scrubber {
                RailScrubber(input: scrubber)
            } else {
                Spacer(minLength: CGFloat(DuoRailLayout.spacerMinLength))
            }
            DuoLiveDot(state: dj.state)
        }
        .padding(.vertical, CGFloat(DuoRailLayout.verticalPadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Same order as `ClosedVerticalRail` (`folded.closedRail`): glass, then the container.
        .modifier(DuoRailGlass())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stations.rail")
    }

    private var thumbnail: some View {
        let side = CGFloat(DuoStationsLayout.thumbnailSide)
        let art = CGFloat(DuoStationsLayout.thumbnailArtSide)
        let radius = CGFloat(DuoStationsLayout.thumbnailArtRadius)
        return Button {
            if let playing { onOpenPlayer(playing.id) }
        } label: {
            ZStack {
                if let playing {
                    DuoStationMark(station: playing, side: art - 4, radius: radius - 2)
                    RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                        .strokeBorder(DuoStationsStyle.accent, lineWidth: 2)
                        .frame(width: art + 2, height: art + 2)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(FoldedStyle.hairline, lineWidth: 1)
                        .frame(width: art, height: art)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FoldedStyle.tertiaryInk)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(playing == nil)
        .accessibilityLabel(DuoStationsLayout.thumbnailLabel(stationName: playing?.name))
        .accessibilityHint(playing == nil ? "" : "Opens the player.")
        .accessibilityIdentifier("stations.rail.nowPlaying")
    }
}
