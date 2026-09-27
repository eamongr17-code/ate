import XCTest

/// **Round 5, the Feed's location — driven.** Near me by default, a pick from the sheet, and back to
/// Near me. Against staging (`-ate-debug-signin`): the cities and "near me" are the live
/// `feed_cities` / `resolve_city`, and nothing here writes a row. `FEED_VARIANT` (A|B) picks the
/// exploration's layout; paced for a simulator recording.
final class FeedLocationUITests: XCTestCase {

    func testPickEverywhereAndBackToNearMe() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let variant = ProcessInfo.processInfo.environment["FEED_VARIANT"] ?? "A"
        app.launchArguments = ["-ate-ui-testing", "-ate-debug-signin", "-ate-open-feed", "-ate-r5-feed-location", variant]
        app.launch()

        let control = app.buttons["feed.area"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 10) { (control.value as? String)?.hasPrefix("Near me") == true },
                      "the Feed opens on near me, with the city it resolved to")
        pause(1.2)

        control.tap()
        let everywhere = app.buttons["row.Everywhere"].firstMatch
        XCTAssertTrue(everywhere.waitForExistence(timeout: 5))
        pause(1.0)
        everywhere.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (control.value as? String) == "Everywhere" })
        pause(1.5)

        control.tap()
        let nearMe = app.buttons["row.Near me"].firstMatch
        XCTAssertTrue(nearMe.waitForExistence(timeout: 5))
        pause(1.0)
        nearMe.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (control.value as? String)?.hasPrefix("Near me") == true },
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
