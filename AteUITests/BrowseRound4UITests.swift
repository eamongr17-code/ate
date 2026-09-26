import XCTest

/// **Round 4, browse — driven.** What only a drive can see: the entry page drawing from the card it
/// was opened with (no blank paper), the swipe back — finished and cancelled — bringing the tab bar
/// with it, the photo preview's three options, and the journal filter's two entry points.
///
/// Against `-ate-preview-data` (with `-ate-preview-journal`'s longer journal), so it needs no backend
/// and writes nothing. The exploration drives are paced for the simulator recordings Eamon picks
/// from; with `BROWSE_SHOT_DIR` set they also drop stills there.
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

    // MARK: - Photo preview

    func testPhotoPreviewA() { drivePhotoPreview("A") }
    func testPhotoPreviewB() { drivePhotoPreview("B") }
    func testPhotoPreviewC() { drivePhotoPreview("C") }

    private func drivePhotoPreview(_ variant: String) {
        let app = launch(["-ate-photo-preview", variant])
        let photo = app.buttons.matching(identifier: "photo.0").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        pause(0.6)
        photo.tap()
        pause(1.0)
        save("photo-\(variant)-open")
        // Sideways, to the next photo, and back.
        drag(app, from: CGVector(dx: 0.8, dy: 0.45), to: CGVector(dx: 0.15, dy: 0.45))
        pause(0.9)
        save("photo-\(variant)-next")
        drag(app, from: CGVector(dx: 0.2, dy: 0.45), to: CGVector(dx: 0.85, dy: 0.45))
        pause(0.9)
        // Down, to put it back.
        drag(app, from: CGVector(dx: 0.5, dy: 0.4), to: CGVector(dx: 0.5, dy: 0.85))
        pause(1.0)
        XCTAssertTrue(waitUntil(timeout: 3) { tabBarIsUp(app) }, "the journal is back under it")
        save("photo-\(variant)-closed")
    }

    // MARK: - Journal filter

    /// A: the control beside the segment, its sheet, and the pills it leaves.
    func testJournalFilterA() {
        let app = launch(["-ate-journal-filter", "A"])
        let control = app.buttons["journal.filter"]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        save("filter-A-closed")
        pause(0.6)
        control.tap()
        XCTAssertTrue(app.buttons["Top rated"].waitForExistence(timeout: 5))
        pause(0.6)
        app.buttons["Top rated"].tap()
        pause(0.4)
        app.buttons["4.0+"].firstMatch.tap()
        pause(0.6)
        save("filter-A-sheet")
        app.buttons["sheet.primary"].tap()
        let pill = app.buttons["Remove 4.0+"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the filter shows as a removable pill")
        pause(1.0)
        save("filter-A-applied")
        pill.tap()
        pause(0.8)
        app.buttons["Remove Top rated"].tap()
        pause(0.8)
        scrollForMonthMarker(app, name: "filter-A-month")
    }

    /// B: the pill row under the segment, each pill its own menu.
    func testJournalFilterB() {
        let app = launch(["-ate-journal-filter", "B"])
        let sort = app.buttons["journal.filter.sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 10))
        save("filter-B-closed")
        pause(0.6)
        sort.tap()
        XCTAssertTrue(app.buttons["Oldest"].waitForExistence(timeout: 5))
        pause(0.5)
        app.buttons["Oldest"].tap()
        pause(0.8)
        app.buttons["journal.filter.place"].tap()
        XCTAssertTrue(app.buttons["Shira Nui"].waitForExistence(timeout: 5))
        pause(0.5)
        app.buttons["Shira Nui"].tap()
        let pill = app.buttons["Remove Shira Nui"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the answer is an ink pill with its ✕")
        pause(1.0)
        save("filter-B-applied")
        pill.tap()
        pause(0.8)
        scrollForMonthMarker(app, name: "filter-B-month")
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

    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        app.coordinate(withNormalizedOffset: from).press(
            forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: to),
            withVelocity: .fast, thenHoldForDuration: 0
        )
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
