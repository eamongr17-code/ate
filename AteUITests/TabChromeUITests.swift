import XCTest

/// **The shell's chrome, driven** — the things only a drive can see: a tab root keeps its top safe
/// area through rapid tab switching and re-taps, its header gets out of the way on the way down and
/// comes back on the way up (with the bar), and no page pushed from a tab shows the bar.
///
/// Against `-ate-preview-data`, so it needs no backend and writes nothing. With `TABBAR_SHOT_DIR`
/// set it also drops PNGs there for a side-by-side.
final class TabChromeUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Round 4's bug: a re-tap scrolled the Journal's *segment* to the top of the visible area, which
    /// put the logo under the status bar — and the counter was shared, so re-tapping any tab did it
    /// to the Journal behind. Rapid switching, re-taps included, leaves the header where it started.
    func testRapidSwitchingAndRetapsKeepTheHeaderBelowTheStatusBar() {
        launch()
        let button = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let home = button.frame.minY
        XCTAssertGreaterThan(home, 50, "the header starts below the status bar")
        let taps = ["Journal", "Feed", "Feed", "Journal", "Journal", "You", "You", "Journal",
                    "Search", "Journal", "Feed", "Journal"]
        for _ in 0..<2 {
            for name in taps { tap(name) }
        }
        sleep(1)
        save("chrome-journal-after-switching")
        XCTAssertEqual(button.frame.minY, home, accuracy: 0.5, "the header keeps its place under the status bar")
        tap("Feed")
        sleep(1)
        let area = app.buttons["feed.area"].firstMatch
        XCTAssertGreaterThan(area.frame.minY, 50, "the Feed's header is below the status bar too")
        save("chrome-feed-after-switching")
    }

    /// Down: the header slides away and the bar minimises. Up, from the middle of the list: both are
    /// straight back — the whole bar, not just the minimised pill.
    func testHeaderAndBarHideOnScrollDownAndReturnOnScrollUp() {
        launch(["-ate-open-feed"])
        let area = app.buttons["feed.area"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 10))
        let home = area.frame.minY
        // The header in the list, and the copy that floats back over it: whichever is on screen.
        let areas = app.buttons.matching(identifier: "feed.area")
        func onScreen() -> XCUIElement? { areas.allElementsBoundByIndex.first { $0.isHittable } }
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { onScreen() == nil }, "the header slides away")
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["Search"].exists == false }, "the bar minimises")
        save("chrome-feed-scrolled-down")
        // A short drag down: nowhere near the top of the list.
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 120)))
        XCTAssertTrue(waitUntil(timeout: 2) { onScreen() != nil }, "the header is back on the way up")
        XCTAssertEqual(onScreen()?.frame.minY ?? 0, home, accuracy: 0.5, "pinned where it rests at the top")
        XCTAssertTrue(waitUntil(timeout: 2) { app.buttons["Search"].isHittable }, "and the bar is whole again")
        save("chrome-feed-scrolled-up")
    }

    /// Every page a tab pushes hides the bar — Ratings and Suggestions included — and a swipe back
    /// brings it back with the page, not half a second after it.
    func testEveryPushedPageHidesTheTabBar() {
        launch()
        let suggestions = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(suggestions.waitForExistence(timeout: 10))

        suggestions.tap()
        assertBarHidden("Suggestions")
        swipeBack()
        assertBarBack("Suggestions")

        app.buttons.matching(identifier: "journal.slip.body").firstMatch.tap()
        XCTAssertTrue(app.otherElements["entry.dishes"].waitForExistence(timeout: 10))
        assertBarHidden("Entry")
        swipeBack()
        assertBarBack("Entry")

        tap("You")
        let ratings = app.buttons["you.ratings"].firstMatch
        if ratings.waitForExistence(timeout: 10) {
            ratings.tap()
            assertBarHidden("Ratings")
            swipeBack()
            assertBarBack("Ratings")
        }
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        assertBarHidden("Settings")
        swipeBack()
        assertBarBack("Settings")

        tap("Feed")
        app.buttons.matching(identifier: "feed.slip.body").firstMatch.tap()
        XCTAssertTrue(app.otherElements["entry.dishes"].waitForExistence(timeout: 10))
        assertBarHidden("Someone's entry")
        let byline = app.buttons["entry.byline"].firstMatch
        if byline.waitForExistence(timeout: 5) {
            byline.tap()
            sleep(1)
            assertBarHidden("Profile")
        }
    }

    /// A cancelled swipe back leaves the page and the hidden bar exactly as they were.
    func testCancelledSwipeBackKeepsTheBarHidden() {
        launch()
        let suggestions = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(suggestions.waitForExistence(timeout: 10))
        suggestions.tap()
        assertBarHidden("Suggestions")
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 60, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(1)
        assertBarHidden("Suggestions, after a cancelled swipe")
        save("chrome-cancelled-swipe")
    }

    /// The bug's own path: scrolled, then the tab re-tapped — the page goes to its true top, the logo
    /// below the status bar, not the segment at the top with the logo under the clock.
    func testRetapFromAScrolledJournalLandsTheLogoBelowTheStatusBar() {
        launch()
        let button = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let home = button.frame.minY
        app.swipeUp()
        sleep(1)
        tap("Journal")
        if waitUntil(timeout: 2, { abs(button.frame.minY - home) < 0.5 }) == false {
            tap("Journal") // the first tap on a minimised bar only expands it
        }
        XCTAssertTrue(waitUntil(timeout: 3) { abs(button.frame.minY - home) < 0.5 }, "back to the true top")
        save("chrome-journal-retap")
    }

    // MARK: - Helpers

    private func assertBarHidden(_ page: String, line: UInt = #line) {
        sleep(1)
        save("chrome-pushed-\(page)")
        XCTAssertFalse(app.buttons["Search"].firstMatch.isHittable, "\(page) hides the tab bar", line: line)
    }

    /// Back on the tab root, the bar is there the moment the pop lands — it rides the pop
    /// (`ateTabBarFollowsPop`) rather than arriving after it.
    private func assertBarBack(_ page: String, line: UInt = #line) {
        XCTAssertTrue(waitUntil(timeout: 0.35) { app.buttons["Search"].firstMatch.isHittable },
                      "the bar is back with the swipe from \(page)", line: line)
    }

    private func swipeBack() {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 330, dy: 0)),
                   withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// A tab, by name — expanding a minimised bar first (its one visible item is the current tab).
    private func tap(_ name: String) {
        let button = app.buttons[name].firstMatch
        if button.exists == false {
            let current = ["Journal", "Feed", "Search", "You"].map { app.buttons[$0].firstMatch }.first { $0.exists }
            current?.tap()
            XCTAssertTrue(button.waitForExistence(timeout: 3), "the bar expands to show \(name)")
        }
        button.tap()
    }

    private func launch(_ arguments: [String] = []) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = app.wait(for: .runningForeground, timeout: 0.05)
        }
        return condition()
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["TABBAR_SHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
