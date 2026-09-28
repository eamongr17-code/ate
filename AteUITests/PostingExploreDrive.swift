import XCTest

/// **Round 6 exploration drive — the Post loading state, A and B.** Not a CI test: it skips unless
/// the runner is given `ATE_R6_DRIVE=1` (`scripts/ci-sim.sh` does). Preview data and a slowed sort,
/// so "Posting…" holds its full 3.5s and nothing is written anywhere.
final class PostingExploreDrive: XCTestCase {

    func testPosting() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ATE_R6_DRIVE"] == "1", "exploration drive only")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ate-preview-data", "-ate-ui-testing", "-ate-open-composer", "-ate-seed-draft", "-ate-slow-sort",
            "-ate-r6-posting", env["ATE_VARIANT"] ?? "A"
        ]
        app.launch()
        let post = app.buttons["composer.post"]
        XCTAssertTrue(post.waitForExistence(timeout: 30))
        sleep(2)
        // The recording's cue: everything before this is setup.
        XCTContext.runActivity(named: "ATE-CUE") { _ in }
        sleep(2)
        post.tap()
        sleep(1)
        attach("posting-1")
        usleep(700_000)
        attach("posting-2")
        XCTAssertTrue(app.buttons["share.done"].waitForExistence(timeout: 10))
        let receipt = app.otherElements["summary.receipt"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 20))
        sleep(3)
        attach("summary-straight")
        sleep(1)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIApplication().screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
