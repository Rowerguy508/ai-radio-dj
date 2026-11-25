import AeroDJCore
import os
import SwiftUI
import UIKit

/// Station selection screen. Adaptive container sizing (no hardcoded device dims).
/// The split root owns the selection and the one shared studio/playback session.
/// Neither column creates a model. #454: tapping any station row starts that station right away
/// (switching from whatever plays); restoring the selection never does.
struct StationListView: View {
    /// Composed once at launch by `AppDependencies`; views receive it, never build it.
    let dependencies: AppDependencies
    /// Built-in stations, then every station created with the + walkthrough (P0 build 25: the
    /// list was only the built-ins, so a saved station never appeared). Created rows come from
    /// the recipe library, the store `StationCreationModel.save` writes, so they update live.
    private var stations: [Station] {
        Station.defaultStations + CreatedStations.entries(from: dependencies.studio.recipes.recipes).map(Station.init(created:))
    }
    @State private var showSharedInbox = false
    /// Settings sheet (gear on the Stations list), every build (-Fry).
    @State private var showSettings = false
    /// One add-station flow per presentation (nil when closed). Never created in the Test Station.
    @State private var stationCreation: StationCreationModel?
    /// "Couldn't start that station" (core decides; `StationStartToast` draws it). Row taps only.
    @State private var startNotice = StationStartNotice()

    var body: some View {
        #if DEBUG
        if StudioCapture.isRequested(mode: dependencies.mode) {
            // #465 item 10: the app-wide captures have their own scenario names.
            if let appWide = AppWideCaptureScenario.requested() {
                AppWideCaptureView(scenario: appWide, dependencies: dependencies)
            } else if let layouts = StationsLayoutCaptureScenario.requested() {
                // Open-Duo Stations designs and the Settings picker (-Nova).
                StationsLayoutCaptureView(scenario: layouts)
            } else {
                StudioCaptureView(dependencies: dependencies)
            }
        } else {
            split
        }
        #else
        split
        #endif
    }

    /// Selection lives here, above both columns. The constant task id plus the binder's
    /// once-only gate keep a fold, unfold, or rotation from re-running it.
    private var split: some View {
        StationSplitRoot(stations: stations, showsSharedInbox: dependencies.mode == .live,
                         showSharedInbox: $showSharedInbox,
                         onUserOpenedStation: { id in await openStation(id) },
                         onAddStation: addStationAction,
                         onOpenSettings: { showSettings = true },
                         // Open Duo only (`DuoStationsLayout.usesOpenDuoStations`): the three
                         // Stations designs and Rail D's now-playing thumbnail. Same player and
                         // actions as `PlayerView` (`.live`). Phones never draw it.
                         duoStations: DuoStationsSource(music: dependencies.playback,
                                                        actions: DuoStationsRailActions(.live(dependencies.playback)),
                                                        timeSource: .live,
                                                        studio: dependencies.studio),
                         stationDetail: { station, openFromDetail in
            PlayerView(station: station, music: dependencies.playback, interlude: dependencies.interlude,
                       djSession: dependencies.djSession, studio: dependencies.studio,
                       isTestStation: dependencies.mode == .testStation,
                       stationStops: stations.map { DuoStationSwitch.Stop(id: $0.id.uuidString, name: $0.name) },
                       // #454: a Duo dial tap takes the same route as a row tap. It selects the
                       // station (header, start state, song taps) and then starts it.
                       onOpenStation: { id in
                           guard let uuid = StationTapRoute.stationID(forStop: id, in: stations.map(\.id)) else { return }
                           openFromDetail(uuid)
                       })
            // Inside the detail's NavigationStack: the top of the content, below the nav bar,
            // so it never covers Back or the title. A tap always opens this column. Never takes a tap.
            .overlay(alignment: .top) { StationStartToast(notice: startNotice) }
        })
        // #465 item 10: measures the window for the Duo's station grid. Nil on every phone.
        .appWideScreen(.stations)
        .task(id: "playback-session") { await PlaybackSessionBinder.bind(dependencies) }
        .sheet(isPresented: $showSettings) {
            SettingsView(isPresented: $showSettings, isTestStation: dependencies.mode == .testStation,
                         // Sentinel's #410 n4: the app's one purge-all.
                         personalDataReset: dependencies.purger)
                // #465 item 10: readable rows on the Duo and wide windows; untouched on phones.
                .appWideScreen(.settings, formMargins: true)
        }
        .sheet(isPresented: $showSharedInbox) {
            // Always a NavigationStack with Done. An empty `if` body left an undismissable sheet.
            SharedInboxSheet(isPresented: $showSharedInbox) {
                if dependencies.mode == .live, let review = SharedInboxReview.appGroupInbox() {
                    // #313: Connections re-reads after each change, so the briefing sees it; an edit purges first.
                    SharedInboxReviewView(review: review,
                                          onChange: { await dependencies.studio.connections.refresh() },
                                          willRedact: { await dependencies.studio.connections.purgeNarration(for: [$0]) })
                } else {
                    ContentUnavailableView(
                        "Nothing shared yet", systemImage: "tray",
                        description: Text("In Mail, Messages or Safari, tap Share and choose \(AppName.display)."))
                }
            }
        }
        // Add-station walkthrough (Nova). Saves a recipe only; never plays or applies.
        .sheet(isPresented: Binding(get: { stationCreation != nil },
                                    set: { if !$0 { stationCreation = nil } })) {
            if let stationCreation {
                AddStationWalkthroughView(studio: dependencies.studio, creation: stationCreation) {
                    self.stationCreation = nil
                }
                // #465 item 10: readable width and two library columns when wide.
                .appWideScreen(.library)
            }
        }
        // Live only: lets Connections offer the .md file picker (nil in the test station).
        .environment(\.pickedNotes, dependencies.pickedNotes)
        .ownerVoiceTrialEntry() // AERODJ_OWNER_AB only; a no-op otherwise
        .testerCloudVoiceConsent() // AERODJ_TESTER_VOICE or AERODJ_OWNER_AB only; a no-op otherwise
    }

