#if DEBUG
import AeroDJCore
import SwiftUI

/// #465 item 10 (-Nova): screenshot scenarios for Library, Stations and Settings at the Duo's
/// inner display (640 × 820 pt) and at narrow Split View (340 × 760 pt), both compact class.
/// Debug only, test station only, behind `-AeroDJStudioCapture YES` like `StudioCaptureView`.
/// Kept out of `StudioCaptureScenario` so this PR does not edit the lines #479, #493, #501
/// and #506 each add scenarios to; fold it in there once those land.
enum AppWideCaptureScenario: String, CaseIterable {
    case duoWideLibrary
    case duoWideStations
    /// Wide Stations grid, then fold to the 390×844 carousel. Extra fixture
    /// cards make the grid scrollable so a UI test can check the stored focus
    /// survives the fold (#492). Not a required screenshot.
    case duoWideStationsFold
    case duoWideSettings
    case splitNarrowLibrary
    case splitNarrowStations
    case splitNarrowSettings
    /// Onboarding: `LocalAreaPrompt` at Duo width. Nothing is tapped; no location prompt.
    case duoWideLocalArea

    /// The scenario named in `-AeroDJStudioCaptureScenario`, if it is one of these.
    static func requested(defaults: UserDefaults = .standard) -> AppWideCaptureScenario? {
        defaults.string(forKey: StudioCapture.scenarioKey).flatMap(Self.init(rawValue:))
    }

    var screen: AppWideLayout.Screen {
        switch self {
        case .duoWideLibrary, .splitNarrowLibrary: .library
        case .duoWideStations, .duoWideStationsFold, .splitNarrowStations: .stations
        case .duoWideSettings, .splitNarrowSettings: .settings
        case .duoWideLocalArea: .onboarding
        }
    }

    var input: AppWideLayout.Input {
        switch self {
        case .duoWideLibrary, .duoWideStations, .duoWideStationsFold, .duoWideSettings, .duoWideLocalArea: AppWideLayout.duoWide
        case .splitNarrowLibrary, .splitNarrowStations, .splitNarrowSettings: AppWideLayout.splitNarrow
        }
    }

    var containerSize: CGSize {
        CGSize(width: input.containerWidth, height: input.containerHeight)
    }
}

struct AppWideCaptureView: View {
    let scenario: AppWideCaptureScenario
    let dependencies: AppDependencies

    @State private var creation: StationCreationModel?
    @State private var failure: String?
    @State private var localAreaStore = LocalAreaStore.inMemory()
    @State private var localAreaLocation = CoarseDeviceLocation()
    /// Only `duoWideStationsFold`: the inner-display grid, then the phone carousel.
    @State private var stationsFolded = false
    @SceneStorage("aerodj.stations.scrollAnchor") private var stationsAnchor = ""
    @State private var didResetStationsAnchor = false

