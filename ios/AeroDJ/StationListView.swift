import AeroDJCore
import SwiftUI

/// Station selection screen. Adaptive container sizing (no hardcoded device dims).
/// The split root owns the selection and the one shared studio/playback session.
/// Neither column creates a model, and choosing a station never starts playback.
struct StationListView: View {
    /// Composed once at launch by `AppDependencies`; views receive it, never build it.
    let dependencies: AppDependencies
    @State private var stations: [Station] = Station.defaultStations
    @State private var showSharedInbox = false
    /// One add-station flow per presentation (nil when closed). Never created in the Test Station.
    @State private var stationCreation: StationCreationModel?

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
                         onUserOpenedStation: { await dependencies.playback.authorize() },
                         onAddStation: addStationAction) { station in
            PlayerView(station: station, music: dependencies.playback, interlude: dependencies.interlude,
                       djSession: dependencies.djSession, studio: dependencies.studio,
                       isTestStation: dependencies.mode == .testStation)
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
                        description: Text("In Mail, Messages or Safari, tap Share and choose AeroDJ."))
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
    var onUserOpenedStation: (() async -> Void)? = nil
    /// Opens the add-station walkthrough. Nil hides the + button.
    var onAddStation: (() -> Void)? = nil
    private let detail: (Station) -> Detail

    @State private var selectedStationID: Station.ID? = nil
    @SceneStorage("aerodj.selectedStationID") private var storedStationID = ""
    /// Set once the stored id has been copied into `selectedStationID` this appearance.
    /// The back gesture may leave the list showing; that must not copy the id again.
    @State private var didApplyRestore = false
    /// Regular width shows both columns. Compact uses `preferredCompactColumn`.
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    /// Nothing selected opens on the list. A selection pushes the detail.
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The scheme around the split. Regular width keeps it; compact forces dark (see `body`).
    @Environment(\.colorScheme) private var systemColorScheme

    init(stations: [Station], showsSharedInbox: Bool = false, showSharedInbox: Binding<Bool> = .constant(false),
         onUserOpenedStation: (() async -> Void)? = nil,
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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            stationPicker
            .navigationTitle("AeroDJ")
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
        // Regular is both columns. Compact leaves the visible column to
        // `preferredCompactColumn`. Visibility never writes the selection.
        .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
            columnVisibility = sizeClass == .regular ? .all : .automatic
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
                        Text(station.name).font(.headline)
                        Text(station.description ?? "").font(.subheadline).foregroundStyle(AeroDJPalette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tag(station.id)
            }
        }
    }

    /// The row the list selects. Nil is not stored: the split clears the binding while it
    /// builds the list, and writing that empty value would erase the station the next launch needs.
    /// Choosing a station records only its id and pushes the detail. It does not play.
    /// The back gesture writes `preferredCompactColumn`, so the list can show again.
    private var selection: Binding<Station.ID?> {
        Binding(
            get: { selectedStationID },
            set: { newValue in
                guard let newValue else { return }
                // Keep the system NavigationSplitView push. Setting the column outside
                // an animation was skipping the transition on compact width.
                withAnimation {
                    selectedStationID = newValue
                    preferredCompactColumn = .detail
                }
                didApplyRestore = true
                storedStationID = newValue.uuidString
                // Explicit row tap only. `restoreSelection` writes `selectedStationID` directly
                // and never enters this setter, so restore cannot request Apple Music.
                if let onUserOpenedStation {
                    Task { await onUserOpenedStation() }
                }
            }
        )
    }

    /// Copies the stored station into `@State` once. Playback still starts only from
    /// `PlaybackActions`. Compact shows that detail.
    ///
    /// Debug launches may pass `-AeroDJRestoreStationID <uuid>`. That string is the stored
    /// value for this path and is not written anywhere else. Release does not compile it.
    private func restoreSelection() {
        guard !didApplyRestore else { return }
        guard let id = UUID(uuidString: storedStationRaw),
              stations.contains(where: { $0.id == id }) else { return }
        didApplyRestore = true
        selectedStationID = id
        if isCompact { preferredCompactColumn = .detail }
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

    /// Stable IDs so a restored selection can find the same row after a relaunch.
    static let morningCalmID = UUID(uuidString: "7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D")!
    static let lateNightID = UUID(uuidString: "8D3B2C21-5F60-4B7C-9D0E-1F2A3B4C5D6E")!

    static let defaultStations: [Station] = [
        Station(id: morningCalmID, name: "Morning Calm", description: "Warm, unhurried host"),
        Station(id: lateNightID, name: "Late Night", description: "Smooth vinyl-bar vibes"),
    ]
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
