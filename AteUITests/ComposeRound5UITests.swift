import XCTest

/// **Round 5's compose lane, driven** — Post holding on the sort and the receipt entering whole, and
/// "From your photos" only when there is something to suggest. Runs on `-ate-preview-data`, so
/// nothing is written anywhere.
final class ComposeRound5UITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"]
    }

    /// Post → "Posting…" → the Summary, whose receipt is whole the moment it is there: Share is live
    /// as soon as the receipt is on screen, never a skeleton first.
    func testPostHoldsThenTheReceiptEntersWhole() {
        app.launchArguments += ["-ate-open-composer", "-ate-seed-draft"]
        app.launch()
        let post = app.buttons["composer.post"]
        XCTAssertTrue(post.waitForExistence(timeout: 10))
        XCTAssertEqual(post.label, "Post")
        post.tap()
        XCTAssertTrue(app.buttons["Posting…"].waitForExistence(timeout: 2), "the pill holds the word")
        attach("r5-posting")
        let share = app.buttons["share.send"]
        XCTAssertTrue(share.waitForExistence(timeout: 8), "Post hands over to the Summary")
        XCTAssertTrue(share.isEnabled, "the preview sorter answers inside the hold: the receipt arrives printed")
        XCTAssertFalse(app.buttons["summary.reprint"].exists)
        sleep(2)
        attach("r5-summary")
    }

    /// The sort outlasts the hold: the Summary stands with its pills and no receipt, then the receipt
    /// enters, printed — Share only ever comes on with it.
    func testALateSortEntersWhenFinal() {
        app.launchArguments += ["-ate-open-composer", "-ate-seed-draft", "-ate-slow-sort"]
        app.launch()
        let post = app.buttons["composer.post"]
        XCTAssertTrue(post.waitForExistence(timeout: 10))
        post.tap()
        let share = app.buttons["share.send"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        XCTAssertFalse(share.isEnabled, "nothing to send while the band is empty")
        let receipt = app.otherElements["summary.receipt"]
        XCTAssertFalse(receipt.exists, "the band is empty while the sort is out: no skeleton, no receipt")
        attach("r5-summary-waiting")
        let printed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: share)
        XCTAssertEqual(XCTWaiter().wait(for: [printed], timeout: 15), .completed, "the receipt enters when final")
        XCTAssertTrue(receipt.exists, "and it enters whole, with Share")
        sleep(2)
        attach("r5-summary-late")
    }

    /// From the Post tap to the hand-off the composer is frozen: the photo X, the library, Close and
    /// the words do nothing, and the entry posted is exactly the composer at the tap.
    func testTheComposerIsFrozenThroughTheHold() {
        app.launchArguments += ["-ate-open-composer", "-ate-seed-draft", "-ate-slow-sort"]
        app.launch()
        let post = app.buttons["composer.post"]
        XCTAssertTrue(post.waitForExistence(timeout: 10))
        let cluster = app.otherElements["3 photos"].firstMatch
        XCTAssertTrue(cluster.waitForExistence(timeout: 10))
        let lastX = cluster.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.12))
        let close = app.buttons["Close"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let library = app.buttons["Photo library"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let editor = app.textViews["composer.editor"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))

        post.tap()
        let posting = app.buttons["Posting…"]
        XCTAssertTrue(posting.waitForExistence(timeout: 2))
        // Each tap is checked while "Posting…" is still up, so it landed inside the hold.
        lastX.tap()
        attach("r5-frozen-hold")
        XCTAssertTrue(posting.exists && app.otherElements["3 photos"].exists, "the X did nothing")
        close.tap()
        XCTAssertTrue(posting.exists, "Close did nothing: the composer is still up, still posting")
        library.tap()
        editor.tap()
        XCTAssertFalse(app.keyboards.element.exists, "the words took no focus")
        XCTAssertFalse(app.navigationBars["Photos"].exists, "the library did not open")

        // The Summary, then the journal — and the entry has every photo that was there at the tap.
        let done = app.buttons["share.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        let share = app.buttons["share.send"]
        let printed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: share)
        XCTAssertEqual(XCTWaiter().wait(for: [printed], timeout: 15), .completed)
        done.tap()
        let slip = app.buttons.matching(identifier: "journal.slip.body").element(boundBy: 0)
        XCTAssertTrue(slip.waitForExistence(timeout: 8))
        slip.tap()
        XCTAssertTrue(app.buttons["Photo 3 of 3"].waitForExistence(timeout: 8),
                      "posted with all three photos, as at the tap")
        attach("r5-frozen-posted-entry")
    }

    /// No photos to suggest: no photo-stack button on the journal, and nothing in its place.
    func testNoSuggestionsNoButton() {
        app.launchArguments += ["-ate-no-photos"]
        app.launch()
        XCTAssertTrue(app.buttons["New entry"].waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertFalse(app.buttons["journal.suggestions"].exists, "nothing to suggest, nothing to open")
        attach("r5-journal-no-suggestions")
    }

    /// With suggestions it is there; dismissing the last one takes the page and the button with it.
    func testDismissingTheLastSuggestionLeaves() {
        app.launch()
        let button = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let dismiss = app.buttons.matching(identifier: "suggestions.dismiss")
        XCTAssertTrue(dismiss.firstMatch.waitForExistence(timeout: 10))
        while dismiss.count > 0 {
            dismiss.firstMatch.tap()
            sleep(1)
        }
        XCTAssertTrue(app.buttons["New entry"].waitForExistence(timeout: 5), "back on the journal")
        XCTAssertFalse(app.staticTexts["From your photos"].exists, "no empty page left standing")
        XCTAssertFalse(app.buttons["journal.suggestions"].waitForExistence(timeout: 2),
                       "and no button to an empty page")
        attach("r5-journal-after-last-dismiss")
    }

    /// Never asked for photos: no button on the journal. The first post's Summary asks once (a
    /// stand-in for the system prompt on a preview run); granted, the button is there when the
    /// Summary closes; and the next post does not ask again.
    func testTheFirstPostAsksForPhotosOnce() {
        app.launchArguments += ["-ate-photos-undetermined"]
        app.launch()
        XCTAssertTrue(app.buttons["New entry"].waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertFalse(app.buttons["journal.suggestions"].exists, "never asked, nothing to suggest yet")
        app.terminate()

        app.launchArguments += ["-ate-open-composer", "-ate-seed-draft"]
        app.launch()
        let post = app.buttons["composer.post"]
        XCTAssertTrue(post.waitForExistence(timeout: 10))
        post.tap()
        let prompt = app.alerts["Photos"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 12), "the one ask, once the receipt has settled")
        attach("r5-photo-ask")
        prompt.buttons["Allow"].tap()
        app.buttons["share.done"].tap()
        XCTAssertTrue(app.buttons["journal.suggestions"].waitForExistence(timeout: 8),
                      "granted: the photo-stack button is on the journal")
        attach("r5-journal-after-ask")

        // A second post, the ordinary way: no ask this time.
        app.buttons["New entry"].tap()
        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("The burrata 4.5 again, ")
        app.buttons["composer.key.place"].tap()
        let row = app.buttons["row.Tipo 00"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["Use Tipo 00"].tap()
        XCTAssertTrue(post.waitForExistence(timeout: 5))
        post.tap()
        XCTAssertTrue(app.buttons["share.done"].waitForExistence(timeout: 8))
        XCTAssertFalse(prompt.waitForExistence(timeout: 6), "asked once, never again")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
