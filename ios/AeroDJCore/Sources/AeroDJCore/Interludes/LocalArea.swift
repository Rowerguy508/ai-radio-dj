import Foundation

// #200 local weather and news (-Echo). The listener's area, coarse by construction.
//
// Collected only with opt-in consent: the device's approximate (reduced-accuracy, when-in-use)
// location, or a city or ZIP the listener types instead. Where it goes:
// - WeatherKit (on the device, Apple's service): the coarse coordinate, rounded to 0.1 degree.
// - A news provider: city and region only (`newsQuery`), never a coordinate or a ZIP.
// - Never a voice route or the TTS proxy: no voice request has a location field
//   (`ProxyVoiceProvider`). Lines say "here", not the place name. A fact line carries a
//   provenance, which keeps it on the device (`VoiceRenderer.mayLeaveDevice`) unless the
//   listener accepted cloud-voice copy v2 (`CloudVoiceScope.allLines`): then the line's words
//   (weather, a headline) go to the voice service, still with no location field.
// - Never a log: diagnostics are kind, code and counts.
// Kept: the consent answer and a typed place in UserDefaults until the listener withdraws or a
// purge-all runs (`LocalAreaStore.listen(to:)`); a resolved device area in memory only.

/// A coordinate rounded to `step` degrees (0.1 degree is about 11 km), so it names a town, not a street.
public struct CoarseCoordinate: Codable, Equatable, Sendable {
    public static let step = 0.1
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        func round(_ v: Double) -> Double { (v / Self.step).rounded() * Self.step }
        self.latitude = min(90, max(-90, round(latitude)))
        self.longitude = min(180, max(-180, round(longitude)))
    }
}

