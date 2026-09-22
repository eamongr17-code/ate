import CoreLocation
import Foundation

/// **Where the phone is — asked for once, on one screen.**
///
/// The permission is requested when `PlaceSheet` opens and nowhere else, because that is the only
/// moment the app has a use for it: listing the rooms around you so you can tap one. Design rule 8
/// still holds with no asterisk — **nothing is ever attached from a location**. A place gets onto an
/// entry because it was named or tapped, and a refused permission costs exactly one section.
@MainActor
final class AteLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocationCoordinate2D?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Asks if it has never been asked, then answers with a coordinate or `nil`. `nil` is not an
    /// error — it is a Nearby section that simply is not there.
    func current() async -> CLLocationCoordinate2D? {
        #if DEBUG
        // A preview-data run answers from the middle of the launch market and asks nobody: the
        // simulator's permission alert is not part of what `PlaceSheet.dc.html` draws.
        if ProcessInfo.processInfo.arguments.contains("-ate-preview-data") {
            return CLLocationCoordinate2D(latitude: -37.8118, longitude: 144.9629)
        }
        #endif
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            guard await authorized() else { return nil }
        default:
            break
        }
        if let known = manager.location?.coordinate { return known }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            manager.requestLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    private var authorization: [CheckedContinuation<Bool, Never>] = []

    private func authorized() async -> Bool {
        await withCheckedContinuation { continuation in
            authorization.append(continuation)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            let pending = authorization
            authorization = []
            let isAllowed = status == .authorizedWhenInUse || status == .authorizedAlways
            pending.forEach { $0.resume(returning: isAllowed) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in resume(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in resume(nil) }
    }

    private func resume(_ coordinate: CLLocationCoordinate2D?) {
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume(returning: coordinate) }
    }
}
