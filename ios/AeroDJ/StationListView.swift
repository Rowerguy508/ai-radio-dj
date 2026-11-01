import AeroDJCore
import SwiftUI

/// Station selection screen. Adaptive container sizing (no hardcoded device dims).
/// The split root owns the selection and the one shared studio/playback session.
/// Neither column creates a model. Choosing a built-in station never starts playback; tapping a
/// created one starts it only when nothing is queued (restore never does).
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
    /// One add-station flow per presentation (nil when closed). Never created in the Test Station.
    @State private var stationCreation: StationCreationModel?
    /// "Couldn't start that station" (core decides; `StationStartToast` draws it). Row taps only.
    @State private var startNotice = StationStartNotice()

    var body: some View {
        #if DEBUG
        if StudioCapture.isRequested(mode: dependencies.mode) {
            StudioCaptureView(dependencies: dependencies)
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
                         onUserOpenedStation: { id in
                             // Row tap only, never restore. A created station starts now when nothing
                             // is queued, otherwise takes over at the song boundary (CreatedStationStarter).
                             // Any tap clears the start toast; only this tap's idle-start failure shows it.
                             let tap = startNotice.beginTap()
                             guard let recipeID = CreatedStations.recipeID(for: id, in: dependencies.studio.recipes.recipes) else {
                                 // HOOK(Atlas, Fry #213 nit 2): a built-in tap cancels a waiting created-station start.
                                 dependencies.stationQueue?.cancelCreatedStationStart()
                                 await dependencies.playback.authorize()
                                 return
                             }
                             if let stationQueue = dependencies.stationQueue {
                                 let outcome = await stationQueue.openCreatedStation(.userTap, recipeID: recipeID,
                                                                                     studio: dependencies.studio)
                                 // Status read only (never authorize() or a prompt), and only if a toast is due.
                                 startNotice.finish(tap: tap, outcome: outcome, musicAuthorized: GenreAccess.isAuthorized)
                             } else {
                                 await dependencies.playback.authorize()
                                 _ = await dependencies.studio.applyRecipe(recipeID)
                             }
                         },
                         onAddStation: addStationAction) { station in
            PlayerView(station: station, music: dependencies.playback, interlude: dependencies.interlude,
                       djSession: dependencies.djSession, studio: dependencies.studio,
                       isTestStation: dependencies.mode == .testStation)
            // Inside the detail's NavigationStack: the top of the content, below the nav bar,
            // so it never covers Back or the title. A tap always opens this column. Never takes a tap.
            .overlay(alignment: .top) { StationStartToast(notice: startNotice) }
        }
        .task(id: "playback-session") { await PlaybackSessionBinder.bind(dependencies) }
        .sheet(isPresented: $showSharedInbox) {
            // Always a NavigationStack with Done. An empty `if` body left an undismissable sheet.
            SharedInboxSheet(isPresented: $showSharedInbox) {
                if dependencies.mode == .live, let review = SharedInboxReview.appGroupInbox() {
                    SharedInboxReviewView(review: review)
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
            }
        }
        // Live only: lets Connections offer the .md file picker (nil in the test station).
        .environment(\.pickedNotes, dependencies.pickedNotes)
        .ownerVoiceTrialEntry() // AERODJ_OWNER_AB only; a no-op otherwise
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
    /// Fired only from the list selection setter (a row tap). Restore never calls this, so a
    /// relaunch with a stored station ID cannot request Apple Music permission.
    var onUserOpenedStation: ((Station.ID) async -> Void)? = nil
    /// Opens the add-station walkthrough. Nil hides the + button.
    var onAddStation: (() -> Void)? = nil
    private let detail: (Station) -> Detail

    /// The one source of truth for both layouts: the selected station, whether restore has
    /// run, and what compact width shows. The regular detail and the compact column are both
    /// derived from it, so a width-class change in either direction keeps the open station.
    /// The back gesture may leave the list showing; that must not copy the stored id again.
    @State private var navigation = StationSplitNavigation<Station.ID>()
    @SceneStorage("aerodj.selectedStationID") private var storedStationID = ""
    /// Regular width shows both columns. Compact uses `preferredCompactColumn`.
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The scheme around the split. Regular width keeps it; compact forces dark (see `body`).
    @Environment(\.colorScheme) private var systemColorScheme

    init(stations: [Station], showsSharedInbox: Bool = false, showSharedInbox: Binding<Bool> = .constant(false),
         onUserOpenedStation: ((Station.ID) async -> Void)? = nil,
         onAddStation: (() -> Void)? = nil,
         @ViewBuilder detail: @escaping (Station) -> Detail) {
        self.stations = stations
        self.showsSharedInbox = showsSharedInbox
        self._showSharedInbox = showSharedInbox
        self.onUserOpenedStation = onUserOpenedStation
        self.onAddStation = onAddStation
        self.detail = detail
    }

    private var isCompact: Bool { horizontalSizeClass != .regular }

    private var selectedStationID: Station.ID? { navigation.selectedID }

    /// Derived from `navigation`: the open station whenever one is selected, unless the
    /// listener went back in compact width. Writes made in regular width are ignored there.
    private var preferredCompactColumn: Binding<NavigationSplitViewColumn> {
        Binding(
            get: { navigation.compactColumn == .detail ? .detail : .sidebar },
            set: { navigation.compactColumnWritten($0 == .sidebar ? .list : .detail) }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: preferredCompactColumn) {
            stationPicker
            .navigationTitle(AppName.display)
            // Contain first, so this identifier stays on the list and does not replace the rows.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("split.sidebar")
            // iOS 18+: "Stations" collapses into a compact inline bar as the list scrolls.
            // iOS 17 keeps the system large title. Rows and selection are untouched.
            .morphingLargeTitle("Stations", subtitle: "Your AI-hosted radio, on Apple Music")
            .toolbar {
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
        } detail: {
            if let station = stations.first(where: { $0.id == selectedStationID }) {
                NavigationStack {
                    // Contain first. A bare identifier here is copied onto every child
                    // and replaces studio.model.
                    detail(station)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("split.detail")
                }
            } else {
                Text("Choose a station")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("split.placeholder")
            }
        }
        // Balanced keeps the sidebar beside the detail. The prominent style lays the
        // detail over the sidebar, which is why portrait showed only Show Sidebar.
        .navigationSplitViewStyle(.balanced)
        // After the list exists. An earlier copy loses to the list resetting selection,
        // and a stored id can arrive after the first render.
        .task { restoreSelection() }
        .onChange(of: storedStationID) { _, _ in restoreSelection() }
        // Created stations arrive when the recipes load, after the first render.
        .onChange(of: stations.map(\.id)) { _, _ in restoreSelection() }
        // Regular is both columns. Compact leaves the visible column to
        // `preferredCompactColumn`, which `navigation` derives from the selection, so a fold,
        // rotation or Split View change shows the same open station. Never writes the selection.
        .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
            navigation.setRegularWidth(sizeClass == .regular)
            columnVisibility = navigation.showsBothColumns ? .all : .automatic
        }
    }

    /// Compact width (the folded phone) gets the arc carousel; regular width keeps the
    /// sidebar list. Both write the same `selection`, so a pick only selects and opens.
    @ViewBuilder
    private var stationPicker: some View {
        if isCompact {
            // A card tap goes through the list's own setter: same push, same one-time
            // authorization request, same stored id. Scrolling the carousel selects nothing.
            StationCarousel(stations: stations, selectedID: selectedStationID) { id in
                selection.wrappedValue = id
            }
        } else {
            stationList
        }
    }

    private var stationList: some View {
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
    }

    /// The row the list selects. Nil is not stored: the split clears the binding while it
    /// builds the list, and writing that empty value would erase the station the next launch needs.
    /// Choosing a station records its id and pushes the detail. Only a tap on a created station
    /// with nothing queued plays (`StationQueuePlayer.openCreatedStation`).
    /// The back gesture writes `preferredCompactColumn`, so the list can show again.
    private var selection: Binding<Station.ID?> {
        Binding(
            get: { selectedStationID },
            set: { newValue in
                guard let newValue else { return }
                // Keep the system NavigationSplitView push. Setting the column outside
                // an animation was skipping the transition on compact width.
                withAnimation {
                    navigation.select(newValue)
                }
                storedStationID = newValue.uuidString
                // Explicit row tap only. `restoreSelection` writes `navigation` directly
                // and never enters this setter, so restore cannot request Apple Music.
                if let onUserOpenedStation {
                    Task { await onUserOpenedStation(newValue) }
                }
            }
        )
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

/// Lightweight station model for the app shell. Domain types live in AeroDJCore.
struct Station: Identifiable, Hashable {
    let id: UUID
    let name: String
    let description: String?
    /// A station made with + (a seeded recipe). Its row tap can start playback (#213).
    var isCreated = false

    /// VoiceOver hint for the list row and carousel card: what a tap does. A created station
    /// starts right away when nothing is queued (CreatedStationStarter), else after this song.
    var openHint: String {
        isCreated
            ? "Plays the station now if nothing is queued, otherwise after this song."
            : "Opens the station. Music starts only when you press Play."
    }

    /// Stable IDs so a restored selection can find the same row after a relaunch.
    static let morningCalmID = UUID(uuidString: "7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D")!
    static let lateNightID = UUID(uuidString: "8D3B2C21-5F60-4B7C-9D0E-1F2A3B4C5D6E")!

    static let defaultStations: [Station] = [
        Station(id: morningCalmID, name: "Morning Calm", description: "Warm, unhurried host"),
        Station(id: lateNightID, name: "Late Night", description: "Smooth vinyl-bar vibes"),
    ]
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