/// The listener's area: city and region, and on the device only, a coarse coordinate.
public struct LocalArea: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case device, manual }
    public var locality: String?
    public var region: String?
    public var countryCode: String?
    /// WeatherKit only (on the device). Rounded by `CoarseCoordinate`.
    public var coordinate: CoarseCoordinate?
    public var origin: Origin

    public init(locality: String?, region: String?, countryCode: String?, coordinate: CoarseCoordinate?,
                origin: Origin) {
        self.locality = LocalAreaStore.cleanPlace(locality ?? "")
        self.region = LocalAreaStore.cleanPlace(region ?? "")
        self.countryCode = countryCode.flatMap { $0.count == 2 ? $0.uppercased() : nil }
        self.coordinate = coordinate
        self.origin = origin
    }

    /// What a news provider may be sent: "City, Region", or just one of them. Never a coordinate,
    /// a ZIP or street. Nil when neither is known (local news is then omitted).
    public var newsQuery: String? {
        let parts = [locality, region].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

public enum LocationConsentState: String, Codable, Sendable {
    /// Never asked, or dismissed. Not consent.
    case undecided
    /// "Use approximate location": reduced accuracy, when in use.
    case approximate
    /// "Enter a city or ZIP instead".
    case manual
    /// "Not now", or withdrawn. Weather and local news are reported omitted.
    case declined

    public var allowsLocation: Bool { self == .approximate || self == .manual }
}

/// App-side source of the device's approximate area (CoreLocation reduced accuracy plus reverse
/// geocoding). Nil when unavailable or not authorized.
public protocol CoarseLocationSource: Sendable {
    func currentArea() async -> LocalArea?
}

/// App-side resolver for a typed city or ZIP (on-device geocoder). Nil when not found.
public protocol ManualPlaceResolver: Sendable {
    func resolve(_ place: String) async -> LocalArea?
}

/// Location consent and the typed place, on the device. Fail-closed: anything unreadable is
/// `.undecided`, which allows nothing. Copies of an in-memory store share state.
public final class LocalAreaStore: @unchecked Sendable {
    public static let consentKey = "AeroDJ.localArea.consent"
    public static let manualPlaceKey = "AeroDJ.localArea.manualPlace"
    public static let maxPlaceLength = 64

    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var memoryConsent: LocationConsentState = .undecided
    private var memoryPlace: String?
    /// Last resolved area, this app run only.
    private var cachedArea: LocalArea?

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private init() { self.defaults = nil }
    public static func inMemory() -> LocalAreaStore { LocalAreaStore() }

    public var consent: LocationConsentState {
        lock.withLock {
            guard let defaults else { return memoryConsent }
            return defaults.string(forKey: Self.consentKey).flatMap(LocationConsentState.init(rawValue:)) ?? .undecided
        }
    }

    public var manualPlace: String? {
        lock.withLock { defaults.map { $0.string(forKey: Self.manualPlaceKey) } ?? memoryPlace }
    }

    /// The area last resolved this run, while consent still allows it.
    public var area: LocalArea? { consent.allowsLocation ? lock.withLock { cachedArea } : nil }

    public func chooseApproximate() { write(.approximate, place: nil) }

    /// Stores a typed city or ZIP. Returns false (and stores nothing) when it is empty, too long,
    /// or has characters a place name does not.
    @discardableResult
    public func chooseManual(_ place: String) -> Bool {
        guard let clean = Self.cleanPlace(place) else { return false }
        write(.manual, place: clean)
        return true
    }

    public func decline() { write(.declined, place: nil) }

    /// Consent withdrawal and purge-all: forget the answer's grant, the typed place and the area.
    public func withdraw() {
        write(.declined, place: nil)
        lock.withLock { cachedArea = nil }
    }

    public func remember(_ area: LocalArea?) {
        lock.withLock { cachedArea = area }
    }

    /// A purge-all (`NarrationPurgeFeed` `.all`: consent withdrawal, data reset) withdraws location
    /// too. Keep the returned task for the app's lifetime.
    @discardableResult
    public func listen(to feed: NarrationPurgeFeed) -> Task<Void, Never> {
        let updates = feed.updates()
        return Task { [weak self] in
            for await purge in updates where purge == .all { self?.withdraw() }
        }
    }

    /// Resolves the area for this consent: the device's approximate area, or the typed place.
    /// Nil without consent; the area is remembered for this run only.
    public func resolveArea(device: (any CoarseLocationSource)?, manual: (any ManualPlaceResolver)?) async -> LocalArea? {
        let resolved: LocalArea?
        switch consent {
        case .approximate:
            resolved = await device?.currentArea()
        case .manual:
            guard let place = manualPlace else { resolved = nil; break }
            if let found = await manual?.resolve(place) {
                resolved = found
            } else if place.contains(where: \.isLetter) {
                // Unresolved city text still names a city for news; weather needs a coordinate.
                resolved = LocalArea(locality: place, region: nil, countryCode: nil, coordinate: nil, origin: .manual)
            } else {
                resolved = nil   // an unresolved ZIP is not a city: never sent to news as is
            }
        case .undecided, .declined:
            resolved = nil
        }
        // Consent may have changed while resolving: re-read, fail closed.
        guard consent.allowsLocation else { remember(nil); return nil }
        remember(resolved)
        return resolved
    }

    /// Fact-cue gate for `DJBreakPreparer.setFactCueGate`: a location-needing fact line airs only
    /// while location consent holds.
    public func allowsFactCue(_ cue: NarrationCue) -> Bool {
        guard let kind = FactProvenance.kind(of: cue.provenance) else { return true }
        return !kind.needsLocation || consent.allowsLocation
    }

    private func write(_ state: LocationConsentState, place: String?) {
        lock.withLock {
            cachedArea = nil
            if let defaults {
                defaults.set(state.rawValue, forKey: Self.consentKey)
                if let place { defaults.set(place, forKey: Self.manualPlaceKey) } else { defaults.removeObject(forKey: Self.manualPlaceKey) }
            } else {
                memoryConsent = state
                memoryPlace = place
            }
        }
    }

    /// Trimmed, single-spaced, at most `maxPlaceLength`, letters, digits, spaces and , . - ' only.
    public static func cleanPlace(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= maxPlaceLength else { return nil }
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " ,.-'"))
        guard collapsed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return collapsed
    }
}

