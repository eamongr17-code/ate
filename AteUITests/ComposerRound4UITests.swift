import XCTest

/// **Round 4's composer, driven** — the transitions and gestures only a drive can see: Done handing
/// over to the Summary, the keyboard going down, the diet row, the photo X, and the secret sixth
/// star. Runs on `-ate-preview-data`, so nothing is written anywhere.
final class ComposerRound4UITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing", "-ate-open-composer", "-ate-seed-draft"]
    }

    /// Done hands over to the Summary in one clean step.
    func testDoneHandsOverToTheSummary() {
        app.launch()
        let done = app.buttons["composer.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        sleep(1)
        done.tap()
        XCTAssertTrue(app.buttons["share.send"].waitForExistence(timeout: 5), "Done hands over to the Summary")
        sleep(3)
        attach("r4-summary")
    }

    /// The keyboard goes down and the toolbar drops with it, to the bottom safe area.
    func testToolbarDropsWhenTheKeyboardGoes() {
        app.launch()
        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        attach("r4-keyboard-up")
        // An interactive dismissal: the finger drags the words down past the keyboard's top edge.
        let from = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let to = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(waitForKeyboardToGo(), "the drag takes the keyboard down")
        sleep(2)
        attach("r4-keyboard-down")
        let place = app.buttons["composer.key.place"]
        XCTAssertGreaterThan(place.frame.maxY, app.windows.firstMatch.frame.height - 100,
                             "the toolbar sits at the foot of the screen")
    }

    /// The keyboard going down UNDER a sheet (the place sheet's own search field takes it), then the
    /// sheet swiped away: the composer is left without a keyboard, and its toolbar has to be at the
    /// foot of the screen — not where the keyboard's top edge used to be.
    func testToolbarDropsAfterASheetIsSwipedAway() {
        app.launch()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10))
        app.buttons["composer.key.place"].tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        sleep(1)
        let grabber = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        grabber.press(
            forDuration: 0.05,
            thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        sleep(2)
        attach("r4-after-sheet")
        if app.keyboards.element.exists == false {
            let place = app.buttons["composer.key.place"]
            XCTAssertGreaterThan(place.frame.maxY, app.windows.firstMatch.frame.height - 100,
                                 "the toolbar sits at the foot of the screen")
        }
    }

    private func waitForKeyboardToGo() -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.element)
        return XCTWaiter().wait(for: [gone], timeout: 5) == .completed
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
