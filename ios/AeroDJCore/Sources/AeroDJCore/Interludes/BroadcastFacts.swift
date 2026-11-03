import Foundation

// #200 news & weather in DJ commentary (-Echo). Provider facts for the DJ to speak.
//
// One seam for every outside fact a DJ line may say: weather (Apple WeatherKit), news (source not
// chosen yet), and, by design, Nova's personal content and Fry's Apple Music artist info. A provider
// returns small typed facts; it never returns script text. `FactInterludeComposer` writes the lines,
// only from fact fields, so every spoken word traces to one fact (`BroadcastFact.provenance`).
//
// Rules this file carries:
// - Every fact has an `observedAt`, an `expiresAt` and an attribution. A fact at or past its expiry
//   is never spoken: the composer drops it at plan time and `DJBreakPreparer.takeBreak` drops its
//   line at the take (`NarrationCue.expiresAt`). Both report counts only.
// - A fact that needs the listener's area (`kind.needsLocation`) is only asked for with location
//   consent and a coarse area (`LocalArea`). Without them the provider is not called and the cue is
//   reported omitted (`FactOmission.noLocation`), never invented or guessed.
// - Nothing here logs. Diagnostics are kind, code and counts (`FactCueCounts`), never text or place.

/// What a fact is about. Raw values are stable diag codes.
/// #200: which field of a fact a spoken value came from (provenance only, never spoken). Also the
/// only placeholders `FactLineTemplates` may use.
public enum BroadcastFactField: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case temperature, condition, high, low, precipitationChance
    case headline, outlet
    /// The spoken name of the fact's source ("Apple Weather").
    case source
    /// A whole `approvedSentence`.
    case sentence
}

public enum BroadcastFactKind: String, Codable, Sendable, CaseIterable {
    case weather
    /// Headlines for the listener's city or region.
    case localNews
    /// National or world headlines.
    case news
    /// Reserved for Nova's personal content (#200 parallel lane), if it moves onto this seam.
    case personal
    /// Reserved for Fry's Apple Music artist info (#200 parallel lane).
    case artistInfo

    /// Needs the listener's coarse area, so it is location-consent gated.
    public var needsLocation: Bool { self == .weather || self == .localNews }
}

/// Who a fact came from and what its terms ask for.
public struct FactAttribution: Codable, Equatable, Sendable {
    /// Stable provider code, e.g. "apple-weather". Safe for diagnostics.
    public var providerID: String
    /// Name the DJ says when it credits the source aloud ("Apple Weather", "NPR").
    public var spokenName: String
    /// The provider's terms require the source to be named with the content. For news this is
    /// every outlet; for WeatherKit the visual mark is required and the spoken credit is our choice.
    public var requiresSpokenCredit: Bool
    /// Legal or source page shown in the app beside the content (WeatherKit `legalPageURL`).
    public var legalURL: URL?

    public init(providerID: String, spokenName: String, requiresSpokenCredit: Bool, legalURL: URL? = nil) {
        self.providerID = providerID
        self.spokenName = spokenName
        self.requiresSpokenCredit = requiresSpokenCredit
        self.legalURL = legalURL
    }
}

public enum TemperatureUnit: String, Codable, Sendable { case celsius, fahrenheit }

/// Current conditions plus today's range, already in the listener's unit.
public struct WeatherFact: Codable, Equatable, Sendable {
    /// Lowercase condition phrase from the provider ("partly cloudy", "light rain").
    public var condition: String
    public var temperature: Int
    public var unit: TemperatureUnit
    public var high: Int?
    public var low: Int?
    /// 0...100. Spoken only at or above `FactInterludeComposer.rainChanceToMention`.
    public var precipitationChancePercent: Int?

    public init(condition: String, temperature: Int, unit: TemperatureUnit, high: Int? = nil, low: Int? = nil,
                precipitationChancePercent: Int? = nil) {
        self.condition = condition
        self.temperature = temperature
        self.unit = unit
        self.high = high
        self.low = low
        self.precipitationChancePercent = precipitationChancePercent
    }
}

/// One headline, as published, and its outlet.
public struct HeadlineFact: Codable, Equatable, Sendable {
    public var headline: String
    /// Outlet that published it (spoken: "From NPR: ..."). May differ from the feed provider.
    public var outlet: String
    public init(headline: String, outlet: String) {
        self.headline = headline
        self.outlet = outlet
    }
}