    /// #454 (-Atlas): every station row tap (built-in, library or created) starts that station on
    /// one path (`StationQueuePlayer.openStation`): Now Playing shows "Starting <name>…" at once,
    /// the first song plays as soon as it resolves, and a failure stays on that screen with Try
    /// again (plus the existing toast). Row tap only, never restore. Any tap clears the toast.
    private func openStation(_ id: Station.ID) async {
        let tap = startNotice.beginTap()
        let name = stations.first(where: { $0.id == id })?.name ?? "station"
        let recipeID = CreatedStations.recipeID(for: id, in: dependencies.studio.recipes.recipes)
        let status = dependencies.studio.stationStart
        let statusTap = status.begin(stationID: id.uuidString, stationName: name,
                                     songAtTap: dependencies.playback.snapshot.nowPlaying?.id,
                                     retry: { Task { await openStation(id) } })
        guard let stationQueue = dependencies.stationQueue else {
            // No station queue (previews): the old behavior, no start.
            await dependencies.playback.authorize()
            if let recipeID { _ = await dependencies.studio.applyRecipe(recipeID) }
            status.finish(tap: statusTap, outcome: .notStarted(.notAvailableYet))
            return
        }
        let outcome: CreatedStationOpenOutcome
        if let recipeID {
            outcome = await stationQueue.openCreatedStation(.userTap, recipeID: recipeID, studio: dependencies.studio)
        } else {
            outcome = await stationQueue.openBuiltInStation(.userTap, stationID: id, studio: dependencies.studio)
        }
        status.finish(tap: statusTap, outcome: outcome)
        // Status read only (never authorize() or a prompt), and only if a toast is due.
        startNotice.finish(tap: tap, outcome: outcome, musicAuthorized: GenreAccess.isAuthorized)
    }

    /// The + action, or nil (no button) when the app has no seed search: previews and the Test Station.
    private var addStationAction: (() -> Void)? {
        guard dependencies.studio.seedSearch != nil else { return nil }
        return { stationCreation = dependencies.studio.makeStationCreation() }
    }
}

/// Sidebar plus detail. `@State` holds the selection; `@SceneStorage` keeps only the station ID.
/// Restoring that ID selects the row and does not call play.
struct StationSplitRoot<Detail: View>: View {
    let stations: [Station]
    var showsSharedInbox: Bool = false
    @Binding var showSharedInbox: Bool
    /// Fired only from a user tap (`userTapped`): a list row, carousel or grid card, or the Duo
    /// dial in the detail. Restore never calls this, so a relaunch with a stored station ID cannot
    /// request Apple Music permission.
    var onUserOpenedStation: ((Station.ID) async -> Void)? = nil
    /// Opens the add-station walkthrough. Nil hides the + button.
    var onAddStation: (() -> Void)? = nil
    /// Opens Settings. Nil hides the gear (StudioCapture passes none).
    var onOpenSettings: (() -> Void)? = nil
    /// Open-Duo Stations (owner, 2026-11-17): the three designs and Rail D's now-playing
    /// thumbnail (`DuoStationsScreen`). Nil, the default, keeps today's picker everywhere; even
    /// when set, only the open Duo (`DuoStationsLayout.usesOpenDuoStations`) draws it.
    var duoStations: DuoStationsSource? = nil
    /// The detail for the open station. Its second argument is the split's own tap route (#454): a
    /// station tapped inside the detail (the Duo dial) is selected here like a row, then started.
    private let detail: (Station, @escaping (Station.ID) -> Void) -> Detail

