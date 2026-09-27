import XCTest

/// **Round 4, browse — driven.** What only a drive can see: the entry page drawing from the card it
/// was opened with (no blank paper), the swipe back — finished and cancelled — bringing the tab bar
/// with it, and the one filter sheet on the Journal and on Search.
///
/// Against `-ate-preview-data` (with `-ate-preview-journal`'s longer journal), so it needs no backend
/// and writes nothing. The drives are paced for simulator recordings; with `BROWSE_SHOT_DIR` set they
/// also drop stills there.
final class BrowseRound4UITests: XCTestCase {

    // MARK: - The entry page and the swipe back

    /// A journal slip opens its entry already drawn — the card came with it — and a swipe back,
    /// cancelled and then finished, leaves the tab bar where it belongs.
    func testEntryOpensDrawnAndSwipesBack() {
        let app = launch([])
        let body = app.buttons.matching(identifier: "journal.slip.body").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.tap()
        XCTAssertTrue(app.otherElements["entry.dishes"].waitForExistence(timeout: 1.5),
                      "the page is drawn from the card in hand, not after a read")
        XCTAssertFalse(app.otherElements["entry.skeleton"].exists, "and never shows its skeleton")
        save("entry-seeded")
        pause(0.8)

        // Halfway, held, let go: the pop cancels and the entry stays.
        edgeSwipe(app, to: 0.35, velocity: .slow, hold: 0.8)
        pause(0.8)
        XCTAssertTrue(app.otherElements["entry.dishes"].exists, "a cancelled swipe keeps the page")
        XCTAssertFalse(tabBarIsUp(app), "and the tab bar stays hidden under it")

        // All the way: back on the journal, the bar with it.
        edgeSwipe(app, to: 0.95, velocity: .default, hold: 0)
        XCTAssertTrue(waitUntil(timeout: 3) { tabBarIsUp(app) }, "the journal's tab bar is back")
        save("entry-swiped-back")
        pause(0.6)
    }

    /// An entry opened by id alone — the debug drive's — is its skeleton until the read answers,
    /// then the page.
    func testEntryOpenedByIDFillsIn() {
        let app = launch(["-ate-open-entry"])
        XCTAssertTrue(app.otherElements["entry.dishes"].waitForExistence(timeout: 10))
        save("entry-by-id")
    }

    // MARK: - The one filter sheet

    /// The Journal: the control beside the segment, the sheet, and the pills it leaves.
    func testJournalFilterSheet() {
        let app = launch([])
        let control = app.buttons["journal.filter"]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        pause(0.6)
        control.tap()
        XCTAssertTrue(app.buttons["Top rated"].waitForExistence(timeout: 5))
        pause(0.6)
        app.buttons["Top rated"].tap()
        pause(0.4)
        app.buttons["4.0+"].firstMatch.tap()
        pause(0.6)
        save("journal-filter-sheet")
        app.buttons["sheet.primary"].tap()
        let pill = app.buttons["Remove 4.0+"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the filter shows as a removable pill")
        pause(1.0)
        save("journal-filter-applied")
        pill.tap()
        pause(0.8)
        app.buttons["Remove Top rated"].tap()
        pause(0.8)
        scrollForMonthMarker(app, name: "journal-month-marker")
    }

    /// Search: the same control at the end of the scopes, the same sheet with Search's sections, the
    /// same pills.
    func testSearchFilterSheet() {
        let app = launch(["-ate-open-search", "-ate-search-scope", "dishes", "-ate-search-query", "ra"])
        let control = app.buttons["search.filter"]
        XCTAssertTrue(control.waitForExistence(timeout: 10), "the filter control sits with the scopes")
        pause(0.8)
        save("search-filter-closed")
        control.tap()
        XCTAssertTrue(app.buttons["4.0+"].firstMatch.waitForExistence(timeout: 5))
        pause(0.6)
        app.buttons["4.0+"].firstMatch.tap()
        pause(0.4)
        app.buttons["vegetarian"].firstMatch.tap()
        pause(0.6)
        save("search-filter-sheet")
        app.buttons["sheet.primary"].tap()
        XCTAssertTrue(app.buttons["Remove 4.0+"].waitForExistence(timeout: 5), "the same removable pills")
        XCTAssertTrue(app.buttons["Remove V"].exists)
        pause(1.0)
        save("search-filter-applied")
        app.buttons["Remove V"].tap()
        pause(0.8)
        XCTAssertFalse(app.buttons["Remove V"].exists, "a pill takes its filter away")
        save("search-filter-removed")
    }

    private func scrollForMonthMarker(_ app: XCUIApplication, name: String) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
                    withVelocity: .slow, thenHoldForDuration: 0.4)
        pause(1.0)
        // A fling: the list is still moving when the still is taken, so the marker is up.
        app.swipeUp(velocity: .fast)
        save(name)
        pause(1.5)
    }

    // MARK: - Machinery

    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-preview-journal", "-ate-ui-testing"] + arguments
        app.launch()
        return app
    }

    /// The journal tab's button is on screen and reachable — the bar is up.
    private func tabBarIsUp(_ app: XCUIApplication) -> Bool {
        let journal = app.buttons["Journal"].firstMatch
        return journal.exists && journal.isHittable && journal.frame.minY > app.frame.height * 0.8
    }

    private func edgeSwipe(
        _ app: XCUIApplication, to fraction: CGFloat, velocity: XCUIGestureVelocity, hold: TimeInterval
    ) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: hold)
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

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["BROWSE_SHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
