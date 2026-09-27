import XCTest

/// **Round 5 exploration drive — Post against STAGING, on the real sorter.** Not a CI test: it skips
/// unless the runner is given `ATE_STAGING_DRIVE=1` (`TEST_RUNNER_ATE_STAGING_DRIVE=1 xcodebuild test
/// …`), because it writes a synthetic entry on staging as the demo account.
final class PostStagingDrive: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATE_STAGING_DRIVE"] == "1", "staging drive only")
        continueAfterFailure = false
        app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        app.launchArguments = ["-ate-debug-signin", "-ate-ui-testing"]
        if env["ATE_SLOW_SORT"] == "1" { app.launchArguments.append("-ate-slow-sort") }
        if env["ATE_DARK"] == "1" { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
    }

    /// Writes, waits for the early sort to answer (or not), posts, and holds on the Summary.
    func testPost() {
        app.launch()
        let plus = app.buttons["New entry"]
        XCTAssertTrue(plus.waitForExistence(timeout: 20))
        plus.tap()
        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["composer.key.place"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Tipo")
        let row = app.buttons["row.Tipo 00"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let use = app.buttons["Use Tipo 00"]
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        use.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(ProcessInfo.processInfo.environment["ATE_WORDS"]
            ?? "Pappardelle with duck ragu 4.5 so rich. Burrata 4 was creamy, tiramisu 3.5 to finish. ")
        // Warm: the early sort goes after a 1.5s pause and answers in the model's time.
        let settle = Double(ProcessInfo.processInfo.environment["ATE_SETTLE"] ?? "12") ?? 12
        Thread.sleep(forTimeInterval: settle)
        // The recording's cue: everything before this is setup.
        XCTContext.runActivity(named: "ATE-CUE") { _ in }
        Thread.sleep(forTimeInterval: 2)
        app.buttons["composer.post"].tap()
        XCTAssertTrue(app.buttons["share.done"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 15)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "summary"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
