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
        //
        // Waited for, not read straight off: the promotion runs on the NEXT turn of the runloop,
        // outside UIKit's edit transaction (the same seam `testUndoAfterAScorePromotes…` waits on).
        // Reading `value` the instant `typeText` returned raced it, and this test failed about one
        // run in six with the digits still in the words — a pass that depended on the machine.
        XCTAssertTrue(waitForEditor(editor, contains: false),
                      "the digits should have become a token")
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

        // `ComposerPlaceB`: the place is held by the key, never put into the words.
        XCTAssertEqual(app.buttons["composer.key.place"].label, "Place: Tipo 00",
                       "the Place key shows the place it holds")
        let words = (editor.value as? String) ?? ""
        XCTAssertFalse(words.contains("Tipo 00"), "picking a place never writes it into the words: \(words)")

        app.buttons["composer.done"].tap()

        // The Summary: the receipt printing on the coral ground, Share coming on when it has.
        let share = app.buttons["share.send"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "Done hands over to the Summary")
        let printed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: share)
        XCTAssertEqual(XCTWaiter().wait(for: [printed], timeout: 15), .completed,
                       "Share comes on once the receipt prints")
        attach("06-summary-printed")
        app.buttons["share.done"].tap()

        // The entry page, already waiting beneath: the dish rows lead it, the words follow.
        let dishes = app.otherElements["entry.dishes"]
        XCTAssertTrue(dishes.waitForExistence(timeout: 15), "the dish rows lead the page")
        XCTAssertTrue(app.otherElements["entry.words"].exists,
                      "and the words are on the same page, under them")
        attach("06b-entry-printed")

        // Back to the journal, where the entry now lives. "Back", not "Back to journal": the entry
        // page is reached from the feed and from a profile too now. Waited for: the page arrives
        // with the push animation, and a tap fired into a hierarchy still settling finds nothing.
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the entry page's own back control")
        back.tap()
        // A journal slip is no longer one flat button: its pin opens the place and its dish rows
        // open the dish, so the slip is a container and its body is the door to the entry.
        let slips = app.otherElements.matching(identifier: "journal.slip")
        XCTAssertTrue(slips.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(slips.count, 2, "the seeded entry plus the one just written")
        attach("07-journal-full")

        // And a slip is a door: tapping the older one's body opens its entry, bill and all.
        app.buttons.matching(identifier: "journal.slip.body").element(boundBy: 1).tap()
        XCTAssertTrue(app.otherElements["entry.dishes"].waitForExistence(timeout: 5),
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
        XCTAssertTrue(waitForEditor(editor, contains: false),
                      "the digits should have become a token")
        attach("12-before-undo")

        // Undo walks back through the edits in the order they were made. **How far each step goes is
        // UIKit's business, not ours**: it coalesces typing into groups of its own choosing, and the
        // promotion can land in the same group as the characters typed beside it. So the digits come
        // back on the first undo or the second — this asks after each one and requires only that
        // they came back, which is the behaviour the person cares about. (Asserting "4.5" after
        // exactly two undos is what made this test fail about one run in five: that run's second
        // undo gave back `ragu 4.` — the promotion reversed *and* part of the typing with it.)
        app.buttons["debug.undo"].tap()
        let digitsBackAfterFirst = waitForEditor(editor, contains: true, "4", timeout: 3)
        XCTAssertEqual(app.state, .runningForeground, "the first undo must not take the app down")
        attach("13-after-undo")

        // The one that used to SIGABRT: UIKit's operation, run against storage a programmatic edit
        // had replaced underneath it.
        app.buttons["debug.undo"].tap()
        let digitsBackAfterSecond = waitForEditor(editor, contains: true, "4")
        XCTAssertEqual(app.state, .runningForeground, "a second undo must not take the app down")
        XCTAssertTrue(digitsBackAfterFirst || digitsBackAfterSecond,
                      "undo gives the person the digits they typed back")

        // Redo as many times as we undid: whatever UIKit grouped, undoing N and redoing N is the
        // state we started from — the pill back in the words, no loose digits beside it.
        app.buttons["debug.redo"].tap()
        app.buttons["debug.redo"].tap()
        XCTAssertTrue(waitForEditor(editor, contains: false, "4"),
                      "redo puts the pill back — it does not eat the score")
        XCTAssertEqual(app.state, .runningForeground, "and redo keeps it alive too")
        XCTAssertTrue(((editor.value as? String) ?? "").hasPrefix("The tagliatelle al ragu"),
                      "and the words themselves came through all of it unchanged")
        attach("14-after-redo")
    }

    /// Waits for the digits to appear in — or disappear from — the editor's accessibility **value**,
    /// which is how "did the promotion happen / did undo give the score back" is observed from out
    /// here.
    ///
    /// **One attribute, ten seconds.** This used to be a hand-rolled three-second loop that built a
    /// fresh `XCUIApplication`, waited on its state and *then* read `editor.value` — three
    /// accessibility round-trips per turn, against an app still settling from the test before it. A
    /// full-suite run failed about one time in three, always here and never because the app was
    /// wrong: the budget went on the polling rather than on the app. `XCTNSPredicateExpectation`
    /// evaluates one keypath on XCTest's own cadence, so the wait costs almost nothing and can
    /// afford to be generous. The assertion is the same one: the value either holds "4.5" or it does
    /// not.
    private func waitForEditor(
        _ editor: XCUIElement,
        contains digits: Bool,
        _ literal: String = "4.5",
        timeout: TimeInterval = 10
    ) -> Bool {
        let format = digits ? "value CONTAINS %@" : "NOT (value CONTAINS %@)"
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: format, literal),
            object: editor
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
