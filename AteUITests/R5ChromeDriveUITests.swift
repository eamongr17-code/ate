import XCTest

/// Exploration drive for the round-5 chrome variants (not a test; skipped unless `R5_TAG` is set).
/// `R5_ARGS` carries the variant launch arguments, `R5_SHOTS` the directory stills land in.
final class R5ChromeDriveUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testDriveScroll() throws {
        try XCTSkipIf(env["R5_TAG"] == nil)
        launch(["-ate-open-feed"])
        XCTAssertTrue(app.buttons["feed.area"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        save("rest")
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        // Down: header away, bar minimises.
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -300)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
        save("down")
        // Up, mid-list: header back, bar expands.
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 120)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
        save("up")
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -200)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
        // The minimised bar, tapped open.
        let disc = app.buttons["tabbar.minimised"].firstMatch
        if disc.exists { disc.tap() }
        sleep(2)
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -200)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 120)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
    }

    func testDriveJournalTop() throws {
        try XCTSkipIf(env["R5_TAG"] == nil)
        launch([])
        XCTAssertTrue(app.buttons["journal.suggestions"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        save("journal-rest")
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -250)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
        save("journal-down")
    }

    func testDrivePushed() throws {
        try XCTSkipIf(env["R5_TAG"] == nil)
        launch(["-ate-open-entry"])
        sleep(4)
        save("entry-rest")
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -220)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        save("entry-scrolled")
    }

    func testDrivePlus() throws {
        try XCTSkipIf(env["R5_TAG"] == nil)
        launch([])
        XCTAssertTrue(app.buttons["journal.suggestions"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        for _ in 0..<4 {
            app.buttons["New entry"].firstMatch.tap()
            XCTAssertTrue(app.textViews["composer.editor"].waitForExistence(timeout: 5))
            sleep(1)
            app.buttons["Close"].firstMatch.tap()
            sleep(2)
        }
    }

    func testDriveTabs() throws {
        try XCTSkipIf(env["R5_TAG"] == nil)
        launch([])
        XCTAssertTrue(app.buttons["journal.suggestions"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        save("tabs-journal")
        for name in ["Feed", "Search", "You"] {
            app.buttons["tabbar.\(name.lowercased())"].firstMatch.tap()
            sleep(2)
            save("tabs-\(name)")
        }
        app.buttons["Journal"].firstMatch.tap()
        sleep(1)
    }

    private func launch(_ arguments: [String]) {
        continueAfterFailure = true
        app = XCUIApplication()
        let extra = (env["R5_ARGS"] ?? "").split(separator: " ").map(String.init)
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments + extra
        app.launch()
    }

    private func save(_ name: String) {
        guard let directory = env["R5_SHOTS"], let tag = env["R5_TAG"] else { return }
        let shot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(tag)-\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
