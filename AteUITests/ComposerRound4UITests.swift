import XCTest

/// **Round 4's composer, driven** — the transitions and gestures only a drive can see: Done handing
/// over to the Summary, the keyboard going down, the diet row, the photo X, a score ending a
/// sentence, the new-place handover, and the secret sixth star. Runs on `-ate-preview-data`, so
/// nothing is written anywhere.
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
        let done = app.buttons["composer.post"]
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
        assertToolbarAtFoot()
    }

    /// The keyboard going down while the photo picker covers the composer — the picker cancelled —
    /// must not leave the toolbar where the keyboard's top edge used to be.
    func testToolbarDropsAfterThePickerCloses() {
        app.launch()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10))
        app.buttons["Photo library"].tap()
        let cancel = app.buttons.matching(identifier: "Cancel").firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), "the picker is up")
        cancel.tap()
        // The picker has gone once the composer's own keys take taps again.
        let place = app.buttons["composer.key.place"]
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: place)
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 10), .completed)
        attach("r4-after-picker")
        if app.keyboards.element.exists == false {
            let limit = app.windows.firstMatch.frame.height - 100
            let atFoot = XCTNSPredicateExpectation(
                predicate: NSPredicate { element, _ in ((element as? XCUIElement)?.frame.maxY ?? 0) > limit },
                object: place
            )
            XCTAssertEqual(XCTWaiter().wait(for: [atFoot], timeout: 5), .completed, "the toolbar sits at the foot")
        }
    }

    /// The leaf swaps the toolbar for the five codes; a code goes in after the dish and the toolbar
    /// comes back.
    func testDietRowInsertsAChipAndReturns() {
        app.launch()
        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText(" The prawn spaghetti")
        app.buttons["composer.key.diet"].tap()
        let gf = app.buttons["composer.diet.gf"]
        XCTAssertTrue(gf.waitForExistence(timeout: 3), "the diet row takes the toolbar")
        XCTAssertFalse(app.buttons["composer.key.score"].exists, "the ordinary keys give way")
        attach("r4-diet-row")
        gf.tap()
        XCTAssertTrue(app.buttons["composer.key.score"].waitForExistence(timeout: 3), "the toolbar comes back")
        attach("r4-diet-chip")
    }

    /// Each photo carries a visible X; tapping it takes the photo out.
    func testPhotoXRemovesIt() {
        app.launch()
        let cluster = app.otherElements["3 photos"].firstMatch
        XCTAssertTrue(cluster.waitForExistence(timeout: 10))
        attach("r4-photos-anchored")
        // The last photo's X, over its top-right corner.
        cluster.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.12)).tap()
        XCTAssertTrue(app.otherElements["2 photos"].firstMatch.waitForExistence(timeout: 5), "the X took it")
        attach("r4-photo-removed")
    }

    /// A library pick is in the cluster the moment the picker closes — a still tile at once, the
    /// photo as soon as it decodes — and the photos sit at the foot of the writing area.
    func testAPickAppearsAtOnce() {
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing", "-ate-open-composer"]
        app.launch()
        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("The ragù")
        app.buttons["Photo library"].tap()
        // The system picker's grid, by its own identifier — waited for, however slowly it loads.
        let firstPhoto = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 30), "the picker shows the library")
        // The grid reports itself before it takes touches (it is still sliding up): wait for that.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: firstPhoto)
        _ = XCTWaiter().wait(for: [ready], timeout: 10)
        // The tile's own point, not a blind screen position — it works whatever the grid's state.
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons.matching(NSPredicate(
            format: "(label == 'Add' OR identifier == 'Add' OR label == 'Done') AND identifier != 'composer.done'"
        )).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "a pick can be confirmed")
        add.tap()
        XCTAssertTrue(app.otherElements["1 photo"].firstMatch.waitForExistence(timeout: 3),
                      "the pick is in the cluster as the picker closes")
        attach("r4-pick-at-once")
        // The preview replaces the still tile: the cluster's tile draws an image.
        let tile = app.otherElements["composer.photos"].images.firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        attach("r4-pick-loaded")
    }

    /// "it was a 4.5." — the full stop promotes the score, and sits straight against the pill.
    func testAScoreEndingASentencePromotes() {
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing", "-ate-open-composer"]
        app.launch()
        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("The ragù was a 4.5.")
        let promoted = NSPredicate(format: "NOT (value CONTAINS '4.5')")
        let waited = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: promoted, object: editor)], timeout: 3)
        XCTAssertEqual(waited, .completed, "the digits became a pill at the full stop")
        let words = (editor.value as? String) ?? ""
        XCTAssertTrue(words.hasSuffix("\u{FFFC}."), "the stop sits straight after the pill: \(words)")
        attach("r4-score-full-stop")
    }

    /// A new place: both sheets go in one step and the composer holds the place.
    func testAddingAPlaceLandsBackInTheComposer() {
        app.launch()
        XCTAssertTrue(app.buttons["composer.key.place"].waitForExistence(timeout: 10))
        app.buttons["composer.key.place"].tap()
        let add = app.buttons["place.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        // The field opens holding what was searched for; this is a different place.
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "Round Four Diner")
        app.buttons["Add place"].tap()
        XCTAssertTrue(app.buttons["composer.key.place"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Where was this?"].exists, "the place sheet went with it")
        XCTAssertEqual(app.buttons["composer.key.place"].label, "Place: Round Four Diner")
        attach("r4-new-place")
    }

    /// Past 5.0 and held: the sixth star, and the pill reads 6.0.
    func testTheSecretSix() {
        app.launch()
        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        sleep(1)
        // A perfect 5.0 first: slide to the end and let go.
        app.buttons["composer.key.score"].tap()
        let track = slider()
        XCTAssertTrue(track.waitForExistence(timeout: 3), app.debugDescription)
        track.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: track.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)),
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )
        sleep(2)
        attach("r4-perfect-five")
        // Then the 6: past the end, and held.
        app.buttons["composer.key.score"].tap()
        XCTAssertTrue(track.waitForExistence(timeout: 3))
        track.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: track.coordinate(withNormalizedOffset: CGVector(dx: 1.14, dy: 0.5)),
            withVelocity: .slow,
            thenHoldForDuration: 1.8
        )
        sleep(2)
        attach("r4-six")
        // The panel has settled away with the 6 in the words (the pill is an attachment, which the
        // accessibility tree does not expose — the screenshot is the evidence; the encoding is
        // AteKit's `SixTokensTests`).
        XCTAssertFalse(slider().exists, "the panel settled")
    }

    // MARK: - Pieces

    private func slider() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Score for'"))
            .firstMatch
    }

    private func assertToolbarAtFoot() {
        let place = app.buttons["composer.key.place"]
        XCTAssertGreaterThan(place.frame.maxY, app.windows.firstMatch.frame.height - 100,
                             "the toolbar sits at the foot of the screen")
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
