import XCTest

/// **The rebuilt Journal's calendar, driven** (build 87, note 2): the calendar icon opens one
/// vertical list of months and closes it again in one tap; a day zooms back in to the list.
///
/// Against `-ate-preview-data -ate-v2` with the `journal` fixture, so it needs no backend and writes
/// nothing. With `V2_SHOT_DIR` set the drive drops stills there (`ATE_DARK=1` for the dark ones).
final class V2JournalCalendarUITests: XCTestCase {

    func testCalendarTogglesScrollsVerticallyAndOpensADay() {
        let app = launch()
        let button = app.buttons["journal.calendar"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))

        // One tap: the months, opening on this month at the foot of the list.
        button.tap()
        let october = app.staticTexts["October"].firstMatch
        XCTAssertTrue(october.waitForExistence(timeout: 5), "the months are up")
        pause(1.4)
        save("calendar-month")

        // Up through the months: earlier ones come down from the top, with their written days.
        app.swipeDown(velocity: .slow)
        XCTAssertTrue(anyDay(app).waitForExistence(timeout: 5), "an earlier month's days")
        pause(1.4)
        save("calendar-scrolled-up")
        app.swipeDown(velocity: .default)
        pause(1.4)
        save("calendar-scrolled-further")

        // One tap back: the list.
        button.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { anyDay(app).exists == false }, "one tap closes the calendar")
        pause(1.4)
        save("list-after-toggle")

        // Open again, up a month, and tap a day: the list, at that day.
        button.tap()
        XCTAssertTrue(october.waitForExistence(timeout: 5))
        app.swipeDown(velocity: .slow)
        XCTAssertTrue(anyDay(app).waitForExistence(timeout: 5))
        let days = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.day."))
        let day = days.allElementsBoundByIndex.last { $0.isHittable } ?? anyDay(app)
        day.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { anyDay(app).exists == false }, "a day zooms back in to the list")
        pause(1.0)
        save("day-opened")

        // Open again: on the month the list was showing (September). Pinch out: the years.
        button.tap()
        XCTAssertTrue(app.staticTexts["September"].firstMatch.waitForExistence(timeout: 5))
        pause(1.4)
        save("calendar-reopened-on-list-month")
        XCTAssertTrue(october.waitForExistence(timeout: 5))
        october.pinch(withScale: 0.4, velocity: -2)
        XCTAssertTrue(app.buttons["calendar.month.1"].firstMatch.waitForExistence(timeout: 3), "pinch out: the years")
        pause(0.8)
        pause(0.6)
        save("calendar-year")
        // Fingers apart: back to the month list; together again: the years.
        app.windows.firstMatch.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["calendar.month.1"].exists == false },
                      "pinch in: the months")
        pause(1.4)
        save("calendar-pinched-in")
        XCTAssertTrue(october.waitForExistence(timeout: 3))
        october.pinch(withScale: 0.4, velocity: -2)
        XCTAssertTrue(app.buttons["calendar.month.1"].firstMatch.waitForExistence(timeout: 3))
        button.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["calendar.month.1"].exists == false },
                      "from the year, one tap is the list")
    }

    // MARK: - Helpers

    private var isDark: Bool { ProcessInfo.processInfo.environment["ATE_DARK"] == "1" }

    private func anyDay(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar.day.")).firstMatch
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-fixture", "journal", "-ate-ui-testing", "-ate-v2"]
        if isDark { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
        app.launch()
        return app
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
        guard let directory = ProcessInfo.processInfo.environment["V2_SHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("B-\(name)-\(isDark ? "dark" : "light").png")
        try? shot.pngRepresentation.write(to: url)
    }
}
