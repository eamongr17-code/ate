import XCTest

/// **Every bottom sheet, sized to what it holds** — no X, the grabber and a swipe down to dismiss,
/// and no big empty area under the last row. Photographs each one for the side-by-side, and swipes
/// one away to prove the gesture is the way out.
///
/// Against `-ate-preview-data`, so it writes nothing. `TABBAR_SHOT_DIR` collects the PNGs.
final class SheetFitUITests: XCTestCase {

    private var app: XCUIApplication!

    func testEntrySheetsFitAndSwipeAway() {
        launch(["-ate-open", "entry/a7e00000-0000-4000-8000-000000000142?sheet=place"])
        let add = app.buttons["place.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the place sheet is up")
        sleep(2)
        save("sheet-place")
        XCTAssertFalse(app.buttons["Close"].exists, "no X on a sheet")
        add.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        save("sheet-add-place")
        dismissSheet()
        sleep(1)
        dismissSheet()
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["place.add"].exists == false }, "a swipe down dismisses")
        save("sheet-dismissed")
    }

    func testDishSheetFits() {
        launch(["-ate-open", "entry/a7e00000-0000-4000-8000-000000000142?sheet=dish"])
        XCTAssertTrue(app.buttons["sheet.primary"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        save("sheet-dish")
        XCTAssertFalse(app.buttons["Close"].exists, "no X on a sheet")
    }

    func testFeedAreaAndActionsSheetsFit() {
        launch(["-ate-open", "feed"])
        let area = app.buttons["feed.area"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 10))
        area.tap()
        sleep(2)
        save("sheet-area")
        XCTAssertFalse(app.buttons["Close"].exists, "no X on a sheet")
        dismissSheet()
        sleep(1)
        app.scrollToFeedSlip().tap()
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        sleep(2)
        save("sheet-actions")
        XCTAssertFalse(app.buttons["Close"].exists, "no X on a sheet")
    }

    private func dismissSheet() {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let grabber = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
        _ = top
        // From just under the sheet's top edge — found by the title row — straight down.
        let start = sheetTop().withOffset(CGVector(dx: 0, dy: 12))
        start.press(forDuration: 0.05, thenDragTo: grabber.withOffset(CGVector(dx: 0, dy: 900)),
                    withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// The top of the frontmost sheet: its title is the first header on screen.
    private func sheetTop() -> XCUICoordinate {
        let header = app.staticTexts.matching(NSPredicate(format: "label IN %@", [
            "Where was this?", "Which dish?", "New place", "Which area?"
        ])).firstMatch
        if header.exists {
            return header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: -30))
        }
        return app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    private func launch(_ arguments: [String]) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = app.wait(for: .runningForeground, timeout: 0.1)
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
