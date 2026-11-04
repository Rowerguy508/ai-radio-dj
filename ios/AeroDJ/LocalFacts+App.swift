import AeroDJCore
import SwiftUI
import UIKit
#if canImport(WeatherKit)
import WeatherKit
#endif

// #401 wiring, app side (-Fry): the live owner of `LocalFactsWiring`, the Tune → DJ card that
// presents Echo's `LocalAreaPrompt`, and the player's provider marks while a fact line plays.
// Off by default (Sentinel, #410): the Weather and Local news switches start off and turning one
// on is the opt-in. The location prompt appears only right after one of them is switched on
// (`LocalFactsWiring.shouldAskForLocation`), never before and never for national news alone. No
// `CLLocationManager` exists and no location is read before that; "Not now" or swiping the
// prompt away turns the switch back off.

/// Owns the location manager lazily: `CoarseDeviceLocation()` creates a `CLLocationManager`, so
/// it is built only when the prompt is shown or an approximate read is allowed.
@MainActor
final class LazyCoarseDeviceLocation {
    private var made: CoarseDeviceLocation?
    var location: CoarseDeviceLocation {
        if let made { return made }
        let fresh = CoarseDeviceLocation()
        made = fresh
        return fresh
    }
    func currentArea() async -> LocalArea? { await location.currentArea() }
}

/// `CoarseLocationSource` over the lazy device location. `LocalAreaStore.resolveArea` calls it
/// only while consent is `.approximate`.
struct LazyDeviceCoarseLocationSource: CoarseLocationSource {
    let location: LazyCoarseDeviceLocation
    func currentArea() async -> LocalArea? { await location.currentArea() }
}

@MainActor
final class LocalFactsHost: ObservableObject {
    /// How often the loop looks; `LocalFactsWiring.interval` (15 min) decides when it refreshes.
    static let tick: Duration = .seconds(60)

    let wiring: LocalFactsWiring
    let location: LazyCoarseDeviceLocation
    private let preparer: DJBreakPreparer
    @Published private(set) var status: LocalFactsStatus
    /// Sentinel's N3: the per-kind switches, mirrored for the card.
    @Published private(set) var weatherOn: Bool
    @Published private(set) var newsOn: Bool
    private var tasks: [Task<Void, Never>] = []

    init(wiring: LocalFactsWiring, location: LazyCoarseDeviceLocation, preparer: DJBreakPreparer) {
        self.wiring = wiring
        self.location = location
        self.preparer = preparer
        status = wiring.status
        weatherOn = wiring.toggles.weather
        newsOn = wiring.toggles.news
    }

    /// Once per launch (`AppDependencies.start`): the take-time gate, the purge listeners, and
    /// the refresh loop. The loop refreshes only while music plays and the app is in the
    /// foreground ("only while the app is open"), and `refreshIfDue` checks consent first.
    func start(isPlaying: @escaping @MainActor () -> Bool) async {
        guard tasks.isEmpty else { return }
        await wiring.attach(to: preparer)
        tasks = wiring.listen(to: .shared)
        let purges = NarrationPurgeFeed.shared.updates()
        tasks.append(Task { [weak self] in
            for await purge in purges where purge == .all { self?.syncStatus() }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if isPlaying(), UIApplication.shared.applicationState == .active {
                    await self.wiring.refreshIfDue()
                }
                try? await Task.sleep(for: Self.tick)
            }
        })
    }

    /// The prompt was answered or dismissed. Declined: the location switches go back off.
    /// Granted: refresh with the new answer.
    func promptClosed() {
        wiring.locationPromptClosed()
        syncStatus()
        Task { await wiring.refreshIfDue() }   // both off: `.allOff`, nothing fetched
    }

    /// "Forget my location": withdraw (declined, typed place forgotten) and clear.
    func turnOff() {
        wiring.turnOff()
        syncStatus()
    }

    /// Returns whether the card must now show the location prompt (#410 prompt rule).
    func setWeather(_ on: Bool) -> Bool {
        wiring.setWeather(on)
        return switched(.weather, on: on)
    }

    func setNews(_ on: Bool) -> Bool {
        wiring.setNews(on)
        return switched(.news, on: on)
    }

    private func switched(_ which: LocalFactsSwitch, on: Bool) -> Bool {
        syncStatus()
        guard on else { return false }
        if wiring.shouldAskForLocation(afterSwitchingOn: which) { return true }
        Task { await wiring.refreshIfDue() }
        return false
    }

    func syncStatus() {
        status = wiring.status
        weatherOn = wiring.toggles.weather
        newsOn = wiring.toggles.news
    }
}

private struct LocalFactsKey: EnvironmentKey { static let defaultValue: LocalFactsHost? = nil }

extension EnvironmentValues {
    /// Set once at the app root (AeroDJApp), live only. Nil (test station, previews,
    /// StudioCapture): the Tune card is not shown and nothing changes.
    var localFacts: LocalFactsHost? {
        get { self[LocalFactsKey.self] }
        set { self[LocalFactsKey.self] = newValue }
    }
}

/// Tune → DJ: "Local weather & news". Outside Tune's blocked group like the cloud-voice card:
/// consent is not a station setting, so switching off always works; switching on waits while
/// settings are loading or read-only.
struct LocalFactsToggleCard: View {
    let settingsBlocked: Bool
    @Environment(\.localFacts) private var host