/// Copy for the opt-in prompt (`LocalAreaPrompt` in the app). Versioned like the cloud-voice copy.
///
/// #625 (-Echo): the title and body say only what this build does (privacy.md, #624):
/// - every build: Apple's geocoding service (`CLGeocoder` in `CoarseLocation+App.swift`) gets the
///   coordinate rounded to 0.1 degree, or the typed city or ZIP, to find the city or region; Apple
///   Weather (WeatherKit) gets the rounded point.
/// - local news (GDELT, `TesterLocalNews.isCompiledIn`: `AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB`):
///   the city or region name goes to the news source.
/// - cloud voice (`AERODJ_TESTER_VOICE` or `AERODJ_OWNER_AB`, `CloudVoiceConsentPrompt`): the
///   words of weather (and, with local news, news) lines can go to the voice service, never the
///   coordinates or the location itself. Debug, Release and App Store builds have neither.
public enum LocalAreaConsentCopy {
    public static let version = 2

    /// What a build can do with the listener's area, beyond Apple's geocoding and weather.
    public struct Build: Equatable, Sendable {
        /// A news provider gets the city or region name (GDELT, tester build only).
        public var localNews: Bool
        /// A cloud voice can be turned on (tester and owner A/B builds).
        public var cloudVoice: Bool

        public init(localNews: Bool, cloudVoice: Bool) {
            self.localNews = localNews
            self.cloudVoice = cloudVoice
        }

        /// Debug, Release and App Store builds: no news provider, no cloud voice.
        public static let appStore = Build(localNews: false, cloudVoice: false)
        /// `AERODJ_OWNER_AB`: the owner's cloud-voice trial, no news provider.
        public static let ownerAB = Build(localNews: false, cloudVoice: true)
        /// `AERODJ_TESTER_VOICE` alone (internal TestFlight): GDELT local news and the cloud voice.
        public static let tester = Build(localNews: true, cloudVoice: true)

        /// The same mapping the providers use, from the two Swift conditions.
        public static func flags(ownerAB: Bool, testerVoice: Bool) -> Build {
            Build(localNews: testerVoice && !ownerAB, cloudVoice: ownerAB || testerVoice)
        }

        /// The build this module was compiled as.
        public static var current: Build {
            Build(localNews: TesterLocalNews.isCompiledIn,
                  cloudVoice: TesterVoice.enabled || OwnerVoiceTrial.paidProvidersEnabled)
        }
    }

    /// The prompt title for this build: "and news" only where a news provider is compiled in.
    public static var title: String { title(for: .current) }

    public static func title(for build: Build) -> String {
        build.localNews ? "Local weather and news?" : "Local weather?"
    }

    /// The prompt body for this build.
    public static var body: String { body(for: .current) }

    public static func body(for build: Build) -> String {
        var parts = [
            build.localNews
                ? "OnAirly can mention your local weather and headlines between songs."
                : "OnAirly can mention your local weather between songs.",
            "It uses your approximate location only, while the app is open.",
            "To find your city or region, Apple's geocoding service gets your approximate location, "
                + "rounded, or the city or ZIP you type.",
            build.localNews
                ? "Your city or region is sent to the news source, and Apple Weather gets an approximate point."
                : "Apple Weather gets an approximate point.",
        ]
        if build.cloudVoice {
            parts.append("Your coordinates and your location itself are never sent to the voice service.")
            parts.append(build.localNews
                ? "If you turn on the cloud voice, the words of weather and news lines are sent to it, "
                    + "and a local headline can name your city or area."
                : "If you turn on the cloud voice, the words of weather lines are sent to it.")
        }
        return parts.joined(separator: " ")
    }

    public static let useApproximate = "Use approximate location"
    public static let enterPlace = "Enter a city or ZIP instead"
    public static let notNow = "Not now"
    public static let placeFieldPrompt = "City or ZIP"
    /// NSLocationWhenInUseUsageDescription (app Info.plist).
    public static let usageDescription = "OnAirly uses your approximate location, only while the app is open, to mention local weather and news between songs. Your location itself is never sent to the voice service."
}