    /// The one source of truth for both layouts: the selected station, whether restore has
    /// run, and what compact width shows. The regular detail and the compact column are both
    /// derived from it, so a width-class change in either direction keeps the open station.
    /// The back gesture may leave the list showing; that must not copy the stored id again.
    @State private var navigation = StationSplitNavigation<Station.ID>()
    @SceneStorage("aerodj.selectedStationID") private var storedStationID = ""
    /// Regular width shows both columns. Compact uses `preferredCompactColumn`.
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var containerWidth: Double = 0
    @State private var containerHeight: Double = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.splitMeasure) private var splitMeasure
    /// The scheme around the split. Regular width keeps it; compact forces dark (see `body`).
    @Environment(\.colorScheme) private var systemColorScheme
    /// #465 item 10: nil on every phone and narrow split, so compact keeps the carousel.
    @Environment(\.appWideLayout) private var appWide
    /// The whole window (safe area included), for the open-Duo Stations gate only.
    @State private var windowSize: CGSize = .zero
    /// Build 54: the window's safe-area insets, for the launch layout log only.
    @State private var windowInsets = OpenDuoGateLog.Insets()
    /// The top of this root's safe area in global points: where the Stations rail's `railTop`
    /// is measured from, so the pushed player's rail starts at the same y.
    @State private var safeTopGlobal: CGFloat = 0
    /// Build 54: the system's hinge and fold divisions (`FoldDivisionProbe`), read only on a
    /// wide-and-tall window. An open Duo larger than `FoldedColumnLayout.openDuoMaxSide` is
    /// told from an iPad by these; no iPad reports a hinge. Empty on SDKs without the API.
    @State private var foldHinge: FoldAwareness.HingeSample?
    @State private var foldDivisions: [FoldAwareness.Division] = []
    /// Studio captures force a hinge and fold; nil in the app.
    @Environment(\.foldPoseOverride) private var foldPoseOverride
    @Environment(\.displayScale) private var displayScale

    init(stations: [Station], showsSharedInbox: Bool = false, showSharedInbox: Binding<Bool> = .constant(false),
         onUserOpenedStation: ((Station.ID) async -> Void)? = nil,
         onAddStation: (() -> Void)? = nil,
         onOpenSettings: (() -> Void)? = nil,
         duoStations: DuoStationsSource? = nil,
         @ViewBuilder detail: @escaping (Station) -> Detail) {
        self.init(stations: stations, showsSharedInbox: showsSharedInbox, showSharedInbox: showSharedInbox,
                  onUserOpenedStation: onUserOpenedStation, onAddStation: onAddStation,
                  onOpenSettings: onOpenSettings, duoStations: duoStations,
                  stationDetail: { station, _ in detail(station) })
    }

    /// #454: `stationDetail` also gets the split's tap route, for a station tapped inside the detail.
    init(stations: [Station], showsSharedInbox: Bool = false, showSharedInbox: Binding<Bool> = .constant(false),
         onUserOpenedStation: ((Station.ID) async -> Void)? = nil,
         onAddStation: (() -> Void)? = nil,
         onOpenSettings: (() -> Void)? = nil,
         duoStations: DuoStationsSource? = nil,
         @ViewBuilder stationDetail: @escaping (Station, @escaping (Station.ID) -> Void) -> Detail) {
        self.stations = stations
        self.showsSharedInbox = showsSharedInbox
        self._showSharedInbox = showSharedInbox
        self.onUserOpenedStation = onUserOpenedStation
        self.onAddStation = onAddStation
        self.onOpenSettings = onOpenSettings
        self.duoStations = duoStations
        self.detail = stationDetail
    }

    /// Build 54 (-Nova): the width class this split and its overlay use. The open Duo
    /// (`usesDuoStations`, measured) is always compact here, so a device that reports regular
    /// width draws the same Duo Stations, pushed player and rail as the compact open Duo, never
    /// the system sidebar beside a detail. Every other window passes its own class through
    /// unchanged, so the iPhone and the closed Duo see exactly the value they saw before.
    private var effectiveSizeClass: UserInterfaceSizeClass? {
        usesDuoStations ? .compact : horizontalSizeClass
    }

    private var isCompact: Bool { effectiveSizeClass != .regular }

    private var selectedStationID: Station.ID? { navigation.selectedID }

    /// Sidebar + detail. A three-column split would open with `.doubleColumn`.
    private static var openListVisibility: NavigationSplitViewVisibility { .all }

    private var layoutWidth: Double {
        containerWidth > 0 ? containerWidth : (splitMeasure?.containerWidth ?? 0)
    }

    private var layoutHeight: Double {
        containerHeight > 0 ? containerHeight : (splitMeasure?.containerHeight ?? 0)
    }

    /// Half is the adapting width where sidebar and detail cannot sit side by side.
    /// SwiftUI then keeps the detail. The compact column, held on the sidebar, is the
    /// one it shows. Full width and two-thirds are not this span.
    private var isHalfSpan: Bool {
        guard layoutWidth > 0 else { return false }
        return SplitViewLayout.span(hasRegularWidth: true, containerWidth: layoutWidth,
                                     containerHeight: layoutHeight) == .half
    }

    /// Derived from `navigation`: the open station whenever one is selected, unless the
    /// listener went back in compact width. Writes made in regular width are ignored there.
    private var preferredCompactColumn: Binding<NavigationSplitViewColumn> {
        Binding(
            get: { navigation.compactColumn == .detail ? .detail : .sidebar },
            set: { navigation.compactColumnWritten($0 == .sidebar ? .list : .detail) }
        )
    }

    var body: some View {
        SplitBarHost(preferred: .leading) { insets in
            columns(insets)
        }
        // Open Duo only: the Stations screen sits over the split while no station is open,
        // so the player push, the back gesture, restore and the sheets are the split's own.
        // Hidden from VoiceOver underneath. Every other window: false, nothing drawn.
        .accessibilityHidden(showsDuoStations)
        .overlay { duoStationsOverlay }
        // Build 54: a value, never an `if`, so crossing the open-Duo size keeps the split's state.
        // Off the open Duo it is the parent's own class (the iPhone and closed Duo are unchanged).
        .environment(\.horizontalSizeClass, effectiveSizeClass)
        // The player's open-Duo rail reads the window from here. Nil off the open Duo (the
        // default), so every other window's player is unchanged.
        .environment(\.openDuoWindow, openDuoWindowMetrics)
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                   height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
        } action: { size in
            if size != windowSize { windowSize = size }
        }
        .onGeometryChange(for: OpenDuoGateLog.Insets.self) { proxy in
            OpenDuoGateLog.Insets(top: Double(proxy.safeAreaInsets.top), leading: Double(proxy.safeAreaInsets.leading),
                                  bottom: Double(proxy.safeAreaInsets.bottom),
                                  trailing: Double(proxy.safeAreaInsets.trailing))
        } action: { insets in
            if insets != windowInsets { windowInsets = insets }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { minY in
            if minY != safeTopGlobal { safeTopGlobal = minY }
        }
        // Only a wide-and-tall window reads the hinge. On every iPhone and the closed Duo the
        // `if` is false and nothing is added.
        .background {
            if isWideAndTallWindow {
                FoldDivisionProbe(hinge: $foldHinge, divisions: $foldDivisions)
            }
        }
        // Release-safe: one line when the gate's answer or its fold input changes. Points, the
        // screen scale, the width class and two booleans; no station, track or user data.
        .onChange(of: OpenDuoGateLog.Key(usesDuoStations: usesDuoStations, hasFold: hasFold,
                                          measured: windowSize.width > 0), initial: true) { _, key in
            guard key.measured else { return }
            OpenDuoGateLog.decided(usesDuoStations: key.usesDuoStations, hasFold: key.hasFold,
                                   phone: DeviceIdiom.isPhone, idiomPhone: DeviceIdiom.isPhoneIdiomRaw,
                                   modelIPhone: DeviceIdiom.isPhoneModel,
                                   window: windowSize, insets: windowInsets, scale: Double(displayScale),
                                   sizeClass: horizontalSizeClass)
        }
    }

    /// The window the player's open-Duo rail lines up with: the trailing unsafe column and the
    /// Stations rail's top (`DuoStationsLayout.railTopInset`) in global points. Nil off the open Duo.
    private var openDuoWindowMetrics: OpenDuoWindowMetrics? {
        guard usesDuoStations else { return nil }
        let top = DuoStationsLayout.railTopInset(trailingUnsafeWidth: windowInsets.trailing)
        return OpenDuoWindowMetrics(trailingInset: CGFloat(windowInsets.trailing),
                                    railTop: safeTopGlobal + CGFloat(top))
    }

    /// Wide and tall enough for the Duo layout (`.duoHorizontal`), measured. Never an iPhone or
    /// the closed Duo.
    private var isWideAndTallWindow: Bool {
        FoldedColumnLayout.controlPlacement(containerWidth: Double(windowSize.width),
                                            containerHeight: Double(windowSize.height)) == .duoHorizontal
    }

    /// The system reports a fold: a hinge sample or an active division (or a capture's override).
    private var hasFold: Bool {
        let hinge = foldPoseOverride.map { $0.hinge } ?? foldHinge
        let divisions = foldPoseOverride?.divisions ?? foldDivisions
        return hinge != nil || divisions.contains { $0.isActive }
    }

    /// The open Duo, with a source, measured at either width class (build 54: the device reports
    /// regular width, so the old compact-only gate never drew these Stations). Never an iPhone,
    /// the closed Duo or a full-screen iPad (`DuoStationsLayout.usesOpenDuoStations`). Reads the
    /// parent's class, not `effectiveSizeClass`, which is derived from this.
    private var usesDuoStations: Bool {
        duoStations != nil
            && DuoStationsLayout.usesOpenDuoStations(hasRegularWidth: horizontalSizeClass == .regular,
                                                     containerWidth: Double(windowSize.width),
                                                     containerHeight: Double(windowSize.height),
                                                     hasFold: hasFold,
                                                     isPhoneIdiom: DeviceIdiom.isPhone)
    }

    /// The Stations screen is up: the open Duo with no station pushed.
    private var showsDuoStations: Bool { usesDuoStations && !navigation.isStationVisible }

    @ViewBuilder
    private var duoStationsOverlay: some View {
        // Kept (hidden) while the player is pushed; hidden, it draws nothing, takes no touches,
        // leaves VoiceOver and turns its rail's sleep timer Off, so it never pauses playback.
        if usesDuoStations, let duoStations {
            DuoStationsHost(source: duoStations, stations: stations,
                            // A tile or row: the list's own setter, so it opens and starts (#454).
                            onSelect: { selection.wrappedValue = $0 },
                            onOpenPlayer: openPlayer,
                            onOpenSettings: onOpenSettings,
                            onAddStation: onAddStation,
                            onSharedInbox: showsSharedInbox ? { showSharedInbox = true } : nil,
                            isShown: showsDuoStations)
                .opacity(showsDuoStations ? 1 : 0)
                .allowsHitTesting(showsDuoStations)
                // iOS 44274149637: `.accessibilityHidden` alone left `stations.rail.nowPlaying`
                // in the tree under the pushed player for 8 s. Hidden, the host is also one
                // childless element, so none of its controls is reachable. -Nova
                .accessibilityElement(children: showsDuoStations ? .contain : .ignore)
                .accessibilityHidden(!showsDuoStations)
        }
    }

    /// The rail's now-playing thumbnail and C's Open player: show that station's player
    /// without starting it again. Navigation only, never `onUserOpenedStation`.
    private func openPlayer(_ id: Station.ID) {
        withAnimation {
            navigation.select(id)
        }
        storedStationID = id.uuidString
    }

    /// `insets` nil keeps the sidebar on the leading edge and the gear where it is.
    private func columns(_ insets: SplitInsets?) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: preferredCompactColumn) {
            stationPicker(insets)
            .navigationTitle(AppName.display)
            // Contain first, so this identifier stays on the list and does not replace the rows.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("split.sidebar")
            // iOS 18+: "Stations" collapses into a compact inline bar as the list scrolls.
            // iOS 17 keeps the system large title. Rows and selection are untouched.
            .morphingLargeTitle("Stations", subtitle: "Your AI-hosted radio, on Apple Music")
            .toolbar {
                if let onOpenSettings {
                    ToolbarItem(placement: SplitToolbar.placement(
                        preferred: .leading, edge: insets?.barEdge,
                        leading: .topBarLeading, trailing: .topBarTrailing)) {
                        Button(action: onOpenSettings) {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .modifier(SplitMinimumTarget(enabled: insets != nil))
                        .accessibilityIdentifier("stations.settings")
                    }
                }
                // The real App Group inbox is never opened in the test station: its
                // data must not appear next to fixtures.
                if showsSharedInbox {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSharedInbox = true
                        } label: {
                            Label("Shared Items", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if let onAddStation {
                    ToolbarItem(placement: .primaryAction) {
                        AddStationToolbarButton(action: onAddStation)
                    }
                }
            }
            // Compact: the whole sidebar is dark, the carousel's dark-glass cards plus the
            // morphing header and nav bar above them. Without this, light mode drew the header
            // in black on the dark carousel. Same pattern as the folded player. A value, not
            // an `if`, so folding or unfolding keeps the column's identity and scroll state.
            .environment(\.colorScheme, isCompact ? .dark : systemColorScheme)
            .toolbarColorScheme(isCompact ? .dark : nil, for: .navigationBar)
            .modifier(SplitColumnText(enabled: insets?.barEdge == .trailing))
        } detail: {
            if let station = stations.first(where: { $0.id == selectedStationID }) {
                NavigationStack {
                    // Contain first. A bare identifier here is copied onto every child
                    // and replaces studio.model.
                    detail(station, { userTapped($0) })
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("split.detail")
                        .modifier(SplitColumnText(enabled: insets?.barEdge == .trailing))
                }
            } else {
                Text("Choose a station")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("split.placeholder")
                    .modifier(SplitColumnText(enabled: insets?.barEdge == .trailing))
            }
        }
        // Balanced keeps the sidebar beside the detail. The prominent style lays the
        // detail over the sidebar, which is why portrait showed only Show Sidebar.
        .navigationSplitViewStyle(.balanced)
        .background { if insets != nil { splitSizeReader } }
        .modifier(HalfSplitSidebarColumn(enabled: insets != nil && selectedStationID == nil && isHalfSpan))
        // After the list exists. An earlier copy loses to the list resetting selection,
        // and a stored id can arrive after the first render.
        .task {
            restoreSelection()
            showStationListIfUnselected(insets)
        }
        .onChange(of: storedStationID) { _, _ in restoreSelection() }
        // Created stations arrive when the recipes load, after the first render.
        .onChange(of: stations.map(\.id)) { _, _ in restoreSelection() }
        // Regular is both columns. Compact leaves the visible column to
        // `preferredCompactColumn`, which `navigation` derives from the selection, so a fold,
        // rotation or Split View change shows the same open station. Never writes the selection.
        .onChange(of: effectiveSizeClass, initial: true) { _, sizeClass in
            navigation.setRegularWidth(sizeClass == .regular)
            // Nil insets is the phone: both columns or the compact column, unchanged.
            // An adapting split with nothing selected opens `.all` (this split is two
            // columns). A chosen station leaves visibility alone so the sidebar can collapse.
            if insets == nil || selectedStationID != nil {
                columnVisibility = navigation.showsBothColumns ? .all : .automatic
            } else {
                showStationListIfUnselected(insets)
            }
        }
        .onChange(of: selectedStationID) { _, _ in
            showStationListIfUnselected(insets)
        }
        .modifier(SplitLeadingBar(enabled: insets?.barEdge == .trailing))
        .environment(\.splitBarEdge, insets?.barEdge)
    }

    /// Adapting split, nothing selected: sidebar + detail (`.all`). Does nothing on the
    /// phone, and nothing after a station is picked. Compact width (the narrow split)
    /// keeps `.automatic`, which is already the sidebar column.
    private func showStationListIfUnselected(_ insets: SplitInsets?) {
        guard insets != nil, selectedStationID == nil, effectiveSizeClass == .regular else { return }
        if columnVisibility != Self.openListVisibility {
            columnVisibility = Self.openListVisibility
        }
    }

    /// The split's laid-out size. Hidden, and it does not take taps.
    private var splitSizeReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { publishSize(geo.size) }
                .onChange(of: geo.size) { _, size in publishSize(size) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func publishSize(_ size: CGSize) {
        let width = Double(size.width)
        let height = Double(size.height)
        if width != containerWidth { containerWidth = width }
        if height != containerHeight { containerHeight = height }
    }

    /// Compact width (the folded phone) gets the arc carousel; regular width keeps the
    /// sidebar list. Both write the same `selection`, so a pick only selects and opens.
    @ViewBuilder
    private func stationPicker(_ insets: SplitInsets?) -> some View {
        if isCompact {
            // A card tap goes through the list's own setter: same push, same one-time
            // authorization request, same stored id. Scrolling the carousel selects nothing.
            if usesDuoStations {
                // Open Duo: `DuoStationsScreen` draws Stations over the split; #551's
                // carousel is gone here. The column is only the backdrop under it.
                FoldedStyle.background.ignoresSafeArea()
                    .accessibilityHidden(true)
            } else if let appWide, appWide.columns > 1 {
                // #465 item 10: the unfolded Duo (compact class, 640 pt) shows every station
                // as a grid. Same cards and the same selection path as the carousel.
                StationGrid(stations: stations, selectedID: selectedStationID, layout: appWide) { id in
                    selection.wrappedValue = id
                }
            } else {
                StationCarousel(stations: stations, selectedID: selectedStationID) { id in
                    selection.wrappedValue = id
                }
            }
        } else {
            stationList(insets)
        }
    }

    private func stationList(_ insets: SplitInsets?) -> some View {
        List(selection: selection) {
            ForEach(stations) { station in
                // The link is the row. Its value is the station ID, so the tap selects
                // that row and the split pushes the detail.
                NavigationLink(value: station.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        // ui-contract §6: station name is one line, truncated. Created names run to 40 characters.
                        Text(station.name).font(.headline).lineLimit(1)
                        if let description = station.description {
                            Text(description).font(.subheadline).foregroundStyle(AeroDJPalette.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tag(station.id)
                // Same label, hint and identifier scheme as the carousel card (StationCarousel.swift:189-193),
                // so UI tests and VoiceOver treat a created station like any other row.
                .accessibilityHint(station.openHint)
                .accessibilityIdentifier("stations.row.\(station.id.uuidString)")
            }
        }
        // A List keeps its own row margin and ignores the host's safeAreaInset,
        // so on the 540 pt split the row starts 20 pt in, inside the 28 pt leading.
        // Nil insets is the phone, and the list is returned with no padding.
        .modifier(SplitStationListPadding(insets: insets))
    }

    /// The row the list selects. Nil is not stored: the split clears the binding while it
    /// builds the list, and writing that empty value would erase the station the next launch needs.
    /// Choosing a station records its id and pushes the detail. #454: a tap starts that station
    /// (`StationListView.openStation`); restore never enters this setter.
    /// The back gesture writes `preferredCompactColumn`, so the list can show again.
    private var selection: Binding<Station.ID?> {
        Binding(
            get: { selectedStationID },
            set: { userTapped($0) }
        )
    }

    /// #454: every station tap, from the list, carousel, grid or the detail's Duo dial. Selects the
    /// station (`StationTapRoute`), stores its id and starts it. Restore never calls this, so it
    /// cannot request Apple Music.
    private func userTapped(_ id: Station.ID?) {
        var next = navigation
        guard let picked = StationTapRoute.tap(id, navigation: &next, available: stations.map(\.id)) else { return }
        // Keep the system NavigationSplitView push. Setting the column outside
        // an animation was skipping the transition on compact width.
        withAnimation {
            navigation = next
        }
        storedStationID = picked.uuidString
        // Its own task, as a row tap always did: once a tap reaches here its start runs to the end
        // (the dial's newer-tap cancel only stops a tap that has not reached here). A newer tap's
        // start supersedes it in the start path (`.superseded`), so the latest tap still wins.
        if let onUserOpenedStation {
            Task { await onUserOpenedStation(picked) }
        }
    }

    /// Copies the stored station into `navigation` once. Playback still starts only from
    /// `PlaybackActions`. It opens the station for both width classes, whichever is current, so
    /// a restore in regular width still shows the station after a fold or rotation.
    ///
    /// Debug launches may pass `-AeroDJRestoreStationID <uuid>`. That string is the stored
    /// value for this path and is not written anywhere else. Release does not compile it.
    private func restoreSelection() {
        navigation.restore(UUID(uuidString: storedStationRaw), available: stations.map(\.id))
    }

    /// `@SceneStorage` only. In Debug, a launch argument stands in for that stored id.
    private var storedStationRaw: String {
        #if DEBUG
        let seeded = UserDefaults.standard.string(forKey: "AeroDJRestoreStationID") ?? ""
        if !seeded.isEmpty { return seeded }
        #endif
        return storedStationID
    }
}

/// Pads a split station list by the host's extra insets. A nil inset is the phone
/// list, returned unchanged. Full width does not adapt, so it is unchanged too.
private struct SplitStationListPadding: ViewModifier {
    var insets: SplitInsets?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let insets {
            content
                .padding(.leading, CGFloat(insets.padding.leading))
                .padding(.trailing, CGFloat(insets.padding.trailing))
        } else {
            content
        }
    }
}

/// Half split, nothing selected: the width class the split actually honors, so the
/// sidebar column is the one on screen. Off is the view unchanged.
private struct HalfSplitSidebarColumn: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.environment(\.horizontalSizeClass, .compact)
        } else {
            content
        }
    }
}

/// Lightweight station model for the app shell. Domain types live in AeroDJCore.
struct Station: Identifiable, Hashable {
    let id: UUID
    let name: String
    let description: String?
    /// A station made with + (a seeded recipe, catalog or library seeds).
    var isCreated = false

    /// VoiceOver hint for the list row and carousel card: what a tap does. #454: every station
    /// starts right away, switching from whatever plays (`StationListView.openStation`).
    var openHint: String {
        "Plays the station now."
    }

    /// Stable IDs so a restored selection can find the same row after a relaunch.
    /// The same ids as `BuiltInStations`, which holds the seeds those rows play.
    static let morningCalmID = BuiltInStations.morningCalm.id
    static let lateNightID = BuiltInStations.lateNight.id

    static let defaultStations: [Station] = BuiltInStations.all.map {
        Station(id: $0.id, name: $0.name, description: $0.summary)
    }
}

extension Station {
    /// A station the listener created (`CreatedStations`). Its id is the recipe id. An extension,
    /// so the memberwise init the built-ins use stays.
    init(created: CreatedStationEntry) {
        self.init(id: created.id, name: created.name, description: created.summary, isCreated: true)
    }
}

/// Share-inbox sheet chrome: Done always dismisses; swipe-to-dismiss stays enabled.
struct SharedInboxSheet<Content: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPresented = false }
                            .accessibilityIdentifier("share.done")
                    }
                }
        }
        // Intentionally no `.interactiveDismissDisabled`: swipe must dismiss.
    }
}

