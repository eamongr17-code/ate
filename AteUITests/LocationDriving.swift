import CoreLocation
import XCTest

/// **A drive that needs the phone's location sets it up itself** — never whatever the simulator
/// happens to hold (a location nobody set, a permission a previous run answered). Round 5: the
/// Feed's Near me and Search's Nearby both depend on it.
extension XCTestCase {
    /// Melbourne's CBD — inside the one city staging has food in.
    static let melbourne = CLLocation(latitude: -37.8136, longitude: 144.9631)

    /// Before launch: the permission back to "not asked", and the device put in Melbourne. The app
    /// then asks at its own moment, and ``allowLocationIfAsked(timeout:)`` answers.
    func placeTheDevice(for app: XCUIApplication, at location: CLLocation = XCTestCase.melbourne) {
        app.resetAuthorizationStatus(for: .location)
        XCUIDevice.shared.location = XCUILocation(location: location)
    }

    /// Answers the system's location question, if it is up (or comes up within `timeout`).
    @discardableResult
    func allowLocationIfAsked(timeout: TimeInterval) -> Bool {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        guard allow.waitForExistence(timeout: timeout) else { return false }
        allow.tap()
        return true
    }
}
