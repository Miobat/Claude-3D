import Foundation
import CoreLocation

/// Fresh GPS observations for one capture, stopped when capture finishes.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var requestedAt: Date?
    @Published private(set) var lastLocation: CaptureLocation?
    @Published private(set) var status = "Local coordinates — no GPS fix"

    /// Ask for permission if needed, then collect fresh observations until Stop.
    func requestFix() {
        stop()
        lastLocation = nil
        requestedAt = Date()
        status = "Waiting for current phone GPS…"
        let next = CLLocationManager()
        manager = next
        next.desiredAccuracy = kCLLocationAccuracyBest
        next.distanceFilter = kCLDistanceFilterNone
        next.delegate = self
        requestAuthorizedUpdates(next)
    }

    private func requestAuthorizedUpdates(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            lastLocation = nil
            status = "Location unavailable — scanning in local coordinates"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager, requestedAt != nil else { return }
        requestAuthorizedUpdates(manager)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === self.manager, let requestedAt else { return }
        let now = Date()
        let valid = locations.compactMap { location in
            CaptureLocation.validated(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy, altitude: location.altitude,
                verticalAccuracy: location.verticalAccuracy, timestamp: location.timestamp,
                requestedAt: requestedAt, now: now, reducedAccuracy: manager.accuracyAuthorization == .reducedAccuracy)
        }
        if let best = valid.max(by: { $0.timestamp < $1.timestamp }) {
            if lastLocation == nil || best.timestamp >= lastLocation!.timestamp { lastLocation = best }
            status = String(format: "Approximate phone GPS ±%.0f m — not survey control", best.horizontalAccuracy)
        } else if currentFix(now: now) == nil {
            lastLocation = nil
            status = "No fresh GPS fix — scanning in local coordinates"
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === self.manager else { return }
        lastLocation = nil
        status = "GPS unavailable — scanning in local coordinates"
        DebugLogger.shared.warn("Location unavailable: \(error.localizedDescription)", category: "Location")
    }

    func currentFix(now: Date = Date()) -> CaptureLocation? {
        guard let fix = lastLocation, now.timeIntervalSince(fix.timestamp) <= 30 else { return nil }
        return fix
    }

    func finishCapture() -> CaptureLocation? {
        let result = currentFix()
        stop()
        return result
    }

    func stop() {
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        requestedAt = nil
    }
}
