import AteKit
import CoreLocation

/// **Where the phone last was — without asking.** Dish suggestions come from around you (0080), so
/// their reads carry the system's last fix when the app already has permission and one. It never
/// raises the permission alert and never starts updates: no fix is `nil`, and the server falls back
/// to the dish's place, or where you last ate. The point is sent with that read and kept nowhere.
@MainActor
enum AteLastFix {
    private static let manager = CLLocationManager()

    static func point() -> SuggestionPoint? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            guard let coordinate = manager.location?.coordinate,
                  CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return SuggestionPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
        default:
            return nil
        }
    }
}
