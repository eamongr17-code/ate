import XCTest

/// **The tab bar, driven.** The system's own bar with compose borrowed into the search role's glass
/// circle — so the two things only a drive can see: that `+` presents the composer and hands the bar
/// back to the tab you were on, and that re-tapping the current tab still brings its page to the top.
///
/// Against `-ate-preview-data`, so it needs no backend and writes nothing. With
/// `TEST_RUNNER_TABBAR_SHOT_DIR` set it also drops PNGs there for a side-by-side.
final class TabBarUITests: XCTestCase {

    /// `+` presents the composer, and closing it leaves the tab you were on selected — the borrowed
    /// search slot must never become the selection.
    func testComposeTapPresentsAndReturns() {
        let app = launch(["-ate-open-feed"])
        let compose = app.buttons["New entry"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "the compose circle is beside the bar")
        compose.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "+ presents the composer")
        save("tabbar-composer")
        close.tap()
        let feed = app.buttons["Feed"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 5) { feed.isSelected }, "the Feed is still the tab")
        XCTAssertTrue(app.staticTexts["Feed"].firstMatch.exists, "and still on screen, not a blank slot")
    }

    /// Scrolled down, the bar minimises; tapping the current tab brings the page back to its top.
    func testRetapScrollsToTop() {
        let app = launch(["-ate-open-feed"])
        let title = app.staticTexts["Feed"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { title.isHittable == false }, "the header has scrolled away")
        save("tabbar-minimized")
        let tab = app.buttons["Feed"].firstMatch
        tab.tap()
        if waitUntil(timeout: 2, { title.isHittable }) == false {
            // The first tap on a minimised bar only expands it.
            tab.tap()
        }
        XCTAssertTrue(waitUntil(timeout: 3) { title.isHittable }, "re-tapping the tab scrolls to the top")
        save("tabbar-retap")
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