#Preview {
    StationListView(dependencies: AppDependencies.make())
}

/// Build 54 -> 55 (-Nova): what the open-Duo Stations gate saw, so the device confirms the
/// window size, scale, width class and hinge. Release-safe: numbers and booleans only.
enum OpenDuoGateLog {
    struct Key: Equatable {
        var usesDuoStations: Bool
        var hasFold: Bool
        var measured: Bool
    }

    struct Insets: Equatable, Sendable {
        var top: Double = 0
        var leading: Double = 0
        var bottom: Double = 0
        var trailing: Double = 0
    }

    private static let log = Logger(subsystem: "com.aerodj.app", category: "layout")

    static func decided(usesDuoStations: Bool, hasFold: Bool, phone: Bool, idiomPhone: Bool, modelIPhone: Bool,
                        window: CGSize, insets: Insets,
                        scale: Double, sizeClass: UserInterfaceSizeClass?) {
        let sizeClassName: String
        switch sizeClass {
        case .regular: sizeClassName = "regular"
        case .compact: sizeClassName = "compact"
        default: sizeClassName = "none"
        }
        let size = String(format: "%.0fx%.0f", Double(window.width), Double(window.height))
        let safe = String(format: "t%.0f l%.0f b%.0f r%.0f", insets.top, insets.leading,
                          insets.bottom, insets.trailing)
        let scaleText = String(format: "%.1f", scale)
        // The rail's status-column clearance is estimated from the owner's shots, not measured.
        let clearance = String(format: "%.0f", DuoStationsLayout.statusColumnClearance)
        log.notice("stations gate duo \(usesDuoStations, privacy: .public) phone gate \(phone, privacy: .public) idiom phone \(idiomPhone, privacy: .public) model iPhone \(modelIPhone, privacy: .public) hinge \(hasFold, privacy: .public) size class \(sizeClassName, privacy: .public) window \(size, privacy: .public) scale \(scaleText, privacy: .public) safe \(safe, privacy: .public) rail clearance \(clearance, privacy: .public)")
    }
}

