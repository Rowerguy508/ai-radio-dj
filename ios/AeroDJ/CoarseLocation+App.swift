import AeroDJCore
import CoreLocation
import Foundation

/// #200 (-Echo): the device's approximate area for local weather and news. When-in-use only,
/// reduced accuracy only (`NSLocationDefaultAccuracyReduced` in Info.plist, and
/// `kCLLocationAccuracyReduced` here); it never asks for temporary full accuracy. Asks Core
/// Location only after the user picked "Use approximate location" in `LocalAreaPrompt`.
/// Returns a city/region plus a coordinate rounded to 0.1°. Nothing is logged.
@MainActor
final class CoarseDeviceLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Shows the system when-in-use prompt if the user has not answered it yet.
    func requestWhenInUse() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }

    /// One approximate fix, reverse-geocoded on the device by Apple. Nil when not allowed or failed.
    func currentArea() async -> LocalArea? {
        guard isAuthorized else { return nil }
        let location: CLLocation? = await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            manager.requestLocation()
        }
        guard let location else { return nil }
        let coordinate = CoarseCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        // Geocode the rounded point, not the fix.
        let rounded = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(rounded).first
        return LocalArea(locality: placemark?.locality, region: placemark?.administrativeArea,
                         countryCode: placemark?.isoCountryCode, coordinate: coordinate, origin: .device)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        Task { @MainActor in
            let waiters = authorizationWaiters; authorizationWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in finishLocation(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in finishLocation(nil) }
    }

    private func finishLocation(_ location: CLLocation?) {
        let waiters = locationWaiters; locationWaiters = []
        waiters.forEach { $0.resume(returning: location) }
    }
}

/// `CoarseLocationSource` over the device location; reads it only while consent is `.approximate`
/// (`LocalAreaStore.resolveArea` checks before and after).
struct DeviceCoarseLocationSource: CoarseLocationSource {
    let location: CoarseDeviceLocation
    func currentArea() async -> LocalArea? { await location.currentArea() }
}

/// Typed city or ZIP to an area, geocoded by Apple on the device. The coordinate is rounded to
/// 0.1°; the ZIP itself is never kept in the area or sent to a news source.
struct GeocodedManualPlace: ManualPlaceResolver {
    func resolve(_ place: String) async -> LocalArea? {
        guard let placemark = try? await CLGeocoder().geocodeAddressString(place).first else { return nil }
        let coordinate = placemark.location.map {
            CoarseCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        return LocalArea(locality: placemark.locality, region: placemark.administrativeArea,
                         countryCode: placemark.isoCountryCode, coordinate: coordinate, origin: .manual)
    }
}
