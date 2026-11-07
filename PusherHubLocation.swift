import CoreLocation
import Foundation

/**
 * PusherHub's optional location add-on, only for an app that already uses
 * location: one that already asks for location access itself, and so
 * already has NSLocationWhenInUseUsageDescription in its Info.plist. Add this
 * file next to PusherHub.swift and pass it to collectDeviceMetadata:
 *
 *   PusherHub.collectDeviceMetadata(location: PusherHubLocation.place)
 *
 * It never asks for permission. It reads the phone's location only when the
 * person has already allowed it for this app, and returns nil otherwise, so
 * PusherHub finds state and city from the IP address. It uses Apple's own
 * geocoder: no extra library or API key.
 */
@MainActor
public enum PusherHubLocation {

    /// State, city and country from one rough location fix, or nil when this
    /// app has no location access, location is off, or nothing arrives
    /// within 15 seconds.
    public static func place() async -> PusherHubPlace? {
        await withCheckedContinuation { continuation in
            PusherHubLocationFix().start { continuation.resume(returning: $0) }
        }
    }
}

/// One When In Use location fix, reverse-geocoded. Keeps itself alive until
/// it has called its completion, which it always does exactly once.
@MainActor
private final class PusherHubLocationFix: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var completion: ((PusherHubPlace?) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var keepAlive: PusherHubLocationFix?
    private var geocoding = false

    func start(completion: @escaping (PusherHubPlace?) -> Void) {
        self.completion = completion

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            // Not allowed (or not asked yet): PusherHub never asks.
            finish(nil)
            return
        }

        keepAlive = self
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(nil)
        }

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        Task { @MainActor in geocode(latitude: latitude, longitude: longitude) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in finish(nil) }
    }

    private func geocode(latitude: Double, longitude: Double) {
        // One answer is enough: a second lookup would cancel the first.
        guard completion != nil, !geocoding else { return }
        geocoding = true
        geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)) { @Sendable placemarks, _ in
            let placemark = placemarks?.first
            let found = placemark != nil
            let state = placemark?.administrativeArea
            let city = placemark?.locality
            let country = placemark?.country
            Task { @MainActor in
                self.finish(found ? PusherHubPlace(state: state, city: city, country: country) : nil)
            }
        }
    }

    private func finish(_ place: PusherHubPlace?) {
        guard let completion else { return }
        self.completion = nil
        timeoutTask?.cancel()
        manager.delegate = nil
        keepAlive = nil
        completion(place)
    }
}