public enum FactPayload: Codable, Equatable, Sendable {
    case weather(WeatherFact)
    case headline(HeadlineFact)
    /// A complete sentence some other lane already approved (Nova's personal content, Fry's artist
    /// info). Spoken as is; the providing lane owns its consent and sanitizing.
    case approvedSentence(String)
}

public struct BroadcastFact: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: BroadcastFactKind
    public let payload: FactPayload
    /// When the provider observed or published it.
    public let observedAt: Date
    /// After this it is not true enough to air. Required: a fact without one cannot be built.
    public let expiresAt: Date
    public let attribution: FactAttribution
    /// The provider's own id for the item (an article URL, a catalog song id), like #199's
    /// `CatalogFactProvenance.catalogSongID`. Provenance only: never spoken, never logged.
    public let sourceItemID: String?

    public init(id: UUID = UUID(), kind: BroadcastFactKind, payload: FactPayload, observedAt: Date,
                expiresAt: Date, attribution: FactAttribution, sourceItemID: String? = nil) {
        self.id = id
        self.sourceItemID = sourceItemID
        self.kind = kind
        self.payload = payload
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.attribution = attribution
    }

    public func isLive(at now: Date) -> Bool { expiresAt > now }

    /// `fact:<kind>:<id>`, set on the cue (`NarrationCue.provenance`). IDs only, no content.
    public var provenance: String { FactProvenance.make(kind: kind, id: id) }
}

/// The provenance string a fact cue carries.
public enum FactProvenance {
    public static let prefix = "fact:"
    public static func make(kind: BroadcastFactKind, id: UUID) -> String { "\(prefix)\(kind.rawValue):\(id.uuidString)" }
    public static func isFact(_ provenance: String?) -> Bool { provenance?.hasPrefix(prefix) == true }
    public static func kind(of provenance: String?) -> BroadcastFactKind? {
        guard let provenance, isFact(provenance) else { return nil }
        let parts = provenance.dropFirst(prefix.count).split(separator: ":", maxSplits: 1)
        return parts.first.flatMap { BroadcastFactKind(rawValue: String($0)) }
    }
}

/// Why a kind produced nothing. Raw values are diag codes.
public enum FactOmission: String, Codable, Sendable, CaseIterable {
    /// No location consent, or consent but no usable area. The cue is reported, not invented.
    case noLocation
    /// No provider configured for this kind (news until a source is chosen).
    case notConfigured
    /// The provider failed or returned nothing usable (offline, quota, missing entitlement).
    case unavailable
}

/// What a provider is asked for. The area is coarse by construction (`LocalArea`).
public struct FactRequest: Sendable, Equatable {
    public var now: Date
    /// Nil without location consent. Providers of `needsLocation` kinds are not called then.
    public var area: LocalArea?
    public var unit: TemperatureUnit
    public var maxFacts: Int

    public init(now: Date, area: LocalArea?, unit: TemperatureUnit = .fahrenheit, maxFacts: Int = 3) {
        self.now = now
        self.area = area
        self.unit = unit
        self.maxFacts = maxFacts
    }
}

public enum FactProviderResult: Sendable, Equatable {
    case facts([BroadcastFact])
    case omitted(FactOmission)
}

/// The one seam for outside facts. Nova's and Fry's lanes can conform with their own kinds.
public protocol BroadcastFactProvider: Sendable {
    var kind: BroadcastFactKind { get }
    func facts(for request: FactRequest) async -> FactProviderResult
}

public protocol WeatherProvider: BroadcastFactProvider {}
public protocol NewsProvider: BroadcastFactProvider {}

/// Count-only diagnostics for one gather or compose pass. Never text, IDs of places, or areas.
public struct FactCueCounts: Equatable, Sendable {
    public var offered = 0
    public var expired = 0
    public var omittedNoLocation = 0
    public var notConfigured = 0
    public var unavailable = 0
    /// Over the commentary or briefing cap, or a headline too long to say whole.
    public var overCap = 0
    public var kept = 0
    public init() {}
}

/// Count-only diagnostics for fact lines dropped at the take (`DJBreakPreparer.observeFactCueDrops`).
public struct FactCueDropCounts: Equatable, Sendable {
    public var expired = 0
    /// Refused by the preparer's fact gate (location consent withdrawn, source off).
    public var notAllowed = 0
    /// Cues left in the break.
    public var kept = 0
    public init(expired: Int = 0, notAllowed: Int = 0, kept: Int = 0) {
        self.expired = expired
        self.notAllowed = notAllowed
        self.kept = kept
    }
}

