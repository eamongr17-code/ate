import XCTest

/// **The tab bar, driven** (round 5: the app's own bar). What only a drive can see: `+` presents the
/// composer without ever touching the tab under it (the round-4 flash was the borrowed system slot
/// being selected for a frame), the minimised bar taps back open and minimises again on the next
/// scroll down, and re-tapping the current tab still brings its page to the top.
///
/// Against `-ate-preview-data`, so it needs no backend and writes nothing. With
/// `TEST_RUNNER_TABBAR_SHOT_DIR` set it also drops PNGs there for a side-by-side.
final class TabBarUITests: XCTestCase {

    /// `+` presents the composer, and the tab under it never changes — before, during, after.
    func testComposeTapPresentsAndReturns() {
        let app = launch(["-ate-open-feed"])
        let compose = app.buttons["tabbar.compose"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "the + is beside the bar")
        XCTAssertEqual(state(app), "expanded feed")
        compose.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "+ presents the composer")
        save("tabbar-composer")
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { state(app) == "expanded feed" }, "the Feed is still the tab")
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["feed.area"].firstMatch.isHittable },
                      "and still on screen, not a blank slot")
        XCTAssertTrue(app.buttons["tabbar.feed"].firstMatch.isSelected)
    }

    /// Scrolled down, the bar minimises to the current tab's disc; a tap brings the whole bar back,
    /// and the next scroll down minimises it again.
    func testTheMinimisedBarTapsOpenAndMinimisesAgain() {
        let app = launch(["-ate-open-feed"])
        XCTAssertTrue(app.buttons["feed.area"].firstMatch.waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { state(app) == "minimised feed" }, "the bar minimises")
        XCTAssertFalse(app.buttons["tabbar.search"].exists, "a minimised bar offers only its disc")
        save("tabbar-minimised")
        app.buttons["tabbar.minimised"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 2) { state(app) == "expanded feed" }, "a tap brings the whole bar back")
        XCTAssertTrue(app.buttons["tabbar.search"].firstMatch.isHittable)
        save("tabbar-tapped-open")
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -160)))
        XCTAssertTrue(waitUntil(timeout: 3) { state(app) == "minimised feed" }, "and the next scroll down minimises it")
    }

    /// Scrolled down, the bar minimises; opening it and tapping the current tab brings the page back
    /// to its top.
    func testRetapScrollsToTop() {
        let app = launch(["-ate-open-feed"])
        let area = app.buttons["feed.area"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 10))
        let home = area.frame.minY
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { area.isHittable == false }, "the header has scrolled away")
        app.buttons["tabbar.minimised"].firstMatch.tap()
        let tab = app.buttons["tabbar.feed"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 2))
        tab.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { area.isHittable && abs(area.frame.minY - home) < 0.5 },
                      "re-tapping the tab scrolls to the top")
        save("tabbar-retap")
    }

    /// The bar, full and minimised, passes the system's accessibility audit for hit regions and
    /// descriptions. The Debug-only `tabbar.state` probe is 1pt by design (it exists for these tests)
    /// and is excluded; the rest of the screen is other tests' business.
    func testTheBarPassesTheAccessibilityAudit() throws {
        let app = launch(["-ate-open-feed"])
        XCTAssertTrue(app.buttons["tabbar.compose"].waitForExistence(timeout: 10))
        let barOnly: (XCUIAccessibilityAuditIssue) -> Bool = { issue in
            guard let identifier = issue.element?.identifier else { return true }
            return identifier == "tabbar.state" || identifier.hasPrefix("tabbar.") == false
        }
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription], barOnly)
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { state(app) == "minimised feed" })
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription], barOnly)
    }

    private func state(_ app: XCUIApplication) -> String {
        (app.otherElements["tabbar.state"].firstMatch.value as? String) ?? "missing"
    }

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
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 0.1)
        }
        return condition()
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["TABBAR_SHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
