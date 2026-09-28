import XCTest

/// **The Journal's chips and calendar — driven** (round 7). What only a drive can see: a chip's sheet
/// narrowing the list and its ✕ taking it off; the calendar button and a pinch zooming out to the
/// month and the year and back; a day on the calendar bringing the list back at that day.
///
/// Against `-ate-preview-data` with the `journal` fixture's longer journal, so it needs no backend
/// and writes nothing. With `BROWSE_SHOT_DIR` set the drives drop stills there (`ATE_DARK=1` for the
/// dark ones).
final class JournalCalendarUITests: XCTestCase {

    // MARK: - A chip

    /// Rating: the sheet, a preset, the live count, Show — the chip goes ink with its value, the
    /// compact header carries it mid-list, and its ✕ takes it off.
    func testRatingChipSheetNarrowsAndClears() {
        let app = launch([])
        let chip = app.buttons["journal.chip.rating"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        save("main")
        chip.tap()
        let preset = app.buttons["chipsheet.preset.fourPlus"]
        XCTAssertTrue(preset.waitForExistence(timeout: 5), "the Rating sheet is up")
        preset.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { app.staticTexts["chipsheet.value"].label == "4.0 and up" })
        let show = app.buttons["chipsheet.show"]
        XCTAssertTrue(waitUntil(timeout: 3) { show.label.hasPrefix("Show ") && show.label.contains(where: \.isNumber) },
                      "the pill counts the entries")
        pause(0.6)
        save("rating-sheet")
        show.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { chip.label == "4.0+" }, "the chip says its value")

        // Down the list and a little back up: the compact header, the month, the chip that is on.
        app.swipeUp(velocity: .default)
        pause(0.8)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let compact = app.buttons["journal.compact.chip.rating"]
        XCTAssertTrue(compact.waitForExistence(timeout: 3), "the compact header carries the chip")
        pause(0.8)
        save("journal-scrolled")

        app.buttons["journal.compact.chip.rating.clear"].firstMatch.tap()
        app.buttons["Journal"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { chip.exists && chip.label == "Rating" }, "the ✕ took it off")
    }

    // MARK: - The calendar

    /// The button opens the month; the segment the year; fingers apart come back to the month, and
    /// the back disc to the list.
    func testCalendarButtonAndPinches() {
        let app = launch([])
        let button = app.buttons["journal.calendar"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(anyDay(app).waitForExistence(timeout: 5), "the month's days are up")
        pause(0.8)
        save("calendar-month")

        app.buttons["calendar.level.year"].firstMatch.tap()
        XCTAssertTrue(app.buttons["calendar.month.1"].firstMatch.waitForExistence(timeout: 3), "the year's months")
        pause(0.8)
        save("calendar-year")

        app.descendants(matching: .any)["calendar"].firstMatch.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(anyDay(app).waitForExistence(timeout: 3), "fingers apart: back to the month")
        app.buttons["calendar.back"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { button.isHittable }, "back on the list")

        // Fingers together on the list: the month; again: the year.
        app.descendants(matching: .any)["journal.slip"].firstMatch.pinch(withScale: 0.4, velocity: -2)
        XCTAssertTrue(anyDay(app).waitForExistence(timeout: 3), "a pinch zooms out to the month")
        app.descendants(matching: .any)["calendar"].firstMatch.pinch(withScale: 0.4, velocity: -2)
        XCTAssertTrue(app.buttons["calendar.month.1"].firstMatch.waitForExistence(timeout: 3),
                      "and again to the year")
    }

    /// A day in an earlier month — off the first page of the list — brings the list back at it.
    func testADayOpensTheListAtIt() {
        let app = launch([])
        let button = app.buttons["journal.calendar"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        app.buttons["calendar.level.year"].firstMatch.tap()
        let may = app.buttons["calendar.month.5"].firstMatch
        XCTAssertTrue(may.waitForExistence(timeout: 3))
        may.tap()
        let day = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.day.2026-05")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 3), "May has a day with an entry")
        day.tap()
        let divider = app.descendants(matching: .any)["journal.month.2026-5"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 5) { divider.exists && divider.isHittable }, "the list is at May")
        XCTAssertLessThan(divider.frame.minY, app.frame.height / 3, "May is at the top of the screen")
        pause(0.6)
        save("calendar-day-landed")
    }

    /// Stills only: the one top frost over a pushed page (a place), scrolled.
    func testTopFrostOnAPushedPage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BROWSE_SHOT_DIR"] != nil, "stills only")
        let app = launch(["-ate-open", "place/b7e00000-0000-4000-8000-000000000001"])
        XCTAssertTrue(app.buttons["nav.back"].firstMatch.waitForExistence(timeout: 10))
        pause(1.2)
        save("pushed-rest")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)),
                    withVelocity: .slow, thenHoldForDuration: 0.4)
        pause(0.6)
        save("pushed-scrolled")
    }

    // MARK: - Machinery

    private func anyDay(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.day.")).firstMatch
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-fixture", "journal", "-ate-ui-testing"] + arguments
        if isDark { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
        app.launch()
        return app
    }

    private var isDark: Bool { ProcessInfo.processInfo.environment["ATE_DARK"] == "1" }

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
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(isDark ? "dark" : "light").png")
        try? shot.pngRepresentation.write(to: url)
    }
}
