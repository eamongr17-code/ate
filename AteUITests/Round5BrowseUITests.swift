import XCTest

/// **Round 5, browse — driven.** The one bar on the Journal and its filter shared with Saved; the
/// Search scopes that never move; the header at the largest type; the launch moment handing over.
///
/// Against `-ate-preview-data`, so it needs no backend and writes nothing.
final class Round5BrowseUITests: XCTestCase {

    /// A range and a city set on the Journal are still on when Saved is chosen — the order is the
    /// Journal's alone — and the filter control is in the same place on both shelves.
    func testSavedShelfSharesTheFilter() {
        let app = launch(["-ate-preview-journal"])
        let control = app.buttons["journal.filter"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        let resting = control.frame

        control.tap()
        XCTAssertTrue(app.buttons["Top rated"].waitForExistence(timeout: 5))
        app.buttons["Top rated"].tap()
        app.raiseLowestScore(to: 4)
        app.buttons["sheet.primary"].tap()
        XCTAssertTrue(app.buttons["Remove 4.0+"].waitForExistence(timeout: 5))

        app.buttons["journal.shelf.saved"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["Remove 4.0+"].exists }, "the range carries over")
        XCTAssertFalse(app.buttons["Remove Top rated"].exists, "the order does not — Saved has none")
        XCTAssertEqual(control.frame.minX, resting.minX, accuracy: 1, "the control has not moved")
        XCTAssertEqual(control.frame.minY, resting.minY, accuracy: 1)

        control.tap()
        XCTAssertTrue(app.scoreRuler.waitForExistence(timeout: 5), "the same sheet on Saved")
        XCTAssertFalse(app.buttons["Top rated"].exists, "without the order")
        XCTAssertEqual(app.scoreRangeValue, "4.0+", "on the range the Journal set")
        app.buttons["sheet.primary"].tap()

        // Taken off on Saved, it is off on the Journal too.
        app.buttons["Remove 4.0+"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["Remove 4.0+"].exists == false })
        app.buttons["journal.shelf.journal"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Remove Top rated"].waitForExistence(timeout: 5), "the order stays on the Journal")
        XCTAssertFalse(app.buttons["Remove 4.0+"].exists, "the range is off on both")
    }

    /// The scopes are one segment and the filter sits at its end: choosing a scope moves nothing, and
    /// on People — which no filter narrows — the control stays put and does nothing.
    func testSearchScopesHoldStill() {
        let app = launch(["-ate-open-search", "-ate-search-scope", "places"])
        let control = app.buttons["search.filter"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10), "the scopes and the filter show before typing")
        let places = app.buttons["search.scope.places"].firstMatch
        let resting = (control.frame, places.frame)

        for scope in ["dishes", "people", "saved", "places"] {
            app.buttons["search.scope.\(scope)"].firstMatch.tap()
            XCTAssertEqual(control.frame, resting.0, "the filter holds still on \(scope)")
            XCTAssertEqual(places.frame, resting.1, "and so do the scopes")
        }

        app.buttons["search.scope.people"].firstMatch.tap()
        control.tap()
        XCTAssertFalse(app.scoreRuler.waitForExistence(timeout: 1.5), "People takes no filter")
        app.buttons["search.scope.saved"].firstMatch.tap()
        control.tap()
        XCTAssertTrue(app.scoreRuler.waitForExistence(timeout: 5), "Saved does")
    }

    /// At the largest type the one bar wraps: the logo and the two controls, then the segment across
    /// the width — everything still there and reachable.
    func testJournalHeaderAtTheLargestType() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let control = app.buttons["journal.filter"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        let saved = app.buttons["journal.shelf.saved"].firstMatch
        let suggestions = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(control.isHittable && saved.isHittable && suggestions.isHittable)
        XCTAssertGreaterThan(saved.frame.minY, control.frame.maxY - 1, "the segment wraps under the controls")
        XCTAssertLessThanOrEqual(suggestions.frame.maxX, app.frame.width, "nothing runs off the screen")
    }

    /// Without `-ate-ui-testing` the app opens on the coral moment, which hands over to the Journal
    /// in about a second — and nothing on it can be tapped by accident meanwhile.
    func testLaunchMomentHandsOver() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data"]
        app.launch()
        let control = app.buttons["journal.filter"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 4) { control.isHittable }, "the Journal is there once the moment is over")
    }

    // MARK: - Machinery

    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
        return app
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
