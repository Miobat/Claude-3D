import Foundation
import CoreLocation

/// One GPS fix, used to record where a compass-aligned scan was taken.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published private(set) var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Ask for permission if needed, then get the current position once.
    func requestFix() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let best = locations.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) {
            lastLocation = best
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DebugLogger.shared.warn("Location unavailable: \(error.localizedDescription)", category: "Location")
    }
}