/// Asks each provider, applying the location gate first. The only place providers are called.
public struct BroadcastFactGatherer: Sendable {
    public let providers: [any BroadcastFactProvider]
    public init(providers: [any BroadcastFactProvider]) { self.providers = providers }

    public func gather(_ request: FactRequest) async -> (facts: [BroadcastFact], counts: FactCueCounts) {
        var counts = FactCueCounts()
        var facts: [BroadcastFact] = []
        for provider in providers {
            counts.offered += 1
            if provider.kind.needsLocation, request.area == nil {
                // Not called at all: no location reaches a provider without consent.
                counts.omittedNoLocation += 1
                continue
            }
            var scoped = request
            if !provider.kind.needsLocation { scoped.area = nil }   // national news never sees the area
            switch await provider.facts(for: scoped) {
            case .omitted(.noLocation): counts.omittedNoLocation += 1
            case .omitted(.notConfigured): counts.notConfigured += 1
            case .omitted(.unavailable): counts.unavailable += 1
            case .facts(let got):
                let mine = got.filter { $0.kind == provider.kind }
                let live = mine.filter { $0.isLive(at: request.now) }
                counts.expired += mine.count - live.count
                if live.isEmpty, mine.isEmpty { counts.unavailable += 1 }
                facts += live.prefix(max(0, request.maxFacts))
            }
        }
        return (facts, counts)
    }
}

// MARK: - Null and fixture providers (tests, previews, and news until a source is chosen)

/// Always `.omitted(.notConfigured)`. The default for news until the owner picks a source.
public struct NullFactProvider: WeatherProvider, NewsProvider {
    public let kind: BroadcastFactKind
    public init(kind: BroadcastFactKind) { self.kind = kind }
    public func facts(for request: FactRequest) async -> FactProviderResult { .omitted(.notConfigured) }
}

/// Fixed weather, stamped relative to the request's clock. Never reads the network.
public struct FixtureWeatherProvider: WeatherProvider {
    public let kind = BroadcastFactKind.weather
    public var weather: WeatherFact
    public var validFor: TimeInterval
    public var age: TimeInterval
    public init(weather: WeatherFact = WeatherFact(condition: "partly cloudy", temperature: 54, unit: .fahrenheit,
                                                   high: 61, low: 47, precipitationChancePercent: 10),
                validFor: TimeInterval = 15 * 60, age: TimeInterval = 0) {
        self.weather = weather
        self.validFor = validFor
        self.age = age
    }
    public func facts(for request: FactRequest) async -> FactProviderResult {
        guard request.area != nil else { return .omitted(.noLocation) }
        let observed = request.now.addingTimeInterval(-age)
        return .facts([BroadcastFact(kind: .weather, payload: .weather(weather), observedAt: observed,
                                     expiresAt: observed.addingTimeInterval(validFor),
                                     attribution: .appleWeather(legalURL: nil))])
    }
}

/// Fixed headlines. Local headlines need an area like any local source.
public struct FixtureNewsProvider: NewsProvider {
    public let kind: BroadcastFactKind
    public var headlines: [HeadlineFact]
    public var validFor: TimeInterval
    public init(kind: BroadcastFactKind = .news, headlines: [HeadlineFact], validFor: TimeInterval = 60 * 60) {
        self.kind = kind
        self.headlines = headlines
        self.validFor = validFor
    }
    public func facts(for request: FactRequest) async -> FactProviderResult {
        if kind.needsLocation, request.area == nil { return .omitted(.noLocation) }
        guard !headlines.isEmpty else { return .omitted(.unavailable) }
        return .facts(headlines.map {
            BroadcastFact(kind: kind, payload: .headline($0), observedAt: request.now,
                          expiresAt: request.now.addingTimeInterval(validFor),
                          attribution: FactAttribution(providerID: "fixture-news", spokenName: $0.outlet,
                                                       requiresSpokenCredit: true))
        })
    }
}

extension FactAttribution {
    /// Apple Weather (WeatherKit). The visual mark and legal link are required where weather is
    /// shown; we also credit it aloud, which the terms do not require (conservative, #200).
    public static func appleWeather(legalURL: URL?) -> FactAttribution {
        FactAttribution(providerID: "apple-weather", spokenName: "Apple Weather", requiresSpokenCredit: true,
                        legalURL: legalURL)
    }
}
