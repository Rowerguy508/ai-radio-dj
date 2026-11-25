#if canImport(WeatherKit) && canImport(CoreLocation)
import CoreLocation
import Foundation
import WeatherKit

/// #200 (-Echo): current conditions and today's range from Apple WeatherKit, on the device.
///
/// Needs the WeatherKit capability on the App ID and `com.apple.developer.weatherkit` in the
/// signed entitlements. Without them every call fails, which this reports as
/// `.omitted(.unavailable)` (never a guess). Not wired by default.
///
/// Sends Apple only the area's coarse coordinate (0.1 degree). No city name, no ZIP, no logging.
/// 500,000 calls a month are included in the Apple Developer Program; call at most once per
/// `minimumRefresh` per area (a station hour is a handful of calls).
@available(iOS 16.0, macOS 13.0, *)
public struct WeatherKitWeatherProvider: WeatherProvider {
    public let kind = BroadcastFactKind.weather
    /// Never trust a reading longer than this, even if WeatherKit's metadata allows it.
    public var maximumValidity: TimeInterval

    public init(maximumValidity: TimeInterval = 30 * 60) {
        self.maximumValidity = maximumValidity
    }

    public func facts(for request: FactRequest) async -> FactProviderResult {
        guard let coordinate = request.area?.coordinate else { return .omitted(.noLocation) }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let service = WeatherService.shared
            let (current, daily) = try await service.weather(for: location, including: .current, .daily)
            let attribution = try? await service.attribution
            let unit: UnitTemperature = request.unit == .celsius ? .celsius : .fahrenheit
            func degrees(_ m: Measurement<UnitTemperature>) -> Int { Int(m.converted(to: unit).value.rounded()) }
            let today = daily.forecast.first
            let fact = WeatherFact(
                condition: current.condition.description.lowercased(),
                temperature: degrees(current.temperature), unit: request.unit,
                high: today.map { degrees($0.highTemperature) }, low: today.map { degrees($0.lowTemperature) },
                precipitationChancePercent: today.map { Int(($0.precipitationChance * 100).rounded()) })
            let observed = current.date
            let expires = min(current.metadata.expirationDate, observed.addingTimeInterval(maximumValidity))
            guard expires > request.now else { return .omitted(.unavailable) }
            return .facts([BroadcastFact(kind: .weather, payload: .weather(fact), observedAt: observed, expiresAt: expires,
                                         attribution: .appleWeather(legalURL: attribution?.legalPageURL))])
        } catch {
            return .omitted(.unavailable)
        }
    }
}
#endif