    var body: some View {
        if let host { LocalFactsToggleCardBody(host: host, settingsBlocked: settingsBlocked) }
    }
}

private struct LocalFactsToggleCardBody: View {
    @ObservedObject var host: LocalFactsHost
    let settingsBlocked: Bool
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalFactsCopy.title).font(.headline)
            // #410: both start off; switching one on is the opt-in, and only then (for weather or
            // local news, without location consent) the location prompt. N3: each is re-checked
            // at every break's take.
            Toggle(LocalFactsCopy.weatherToggle, isOn: Binding(get: { host.weatherOn }, set: { if host.setWeather($0) { asking = true } }))
                .accessibilityIdentifier("tune.localFactsWeather")
                .disabled(settingsBlocked && !host.weatherOn)   // off is always possible; on waits for Tune
            if TesterLocalNews.isCompiledIn {
                Toggle(LocalFactsCopy.newsToggle, isOn: Binding(get: { host.newsOn }, set: { if host.setNews($0) { asking = true } }))
                    .accessibilityIdentifier("tune.localFactsNews")
                    .disabled(settingsBlocked && !host.newsOn)
            }
            Text(LocalFactsCopy.detail(host.status))
                .font(.caption).foregroundStyle(AeroDJPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tune.localFactsDetail")
            if host.status != .off {
                Button(LocalFactsCopy.forgetLocation) { host.turnOff() }
                    .font(.caption)
                    .accessibilityIdentifier("tune.localFactsForget")
            }
            if TesterLocalNews.isCompiledIn {
                // GDELT's terms: credited wherever local news is explained (tester build only).
                GDELTCitationLink().font(.caption)
            }
        }
        .padding(14)
        .workspaceCardBackground(Color(.tertiarySystemFill).opacity(0.6))
        .onAppear { host.syncStatus() }
        .sheet(isPresented: $asking, onDismiss: { host.promptClosed() }) {
            LocalAreaPrompt(store: host.wiring.store, location: host.location.location) { asking = false }
                .presentationDetents([.medium, .large])
        }
    }
}

/// "Local news data: The GDELT Project (gdeltproject.org)", linking to gdeltproject.org.
struct GDELTCitationLink: View {
    var body: some View {
        Link(destination: FactAttribution.gdeltURL) {
            Text(FactAttribution.gdeltCitation).underline()
        }
        .foregroundStyle(AeroDJPalette.secondaryText)
        .accessibilityIdentifier("attribution.gdelt")
    }
}

/// While a weather or local-news line plays: the provider's mark and link, in the same glass
/// capsule as the station-start toast. Nothing for any other line.
struct FactAttributionBadge: View {
    let mark: FactAttributionMark

    var body: some View {
        Group {
            switch mark {
            case .appleWeather: AppleWeatherAttributionMark()
            case .gdelt: GDELTCitationLink().font(.caption2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .aeroGlass(Capsule(), fallback: AnyShapeStyle(.regularMaterial), hairline: Color.primary.opacity(0.12))
        .transition(.opacity)
    }
}

/// WeatherKit's display requirement: the Apple Weather mark (light or dark, from
/// `WeatherService.attribution`) and a link to its legal page. Until the attribution loads, the
/// text mark and Apple's published legal page.
struct AppleWeatherAttributionMark: View {
    @Environment(\.colorScheme) private var scheme
    @State private var attribution: AppleWeatherAttributionInfo?

    var body: some View {
        HStack(spacing: 8) {
            if let url = attribution.map({ scheme == .dark ? $0.darkMark : $0.lightMark }) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Text("\u{F8FF} Weather").font(.caption.weight(.semibold))
                }
                .frame(height: 14)
                .accessibilityLabel("Apple Weather")
            } else {
                Text("\u{F8FF} Weather").font(.caption.weight(.semibold)).accessibilityLabel("Apple Weather")
            }
            Link(LocalFactsCopy.weatherLegal, destination: attribution?.legal ?? AppleWeatherAttributionInfo.fallbackLegal)
                .font(.caption2).underline()
                .accessibilityIdentifier("attribution.weatherLegal")
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("attribution.appleWeather")
        .task {
            guard attribution == nil else { return }
            attribution = await AppleWeatherAttributionCache.load()
        }
    }
}

struct AppleWeatherAttributionInfo: Equatable, Sendable {
    static let fallbackLegal = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!
    let lightMark: URL
    let darkMark: URL
    let legal: URL
}

/// Loaded once per launch, on the first weather line (after consent: no weather line exists before).
@MainActor
enum AppleWeatherAttributionCache {
    private static var info: AppleWeatherAttributionInfo?

    static func load() async -> AppleWeatherAttributionInfo? {
        if let info { return info }
        #if canImport(WeatherKit)
        guard let a = try? await WeatherService.shared.attribution else { return nil }
        let loaded = AppleWeatherAttributionInfo(lightMark: a.combinedMarkLightURL, darkMark: a.combinedMarkDarkURL,
                                                 legal: a.legalPageURL)
        info = loaded
        return loaded
        #else
        return nil
        #endif
    }
}
