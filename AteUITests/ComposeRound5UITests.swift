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
        attach("r5-summary-waiting")
        let printed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: share)
        XCTAssertEqual(XCTWaiter().wait(for: [printed], timeout: 15), .completed, "the receipt enters when final")
        sleep(2)
        attach("r5-summary-late")
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

    /// Never asked for photos: no button on the journal. The first post's Summary asks once, and
    /// granted, the button is there when the Summary closes.
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
        let done = app.buttons["share.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        // The receipt enters and settles, then the one ask (the preview library says yes).
        sleep(4)
        done.tap()
        XCTAssertTrue(app.buttons["journal.suggestions"].waitForExistence(timeout: 8),
                      "granted: the photo-stack button is on the journal")
        attach("r5-journal-after-ask")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
