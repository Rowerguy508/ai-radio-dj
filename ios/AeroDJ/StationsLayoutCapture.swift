#if DEBUG
import AeroDJCore
import SwiftUI

/// Open-Duo Stations (owner, 2026-11-17) Studio captures: each design (A tile grid, B Daytime /
/// After dark, C featured + Switch to) on the open Duo in the book pose (820 × 640, fold band
/// 396…424 forced as in `RailDCaptureContainer`) and upright (640 × 820), drawn by the real
/// `StationSplitRoot` with a fixed playing snapshot; plus Settings > Stations layout at iPhone
/// size (390 × 844) and on the Duo (640 × 820). Debug only, test station only, behind
/// `-AeroDJStudioCapture YES` like `AppWideCaptureScenario`. Fictional stations, shows, hosts
/// and songs only. Nothing here plays: no `onUserOpenedStation`, no actions wired. -Nova
enum StationsLayoutCaptureScenario: String, CaseIterable {
    case stationsLayoutABook
    case stationsLayoutAPortrait
    case stationsLayoutBBook
    case stationsLayoutBPortrait
    case stationsLayoutCBook
    case stationsLayoutCPortrait
    case stationsLayoutSettingsPhone
    case stationsLayoutSettingsDuo

    static func requested(defaults: UserDefaults = .standard) -> StationsLayoutCaptureScenario? {
        defaults.string(forKey: StudioCapture.scenarioKey).flatMap(Self.init(rawValue:))
    }

    var style: StationsLayoutStyle? {
        switch self {
        case .stationsLayoutABook, .stationsLayoutAPortrait: .tiles
        case .stationsLayoutBBook, .stationsLayoutBPortrait: .editorial
        case .stationsLayoutCBook, .stationsLayoutCPortrait: .featured
        case .stationsLayoutSettingsPhone, .stationsLayoutSettingsDuo: nil
        }
    }

    var isBook: Bool {
        self == .stationsLayoutABook || self == .stationsLayoutBBook || self == .stationsLayoutCBook
    }

    var size: CGSize {
        switch self {
        case .stationsLayoutSettingsPhone: CGSize(width: 390, height: 844)
        case .stationsLayoutSettingsDuo: StudioCapture.duoWideContainerSize
        default: isBook ? StudioCapture.duoTentContainerSize : StudioCapture.duoWideContainerSize
        }
    }
}

/// Fictional stations for the captures (the mock's eight). Fresh ids every launch, so the
/// split's stored station id (`@SceneStorage`) from an earlier run can never restore one and
/// push a player over the screen. UI tests find a station by its name in the label.
enum StationsLayoutFixtures {
    struct Entry {
        let station: Station
        let daypart: DuoStationsLayout.Daypart
    }

    private static let ids: [UUID] = (0..<8).map { _ in UUID() }

    static func id(_ n: Int) -> UUID { ids[n - 1] }

    static let entries: [Entry] = [
        Entry(station: Station(id: id(1), name: "Morning Calm", description: "The Slow Start · with Ada"), daypart: .daytime),
        Entry(station: Station(id: id(2), name: "Sunday Slow", description: "Porch Light · with June"), daypart: .daytime),
        Entry(station: Station(id: id(3), name: "Deep Focus", description: "Quiet Desk · with Sol"), daypart: .daytime),
        Entry(station: Station(id: id(4), name: "Café Hours", description: "Corner Table · with Lou"), daypart: .daytime),
        Entry(station: Station(id: id(5), name: "Late Night", description: "After Hours · with Theo"), daypart: .afterDark),
        Entry(station: Station(id: id(6), name: "Night Drive", description: "Open Road · with Mara"), daypart: .afterDark),
        Entry(station: Station(id: id(7), name: "Coastal Hours", description: "Low Tide · with Rafa"), daypart: .afterDark),
        Entry(station: Station(id: id(8), name: "Rainy Window", description: "Grey Skies · with Nell"), daypart: .afterDark),
    ]

    static var stations: [Station] { entries.map(\.station) }

    /// Morning Calm playing "Tidewater" by Lumen Harbor (fictional).
    static var snapshot: PlaybackSnapshot {
        let playing = entries[0].station
        return PlaybackSnapshot(station: StationRef(id: playing.id.uuidString, name: playing.name),
                                nowPlaying: TrackInfo(id: "fixture-tidewater", title: "Tidewater", artistName: "Lumen Harbor"),
                                upNext: [TrackInfo(id: "fixture-saltlines", title: "Salt Lines", artistName: "Paper Lanterns")],
                                transport: .playing, canSeek: true)
    }

    static func daypart(_ station: Station) -> DuoStationsLayout.Daypart? {
        entries.first { $0.station.id == station.id }?.daypart
    }
}

struct StationsLayoutCaptureView: View {
    let scenario: StationsLayoutCaptureScenario

    /// The Settings shots start from the default (A): an earlier run's tap must not show.
    @State private var ready = false

    var body: some View {
        let size = scenario.size
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            Color(white: 0.14).ignoresSafeArea().accessibilityHidden(true)
            if ready {
                screen
                    .environment(\.horizontalSizeClass, .compact)
                    .environment(\.foldPoseOverride, scenario.isBook
                                 ? FoldPoseOverride(hinge: .init(status: .partiallyOpen, angleDegrees: 150),
                                                    divisions: [RailDCaptureContainer.foldBand])
                                 : nil)
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1).allowsHitTesting(false) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("capture.stationsLayoutContainer")
            } else {
                Text("Loading studio capture").accessibilityIdentifier("capture.loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(UserDefaults.standard.bool(forKey: StudioCapture.darkKey) ? .dark : nil)
        .onAppear {
            if scenario.style == nil {
                UserDefaults.standard.removeObject(forKey: StationsLayoutStyle.defaultsKey)
            }
            ready = true
        }
    }

    @ViewBuilder
    private var screen: some View {
        if let style = scenario.style {
            StationSplitRoot(stations: StationsLayoutFixtures.stations,
                             onAddStation: {}, onOpenSettings: {},
                             duoStations: DuoStationsSource(fixture: StationsLayoutFixtures.snapshot,
                                                            // No-op actions: the rail draws Pause and Skip; nothing plays.
                                                            actions: DuoStationsRailActions(.preview),
                                                            // 1:12 of 3:45 in the rail's song bar.
                                                            timeSource: .fixture,
                                                            pinnedStyle: style,
                                                            daypart: StationsLayoutFixtures.daypart)) { station in
                // Stands in for the player: a tap must open it and start nothing.
                StationsLayoutPlayerStandIn(name: station.name)
            }
        } else {
            SettingsView(isPresented: .constant(true), isTestStation: true)
                .appWideScreen(.settings, formMargins: true)
        }
    }
}

/// The capture's player: its name, plus the workspace segment the Stations rail asked for
/// (`PlayerWorkspaceRequest`), taken on appear as `PlayingScreen` takes it.
private struct StationsLayoutPlayerStandIn: View {
    let name: String
    @State private var segment: WorkspaceSegment?

    var body: some View {
        Text(verbatim: segment.map { "Player: \(name), \($0.rawValue)" } ?? "Player: \(name)")
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FoldedStyle.background)
            .accessibilityIdentifier("capture.stationsLayout.player")
            .onAppear { segment = PlayerWorkspaceRequest.take() }
    }
}
#endif
