import XCTest

/// Exploration drive for round 6's chrome (not a test; skipped unless `R6_TAG` is set). `R6_ARGS`
/// carries the variant launch arguments, `R6_SHOTS` the directory stills land in.
final class R6ChromeDriveUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Down (big header away, bar minimised), then up mid-list (the compact header back), on one tab.
    func testDriveFeed() throws { try drive(["-ate-open-feed"], ready: "feed.area") }
    func testDriveJournal() throws { try drive([], ready: "journal.suggestions", downDrags: 2) }
    func testDriveSearch() throws { try drive(["-ate-open-search"], ready: "search.field") }

    /// The bar at rest and minimised, for the Feed icon candidates and the minimised alignment.
    func testDriveBar() throws {
        try XCTSkipIf(env["R6_TAG"] == nil)
        launch([])
        XCTAssertTrue(app.buttons["tabbar.compose"].waitForExistence(timeout: 10))
        sleep(2)
        save("bar-rest")
        drag(-300)
        sleep(2)
        save("bar-minimised")
    }

    private func drive(_ arguments: [String], ready: String, downDrags: Int = 1) throws {
        try XCTSkipIf(env["R6_TAG"] == nil)
        launch(arguments)
        XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        save("rest")
        for _ in 0..<downDrags { drag(-320) }
        sleep(2)
        save("down")
        drag(120)
        sleep(2)
        save("compact")
        drag(-200)
        sleep(2)
        drag(140)
        sleep(2)
    }

    private func drag(_ distance: CGFloat) {
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: distance)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func launch(_ arguments: [String]) {
        continueAfterFailure = true
        app = XCUIApplication()
        let extra = (env["R6_ARGS"] ?? "").split(separator: " ").map(String.init)
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments + extra
        app.launch()
    }

    private func save(_ name: String) {
        guard let directory = env["R6_SHOTS"], let tag = env["R6_TAG"] else { return }
        let shot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(tag)-\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
