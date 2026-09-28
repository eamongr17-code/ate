import XCTest

/// **Filters with nothing typed** (QA on #84): the lists Search shows before a character is typed —
/// Nearby, and the Saved shelf — are narrowed by the filter too, never a pill sitting over the
/// unfiltered rows.
///
/// Against staging (`-ate-debug-signin`): Nearby is the live `nearby_places`, and the shelf is the
/// demo account's own. Reads only; nothing here writes a row.
final class SearchStandingFilterUITests: XCTestCase {

    func testNearbyNarrowsWithAnEmptyField() {
        let app = launch(scope: "places")
        let rows = app.buttons.matching(identifier: "search.place")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "Nearby is up before typing")
        let before = rows.count
        filter(app, from: 4.5)
        XCTAssertTrue(waitUntil(timeout: 8) { rows.count < before }, "Nearby was read again, narrowed")
        XCTAssertTrue(app.buttons["Remove 4.5+"].exists, "under the pill that says so")
    }

    func testSavedNarrowsWithAnEmptyField() {
        let app = launch(scope: "saved")
        let rows = app.buttons.matching(identifier: "saved.dish")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "the shelf is up before typing")
        let before = rows.count
        filter(app, from: 5)
        XCTAssertTrue(waitUntil(timeout: 8) { rows.count < before }, "the shelf was read again, narrowed")
        XCTAssertTrue(app.buttons["Remove 5.0+"].exists)
    }

    // MARK: - Machinery

    private func launch(scope: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-ui-testing", "-ate-debug-signin", "-ate-open", "search/\(scope)"]
        // Nearby is ranked by where the device is: put it in Melbourne, and answer the question
        // when Places asks it — never whatever the simulator last held (main, 2026-09-28).
        placeTheDevice(for: app)
        app.launch()
        allowLocationIfAsked(timeout: 8)
        // No `q=`: the field is empty throughout.
        return app
    }

    private func filter(_ app: XCUIApplication, from score: Double) {
        app.buttons["search.filter"].firstMatch.tap()
        app.raiseLowestScore(to: score)
        app.buttons["sheet.primary"].tap()
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
