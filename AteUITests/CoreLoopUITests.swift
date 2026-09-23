import XCTest

/// **The core loop, driven.**
///
/// The one XCUITest flow `docs/ARCHITECTURE.md` budgets for, and it earns its keep on exactly the
/// things a unit test cannot see: whether tapping the composer raises a keyboard, whether typing a
/// number beside a dish turns into a score pill, whether Done leaves an entry on the journal and a
/// bill on its page. Every one of those was broken at least once during this milestone, and none
/// of them shows up in a diff.
///
/// It runs against `-ate-preview-data` — the in-memory service — so it needs no backend, no session
/// and no network, and can never write a row anywhere. Screenshots are attached at each step, which
/// is also how the milestone's evidence is produced:
///
/// ```
/// xcodebuild test -scheme Ate -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///   -only-testing:AteUITests -resultBundlePath <path>.xcresult
/// xcrun xcresulttool export attachments --path <path>.xcresult --output-path <dir>
/// ```
final class CoreLoopUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"]
    }

    /// Write → score inline → place → Done → the bill prints on the page → it is in the journal.
    func testWritingAnEntryPrintsABillAndLandsInTheJournal() {
        app.launch()
        attach("01-journal")

        // `+` presents rather than switching. The composer takes focus on appear, which is what
        // makes the next line work at all.
        app.buttons["New entry"].tap()
        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the composer should be on screen")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5),
                      "the composer must open with the keyboard up — nobody writes in one that doesn't")
        attach("02-composer-empty")

        // Typing a number after a dish, then moving on, becomes a score token. This is the
        // interaction the whole composer is built around.
        editor.typeText("Kisume with the team. The salmon roll 4.5 was the quiet star, ")
        attach("03-composer-typed")
        // Typing "4.5" and moving on must leave ONE token holding the whole number. Promoting at
        // the decimal point left a 4.0 pill and a stray ".5" in the words — a score nobody gave.
        let written = (editor.value as? String) ?? ""
        XCTAssertFalse(written.contains("4"), "the digits belong inside the token, not in the words")
        XCTAssertFalse(written.contains(".5"), "the decimal must not be left behind as words")
        XCTAssertTrue(written.contains("was the quiet star"), "the rest of the sentence is untouched")

        // The place is attached because it was TAPPED (design rule 8), never from location.
        app.buttons["composer.key.place"].tap()
        let row = app.buttons["row.Tipo 00"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the place sheet should offer places")
        attach("04-place-sheet")
        row.tap()
        app.buttons["Use Tipo 00"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "picking a place returns to the words")
        attach("05-composer-with-place")

        // **A token brings its own gap, and keeps it.** The CEO's first entry arrived as
        // "PJ’s Mexican cantinafishbowl margarita  was …": a place inserted where the words end got
        // no trailing space, so the next word welded itself to the pill. A unit test covers the
        // model; this covers the editor, where the pill is one character written through UIKit's own
        // edit path and the space could still be eaten or moved on the way in.
        editor.typeText("afterwards")
        let withPlace = (editor.value as? String) ?? ""
        XCTAssertTrue(withPlace.contains(" afterwards"),
                      "the word typed after the place pill must not weld to it: \(withPlace)")
        XCTAssertFalse(withPlace.contains("  "),
                       "and nothing may leave a gap the person did not type: \(withPlace)")

        app.buttons["composer.done"].tap()

        // The entry page. The words are there immediately; the bill arrives when the sorter does.
        let bill = app.otherElements["entry.bill"]
        XCTAssertTrue(bill.waitForExistence(timeout: 15), "the bill should print on the page")
        XCTAssertTrue(app.otherElements["entry.words"].exists,
                      "and the words are on the same page, above it")
        attach("06-entry-printed")

        // Back to the journal, where the entry now lives.
        app.buttons["Back to journal"].tap()
        let slips = app.buttons.matching(identifier: "journal.slip")
        XCTAssertTrue(slips.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(slips.count, 2, "the seeded entry plus the one just written")
        attach("07-journal-full")

        // And a slip is a door: tapping the older one opens its entry, bill and all.
        slips.element(boundBy: 1).tap()
        XCTAssertTrue(app.otherElements["entry.bill"].waitForExistence(timeout: 5),
                      "tapping a slip opens its entry")
        attach("10-entry-from-journal")
    }

    /// The score key and its slider: a fresh token reads 0.5, and sliding changes the pill in the
    /// words. Both were wrong in the spike, and both are invisible to a unit test.
    func testTheScoreKeyOpensOnAHalfStarAndWritesIntoTheWords() {
        app.launch()
        app.buttons["New entry"].tap()

        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("The tagliatelle al ragù ")

        app.buttons["composer.key.score"].tap()
        let slider = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Score for")
        ).firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "the Score key opens the slider")
        XCTAssertEqual(slider.value as? String, "Half a star out of 5",
                       "a fresh token is 0.5, and the slider must agree with the pill in the words")
        attach("08-slider-half")

        // A real finger drag, not `adjust(toNormalizedSliderPosition:)`: scoring is a **slide**
        // (design rule 7), and the thing worth testing is the gesture, not an accessibility action
        // that reaches the same code by a different door.
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))

        // Lifting commits: the panel closes, the score is in the words, and the digits are inside
        // the token rather than left lying in the sentence.
        XCTAssertTrue(slider.waitForNonExistence(timeout: 3),
                      "the slider closes when the finger lifts")
        let written = (editor.value as? String) ?? ""
        XCTAssertTrue(written.hasPrefix("The tagliatelle al ragù"),
                      "the words are untouched — the sorter adds structure, it never rewrites")
        XCTAssertFalse(written.contains("4"), "a score lives in a token, never as loose digits")
        attach("09-composer-scored")
    }

    /// **Undo, twice, then redo.** This crashed: promoting a score rewrote text storage underneath
    /// UIKit's `_UITextUndoOperationTyping`, and running that operation took the app down in
    /// `-[_UITextUndoOperationTyping _undoRedo]`. The second undo is the one that did it, so the
    /// test does two — and a redo, because taking undo over is only correct if redo still works.
    func testUndoAfterAScorePromotesDoesNotCrash() {
        app.launchArguments.append("-ate-undo-drive")
        app.launch()
        app.buttons["New entry"].tap()

        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("The tagliatelle al ragu 4.5, ")
        // The promotion deliberately runs on the next turn of the runloop, outside UIKit's edit
        // transaction — half the fix, and why this waits rather than asserting immediately.
        XCTAssertTrue(waitUntil(timeout: 3) { (editor.value as? String)?.contains("4.5") == false },
                      "the digits should have become a token")
        attach("12-before-undo")

        // Undo walks back through the edits in the order they were made: the trailing space first
        // (UIKit's own typing operation), then our promotion.
        app.buttons["debug.undo"].tap()
        XCTAssertEqual(app.state, .runningForeground, "the first undo must not take the app down")
        attach("13-after-undo")

        // The one that used to SIGABRT: UIKit's operation, run against storage a programmatic edit
        // had replaced underneath it.
        app.buttons["debug.undo"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { (editor.value as? String)?.contains("4.5") == true },
                      "the second undo gives the person their digits back")
        XCTAssertEqual(app.state, .runningForeground, "a second undo must not take the app down")

        app.buttons["debug.redo"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { (editor.value as? String)?.contains("4.5") == false },
                      "redo puts the pill back — it does not eat the score")
        XCTAssertEqual(app.state, .runningForeground, "and redo keeps it alive too")
        XCTAssertTrue(((editor.value as? String) ?? "").hasPrefix("The tagliatelle al ragu"),
                      "and the words themselves came through all of it unchanged")
        attach("14-after-redo")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 0.1)
        }
        return condition()
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