/// Build 54 (-Nova, Orion's idiom-or-hinge gate): the open Duo is a foldable phone, so it reports
/// the phone idiom; no iPad does. With a reported hinge, this is what tells the open Duo at the
/// regular width class from an iPad window of the same size. Every iPhone is phone idiom too,
/// but never wide and tall enough (`.duoHorizontal`) for anything gated on it.
@MainActor
enum DeviceIdiom {
    /// Debug-only test override: `-AeroDJForcePhoneIdiom YES` lets the iPad-simulator UI tests
    /// stand in for the open Duo at regular width. Release compiles it out.
    static let forcePhoneKey = "AeroDJForcePhoneIdiom"

    /// The hardware model ("iPhone17,3"; on the simulator the simulated model, since
    /// `utsname.machine` is the host CPU there). Read once; never logged (Sentinel).
    private static let modelIdentifier: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #if targetEnvironment(simulator)
        let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        #else
        let simulatorModel: String? = nil
        #endif
        return DeviceModel.resolvedIdentifier(machine: machine, simulatorModel: simulatorModel)
    }()

    /// Whether the hardware model is an iPhone. Sentinel: only this boolean is logged, never the
    /// model identifier itself.
    static var isPhoneModel: Bool { DeviceModel.isPhoneModel(identifier: modelIdentifier) }

    /// Atlas: the raw UIKit idiom, no debug override and no model signal, for the launch log.
    static var isPhoneIdiomRaw: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// The phone idiom, or (Orion) an iPhone hardware model that reports the pad idiom. The
    /// debug override still wins in the UI tests; the iPad simulator's model is "iPad…".
    static var isPhone: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: forcePhoneKey) { return true }
        #endif
        return UIDevice.current.userInterfaceIdiom == .phone
            || isPhoneModel
    }
}