    var body: some View {
        Group {
            if let failure {
                Text(failure).accessibilityIdentifier("capture.failed")
            } else if scenario.screen == .library && creation == nil {
                Text("Loading studio capture").accessibilityIdentifier("capture.loading")
            } else {
                container
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(UserDefaults.standard.bool(forKey: StudioCapture.darkKey) ? .dark : nil)
        .onAppear {
            // One launch, once: a previous test's scene storage must not pre-seed the focus.
            if scenario == .duoWideStationsFold, !didResetStationsAnchor {
                stationsAnchor = ""
                didResetStationsAnchor = true
            }
        }
        .task {
            guard scenario.screen == .library else { return }
            let studio = dependencies.studio
            for _ in 0..<200 {
                switch studio.station.loadState {
                case .ready, .failed:
                    creation = StationCreationModel(studio: studio, search: AppWideCaptureSeeds(), kind: .playlist)
                    return
                default:
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            failure = "App-wide capture failed: station did not load within 10 s (\(scenario.rawValue))"
        }
    }

    /// The same backdrop, clip and outline as `DuoWideCaptureContainer`, at this scenario's size.
    private var container: some View {
        let size = currentContainerSize
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let decision = AppWideLayout.decide(currentInput, for: scenario.screen)
        return ZStack {
            Color(white: 0.14).ignoresSafeArea().accessibilityHidden(true)
            screen
                .environment(\.horizontalSizeClass, .compact)
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
                .overlay { shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1).allowsHitTesting(false) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("capture.appWideContainer")
                .overlay(alignment: .bottomLeading) {
                    // What the core decided for this container, for the UI test. 1 pt, no taps.
                    Text(verbatim: decision.decisionText)
                        .font(.system(size: 1))
                        .accessibilityIdentifier("appWide.decision")
                        .accessibilityLabel(decision.decisionText)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    if scenario == .duoWideStationsFold { stationsFoldChrome }
                }
        }
    }

    private var currentInput: AppWideLayout.Input {
        if scenario == .duoWideStationsFold, stationsFolded {
            return AppWideLayout.Input(hasRegularWidth: false, containerWidth: 390, containerHeight: 844)
        }
        return scenario.input
    }

    private var currentContainerSize: CGSize {
        if scenario == .duoWideStationsFold, stationsFolded {
            return CGSize(width: 390, height: 844)
        }
        return scenario.containerSize
    }

    /// Fold control and the stored Stations focus, so a UI test can fold the
    /// grid back to the carousel and check the scrolled card is still held.
    private var stationsFoldChrome: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { stationsFolded.toggle() }
            } label: {
                Text(stationsFolded ? "Unfold" : "Fold")
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stations.fold")
            Text(stationsAnchor.isEmpty ? "none" : stationsAnchor)
                .font(.system(size: 1))
                .accessibilityIdentifier("stations.scrollAnchor")
                .accessibilityLabel(stationsAnchor.isEmpty ? "none" : stationsAnchor)
                .allowsHitTesting(false)
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var screen: some View {
        switch scenario.screen {
        case .library:
            if let creation {
                // Step 2 of a playlist station. The UI test picks "Your library".
                AddStationWalkthroughView(studio: dependencies.studio, creation: creation,
                                          initialStep: .picks, initialKind: .playlist) {}
                    .appWideScreen(.library)
            }
        case .stations:
            // The sidebar column as the split root draws it in compact width, without the
            // split's stored station id, so no restore can push a player over it.
            AppWideStationsCapture(scrollable: scenario == .duoWideStationsFold)
                .appWideScreen(.stations)
        case .settings:
            SettingsView(isPresented: .constant(true), isTestStation: true)
                .appWideScreen(.settings, formMargins: true)
        case .onboarding:
            // As the Tune card presents it: a sheet, content at the top. In-memory store; the
            // location object asks Core Location only if "Use approximate location" is tapped.
            VStack(spacing: 0) {
                LocalAreaPrompt(store: localAreaStore, location: localAreaLocation) {}
                    .appWideScreen(.onboarding)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }
}

/// `StationSplitRoot`'s compact sidebar: the grid when `AppWideLayout` gives columns,
/// otherwise the carousel. Selection is local and starts nothing.
private struct AppWideStationsCapture: View {
    var scrollable = false
    @Environment(\.appWideLayout) private var appWide
    @State private var selected: Station.ID?

    /// Built-ins plus fictional cards so the wide grid has to scroll (#492).
    private var stations: [Station] {
        guard scrollable else { return Station.defaultStations }
        return Station.defaultStations + Self.fixtureCards
    }

    var body: some View {
        NavigationStack {
            Group {
                if let appWide, appWide.columns > 1 {
                    StationGrid(stations: stations, selectedID: selected, layout: appWide) {
                        selected = $0
                    }
                } else {
                    StationCarousel(stations: stations, selectedID: selected) { selected = $0 }
                }
            }
            .navigationTitle(AppName.display)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("split.sidebar")
        }
    }

    private static let fixtureCards: [Station] = (1...10).map { index in
        let id = UUID(uuidString: String(format: "B0B00000-0000-4000-8000-0000000000%02d", index))!
        return Station(id: id, name: "Fixture \(index)", description: "Fictional")
    }
}

/// Fixture library playlists for the Library capture. In memory; no MusicKit, no network.
private struct AppWideCaptureSeeds: StationSeedSearching {
    private static let playlists = ["Road Trip", "Sunday Slow", "Focus Flow", "Late Night Drive",
                                    "Kitchen Disco", "Rainy Day", "Gym Hour", "Wind Down"]

    func searchSeeds(_ term: String, kinds: Set<StationSeedKind>, limit: Int) async throws -> [StationSeedSearchResult] {
        Self.playlists.prefix(limit).enumerated().map {
            StationSeedSearchResult(seed: StationSeed(kind: .playlist, catalogID: "pl.\($0.offset)", name: "[TEST] \($0.element)"),
                                    subtitle: "Apple Music")
        }
    }

    func genreSeeds(matching query: String) async throws -> [StationSeedSearchResult] { [] }

    func libraryPlaylistSeeds(limit: Int) async throws -> [StationSeedSearchResult] {
        Self.playlists.prefix(limit).enumerated().map {
            StationSeedSearchResult(seed: StationSeed(kind: .playlist, catalogID: "lib.\($0.offset)",
                                                      name: "[TEST] \($0.element)", source: .library),
                                    subtitle: "\(12 + $0.offset * 7) songs")
        }
    }
}
#endif
