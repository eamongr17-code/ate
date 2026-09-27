import XCTest

/// **Round 5, the Feed's location — driven.** Near me, a pick from the sheet, and back to Near me.
/// Against staging (`-ate-debug-signin`): the cities and "near me" are the live `feed_cities` /
/// `resolve_city`, and nothing here writes a row. Paced for a simulator recording.
///
/// Independent of the simulator (main, 2026-09-28: it failed on a sim with no location set, a
/// permission already answered, and an account whose last choice was a city): the device is put in
/// Melbourne and the permission reset before launch, the question is answered when it comes, and
/// the drive starts by choosing Near me rather than assuming it.
final class FeedLocationUITests: XCTestCase {

    func testPickEverywhereAndBackToNearMe() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-ui-testing", "-ate-debug-signin", "-ate-open-feed"]
        placeTheDevice(for: app)
        app.launch()
        // The account's last choice may already be Near me: then the Feed asks as it opens.
        allowLocationIfAsked(timeout: 4)

        let control = app.buttons["feed.area"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        pickNearMe(app, control)
        pause(1.2)

        control.tap()
        let everywhere = app.cityPill("@everywhere")
        XCTAssertTrue(everywhere.waitForExistence(timeout: 5))
        pause(1.0)
        everywhere.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (control.value as? String) == "Everywhere" })
        pause(1.5)

        pickNearMe(app, control)
        pause(1.5)
    }

    /// Near me from the sheet — answering the location question if this is the first ask — and the
    /// chip saying so: in Melbourne, "Near me, Melbourne".
    private func pickNearMe(_ app: XCUIApplication, _ control: XCUIElement, line: UInt = #line) {
        control.tap()
        let nearMe = app.cityPill("@near-me")
        XCTAssertTrue(nearMe.waitForExistence(timeout: 5), line: line)
        pause(1.0)
        nearMe.tap()
        allowLocationIfAsked(timeout: 4)
        XCTAssertTrue(waitUntil(timeout: 15) { (control.value as? String) == "Near me, Melbourne" },
                      "near me, and the city the device is in (it reads \(String(describing: control.value)))",
                      line: line)
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
