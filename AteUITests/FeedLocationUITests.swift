import XCTest

/// **Round 5, the Feed's location — driven.** Near me by default, a pick from the sheet, and back to
/// Near me. Against staging (`-ate-debug-signin`): the cities and "near me" are the live
/// `feed_cities` / `resolve_city`, and nothing here writes a row. Paced for a simulator recording.
final class FeedLocationUITests: XCTestCase {

    func testPickEverywhereAndBackToNearMe() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-ui-testing", "-ate-debug-signin", "-ate-open-feed"]
        app.launch()
        // Near me asks for the location the first time the Feed opens on it (never at launch).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }

        let control = app.buttons["feed.area"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        // "Near me, Melbourne" where the simulator is in a city with food; the busiest city where it
        // is not — near me either way, and never a blank.
        XCTAssertTrue(waitUntil(timeout: 10) {
            let value = (control.value as? String) ?? ""
            return value.isEmpty == false && value != "Near me"
        }, "near me is worked out")
        let nearMeValue = control.value as? String
        pause(1.2)

        control.tap()
        let everywhere = app.cityPill("@everywhere")
        XCTAssertTrue(everywhere.waitForExistence(timeout: 5))
        pause(1.0)
        everywhere.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (control.value as? String) == "Everywhere" })
        pause(1.5)

        control.tap()
        let nearMe = app.cityPill("@near-me")
        XCTAssertTrue(nearMe.waitForExistence(timeout: 5))
        pause(1.0)
        nearMe.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (control.value as? String) == nearMeValue },
                      "the choice goes back to near me")
        pause(1.5)
    }

    private func pause(_ seconds: TimeInterval) {
        _ = XCUIApplication().wait(for: .runningBackground, timeout: seconds)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCUIApplication().wait(for: .runningBackground, timeout: 0.1)
        }
        return condition()
    }
}
