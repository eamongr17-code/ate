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

    /// Captures one frame part-way through the header's return and the bar's expansion.
    func testDriveMidMotion() throws {
        try XCTSkipIf(env["R5_TAG"] == nil)
        launch(["-ate-open-feed"])
        XCTAssertTrue(app.buttons["feed.area"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -300)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 60)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        save("mid")
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

    func testProbe() throws {
        try XCTSkipIf(env["R5_TAG"] == nil)
        launch(["-ate-open-feed"])
        for index in 0..<24 {
            let probe = app.otherElements["r5.probe"].firstMatch
            print("R5DBG t\(index)", probe.exists ? (probe.value as? String ?? "?") : "none",
                  app.buttons["feed.area"].exists)
            if index == 12 { save("probe") }
            _ = app.wait(for: .runningForeground, timeout: 0.5)
            usleep(500_000)
        }
    }

    func testDebugSwipe() throws {
        try XCTSkipIf(env["R5_TAG"] == nil)
        launch(["-ate-open-feed"])
        XCTAssertTrue(app.buttons["feed.area"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        app.swipeUp()
        sleep(2)
        save("swipe")
        print("R5DBG state", app.otherElements["tabbar.state"].firstMatch.value as? String ?? "?")
        for button in app.buttons.matching(identifier: "tabbar.search").allElementsBoundByIndex {
            print("R5DBG search", button.frame, button.isHittable)
        }
        for button in app.buttons.matching(NSPredicate(format: "label == 'Search'")).allElementsBoundByIndex {
            print("R5DBG searchlabel", button.identifier, button.frame, button.isHittable)
        }
        for text in app.staticTexts.matching(NSPredicate(format: "label == 'Feed'")).allElementsBoundByIndex {
            print("R5DBG feedtext", text.identifier, text.frame, text.isHittable)
        }
        for element in app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tabbar.'")).allElementsBoundByIndex {
            print("R5DBG el", element.identifier, element.elementType.rawValue, element.frame, element.isHittable, element.value as? String ?? "")
        }
        print(app.debugDescription.split(separator: "\n").filter { $0.contains("Feed") || $0.contains("tabbar") }.joined(separator: "\n"))
    }

    func testDriveTabs() throws {
        try XCTSkipIf(env["R5_TAG"] == nil)
        launch([])
        XCTAssertTrue(app.buttons["journal.suggestions"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        save("tabs-journal")
        for name in ["Feed", "Search", "You"] {
            print("R5DBG before \(name):", app.buttons.matching(identifier: "tabbar.\(name.lowercased())").count,
                  app.otherElements.matching(identifier: "tabbar.state").allElementsBoundByIndex.map { $0.value as? String ?? "?" })
            app.buttons["tabbar.\(name.lowercased())"].firstMatch.tap()
            sleep(2)
            print("R5DBG after \(name):",
                  app.otherElements.matching(identifier: "tabbar.state").allElementsBoundByIndex.map { $0.value as? String ?? "?" })
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
