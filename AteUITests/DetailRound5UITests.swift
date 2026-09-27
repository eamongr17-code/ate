import XCTest

/// **Round 5, detail + share**: a link opens the entry it points at, somebody else's entry is shared
/// as a link (never their receipt), a sheet rises with its rows already in it, a photo floats over
/// the blurred page, the Diet key unfolds its codes, and the share receipt leads with the dishes.
///
/// Against `-ate-preview-data`, so it writes nothing.
final class DetailRound5UITests: XCTestCase {

    private var app: XCUIApplication!

    /// Marcus's cheeseburger, in the preview data's feed.
    private static let feedEntry = "ate://entry/e0000000-0000-4000-8000-000000000001"

    func testAnEntryLinkOpensTheEntry() throws {
        launch([])
        XCTAssertTrue(app.buttons["journal.filter"].firstMatch.waitForExistence(timeout: 10), "the journal is up")
        app.open(try XCTUnwrap(URL(string: Self.feedEntry)))
        // The simulator asks before a custom scheme opens its app; a phone tapping a link does not.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirm = springboard.buttons["Open"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        XCTAssertTrue(app.buttons["entry.byline"].firstMatch.waitForExistence(timeout: 10),
                      "the link pushed somebody else's entry, byline and all")
    }

    /// Signed out, cold: the link launches the app on Welcome, which goes straight into browsing and
    /// opens the entry — a read needs no account (0048).
    func testALinkOnAColdStartSignedOutOpensTheEntry() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing", "-ate-open-welcome"]
        app.terminate()
        app.open(try XCTUnwrap(URL(string: Self.feedEntry)))
        confirmOpen()
        XCTAssertTrue(app.buttons["entry.byline"].firstMatch.waitForExistence(timeout: 15),
                      "the link opened the entry, not the sign-in ask")
        XCTAssertFalse(app.buttons["welcome.signIn"].exists)
    }

    /// Signed out, warm: sitting on Welcome, a link opens the entry over the feed.
    func testALinkOnWelcomeOpensTheEntry() throws {
        launch(["-ate-open-welcome"])
        XCTAssertTrue(app.buttons["welcome.browse"].firstMatch.waitForExistence(timeout: 10), "Welcome is up")
        app.open(try XCTUnwrap(URL(string: Self.feedEntry)))
        confirmOpen()
        XCTAssertTrue(app.buttons["entry.byline"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["welcome.signIn"].exists, "nobody was asked to sign in to read")
    }

    /// Mid-onboarding: the link waits for the handle step, and opens once Continue is pressed.
    func testALinkDuringTheHandleStepOpensAfterIt() throws {
        launch(["-ate-open-first-run-handle"])
        let next = app.buttons["handle.continue"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10), "the handle step is up")
        app.open(try XCTUnwrap(URL(string: Self.feedEntry)))
        confirmOpen()
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the step is not skipped")
        XCTAssertFalse(app.buttons["entry.byline"].exists, "the entry waits")
        XCTAssertTrue(waitUntil(timeout: 5) { next.isEnabled })
        next.tap()
        XCTAssertTrue(app.buttons["entry.byline"].firstMatch.waitForExistence(timeout: 10),
                      "the link opened once the step was done")
    }

    /// The simulator asks before a custom scheme opens its app; a phone tapping a link does not.
    private func confirmOpen() {
        let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
    }

    func testSomebodyElsesEntrySharesALinkNotTheirReceipt() {
        launch(["-ate-open-feed"])
        let slip = app.descendants(matching: .any).matching(identifier: "feed.slip.body").firstMatch
        XCTAssertTrue(slip.waitForExistence(timeout: 10))
        slip.tap()
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let share = app.buttons["actions.Share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        // The system share sheet, holding the link — not the coral receipt screen.
        let activity = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10) || app.navigationBars["UIActivityContentView"].exists
                      || app.collectionViews.cells.count > 0, "the share sheet is up")
        XCTAssertFalse(app.buttons["share.send"].exists, "their receipt is not what leaves")
    }

    func testTheAreaSheetRisesWithItsAreasInIt() {
        launch(["-ate-open-feed"])
        let area = app.buttons["feed.area"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 10))
        area.tap()
        let title = app.staticTexts["Which area?"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // The moment the sheet is there, its areas are too: read ahead, not after it rose.
        XCTAssertTrue(app.buttons["row.Everywhere"].exists)
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'row.'")).count, 1,
                             "the areas are in the sheet as it rises")
    }

    func testThePlaceSheetRisesWithItsPlacesInIt() {
        launch(["-ate-open-entry"])
        let place = app.buttons["entry.place"].firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 10))
        place.press(forDuration: 0.8)
        let change = app.buttons["Change the place"].firstMatch
        if change.waitForExistence(timeout: 3) { change.tap() }
        let title = app.staticTexts["Where was this?"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["place.add"].exists)
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'row.'")).count, 0,
                             "its places are in the sheet as it rises")
    }

    // MARK: - The photo, over the blurred page

    func testAPhotoFloatsOverThePageSwipesPinchesAndGoesBack() {
        launch(["-ate-open-entry"])
        let photo = app.buttons["photo.1"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        sleep(1)
        photo.tap()
        let preview = app.descendants(matching: .any)["photo.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "the photo is up over the page")
        let card = app.descendants(matching: .any)["photo.preview.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        XCTAssertEqual(card.label, "Photo 2 of 3", "it opens on the photo that was tapped")
        sleep(1)
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: -260, dy: 0)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitUntil(timeout: 3) { card.label == "Photo 3 of 3" }, "a swipe pages to the next")
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 260, dy: 0)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitUntil(timeout: 3) { card.label == "Photo 2 of 3" }, "and back")
        card.pinch(withScale: 2.2, velocity: 2)
        sleep(1)
        card.doubleTap()
        sleep(1)
        XCTAssertTrue(preview.exists, "zooming does not put it away")
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 420)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitUntil(timeout: 5) { preview.exists == false }, "a swipe down puts it away")
        photo.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        sleep(1)
        // Above the card and below the status bar, on the blurred page.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { preview.exists == false }, "a tap outside puts it away")
    }

    // MARK: - The Diet key

    func testTheDietKeyUnfoldsItsCodesAndFoldsThemBack() {
        launch(["-ate-open-composer", "-ate-seed-draft"])
        let diet = app.buttons["composer.key.diet"].firstMatch
        XCTAssertTrue(diet.waitForExistence(timeout: 10))
        diet.tap()
        let back = app.buttons["composer.diet.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3), "the codes are up")
        for code in ["gf", "df", "v", "vg", "nf"] {
            XCTAssertTrue(app.buttons["composer.diet.\(code)"].waitForExistence(timeout: 2), code)
        }
        back.tap()
        XCTAssertTrue(diet.waitForExistence(timeout: 3), "the keys are back")
        XCTAssertTrue(waitUntil(timeout: 3) { back.exists == false }, "the codes fold away")
        diet.tap()
        let code = app.buttons["composer.diet.gf"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 3))
        code.tap()
        XCTAssertTrue(diet.waitForExistence(timeout: 3), "a code goes in and the keys come back")
    }

    // MARK: - The share receipt

    func testTheShareReceiptLeadsWithTheDishes() {
        launch(["-ate-open-share"])
        let send = app.buttons["share.send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Share is up")
        let dish = app.staticTexts["Tagliatelle al ragù"].firstMatch
        let place = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Tipo 00'")).firstMatch
        XCTAssertTrue(dish.waitForExistence(timeout: 5))
        XCTAssertTrue(place.exists)
        XCTAssertLessThan(dish.frame.minY, place.frame.minY, "the dishes lead; the place is under them")
        XCTAssertGreaterThan(dish.frame.height, place.frame.height, "the dish is the headline, the place fine print")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = app.wait(for: .runningForeground, timeout: 0.1)
        }
        return condition()
    }

    private func launch(_ arguments: [String]) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
    }
}
