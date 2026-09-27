import XCTest

/// **Round 5's explorations, driven** — the photo floating over the blurred page and the Diet key's
/// row, each the way a thumb uses it. The variant comes from `TEST_RUNNER_ATE_R5_ARGS` (for
/// example `-ate-r5-photo B`); without one, variant A. Screen recordings are taken around these.
///
/// Against `-ate-preview-data`, so it writes nothing.
final class Round5ExploreUITests: XCTestCase {

    private var app: XCUIApplication!

    func testAPhotoFloatsOverThePageSwipesPinchesAndGoesBack() {
        launch(["-ate-open-entry"], variant: ["-ate-r5-photo", "A"])
        let photo = app.buttons["photo.1"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        sleep(1)
        photo.tap()
        let preview = app.descendants(matching: .any)["photo.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "the photo is up over the page")
        sleep(1)
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
        // Sideways to the next photo, and back.
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: -260, dy: 0)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 260, dy: 0)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
        // Pinch in, look, and double-tap back out.
        let card = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        if card.exists {
            card.pinch(withScale: 2.2, velocity: 2)
            sleep(1)
            card.doubleTap()
            sleep(1)
        }
        // Down, and it goes back into its tile.
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 420)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitUntil(timeout: 5) { preview.exists == false }, "a swipe down puts it away")
        sleep(1)
        // A tap on the blurred page does too.
        photo.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { preview.exists == false }, "a tap outside puts it away")
        sleep(1)
    }

    func testTheDietKeyOpensItsCodesAndComesBack() {
        launch(["-ate-open-composer", "-ate-seed-draft"], variant: ["-ate-r5-diet", "A"])
        let diet = app.buttons["composer.key.diet"].firstMatch
        XCTAssertTrue(diet.waitForExistence(timeout: 10))
        sleep(1)
        for _ in 0..<2 {
            diet.tap()
            let back = app.buttons["composer.diet.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 3), "the codes are up")
            sleep(2)
            back.tap()
            XCTAssertTrue(diet.waitForExistence(timeout: 3), "the keys are back")
            sleep(2)
        }
        diet.tap()
        let code = app.buttons["composer.diet.gf"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 3))
        sleep(1)
        code.tap()
        XCTAssertTrue(diet.waitForExistence(timeout: 3), "a code goes in and the keys come back")
        sleep(2)
    }

    private func launch(_ arguments: [String], variant fallback: [String]) {
        continueAfterFailure = false
        app = XCUIApplication()
        let chosen = ProcessInfo.processInfo.environment["ATE_R5_ARGS"]?
            .split(separator: " ").map(String.init) ?? fallback
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments + chosen
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
}
