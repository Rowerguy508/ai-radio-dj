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
        case .duoWideStations, .splitNarrowStations: .stations
        case .duoWideSettings, .splitNarrowSettings: .settings
        case .duoWideLocalArea: .onboarding
        }
    }

    var input: AppWideLayout.Input {
        switch self {
        case .duoWideLibrary, .duoWideStations, .duoWideSettings, .duoWideLocalArea: AppWideLayout.duoWide
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
        let size = scenario.containerSize
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let decision = AppWideLayout.decide(scenario.input, for: scenario.screen)
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
        }
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
            AppWideStationsCapture()
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
    @Environment(\.appWideLayout) private var appWide
    @State private var selected: Station.ID?

    var body: some View {
        NavigationStack {
            Group {
                if let appWide, appWide.columns > 1 {
                    StationGrid(stations: Station.defaultStations, selectedID: selected, layout: appWide) {
                        selected = $0
                    }
                } else {
                    StationCarousel(stations: Station.defaultStations, selectedID: selected) { selected = $0 }
                }
            }
            .navigationTitle(AppName.display)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("split.sidebar")
        }
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
