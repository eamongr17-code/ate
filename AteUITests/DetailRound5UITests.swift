import XCTest

/// **Round 5, detail + share**: a link opens the entry it points at, somebody else's entry is shared
/// as a link (never their receipt), a sheet rises with its rows already in it, a photo zooms open
/// full screen (round 6: build 80's viewer again), the Diet key unfolds its codes, and the share
/// receipt leads with the dishes.
///
/// Against `-ate-preview-data`, so it writes nothing.
final class DetailRound5UITests: XCTestCase {

    private var app: XCUIApplication!

    /// Marcus's cheeseburger, in the preview data's feed.
    private static let feedEntry = "ate://entry/e0000000-0000-4000-8000-000000000001"

    func testAnEntryLinkOpensTheEntry() throws {
        launch([])
        XCTAssertTrue(app.buttons["journal.calendar"].firstMatch.waitForExistence(timeout: 10), "the journal is up")
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
        // Round 5: the area sheet became the location sheet — Near me, Everywhere, the cities.
        let title = app.staticTexts["Where?"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // The moment the sheet is there, its cities are too: read ahead, not after it rose.
        XCTAssertTrue(app.buttons["city.@everywhere"].exists)
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'city.'")).count, 2,
                             "the cities are in the sheet as it rises")
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

    // MARK: - The photo viewer (round 6: back to build 80's native zoom)

    /// A tapped photo zooms open full screen at its own shape, swipes to the next, pinches, and a
    /// swipe down — or Close — puts it back.
    func testAPhotoZoomsOpenSwipesPinchesAndGoesBack() {
        launch(["-ate-open-entry"])
        let photo = app.buttons["photo.1"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        sleep(1)
        photo.tap()
        let viewer = app.descendants(matching: .any)["entry.photoViewer"].firstMatch
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the viewer is up")
        XCTAssertTrue(app.descendants(matching: .any)["Photo 2 of 3"].firstMatch.waitForExistence(timeout: 3),
                      "it opens on the photo that was tapped")
        sleep(1)
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: -300, dy: 0)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
        XCTAssertTrue(close.exists, "a swipe pages; it does not close")
        app.pinch(withScale: 2.2, velocity: 2)
        sleep(1)
        app.doubleTap()
        sleep(1)
        XCTAssertTrue(close.exists, "zooming does not put it away")
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 480)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitUntil(timeout: 5) { viewer.exists == false }, "a swipe down puts it away")
        photo.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        sleep(1)
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { viewer.exists == false }, "Close puts it away")
    }

    // MARK: - Round 6: a detail page draws at once

    /// With the reads held back 2s (`-ate-slow-detail`), a dish opened from a feed slip already shows
    /// its name and its place on arrival, and the rest fills in without the name moving.
    func testADishPageDrawsAtOnceFromTheRowThatOpenedIt() {
        launch(["-ate-open-feed", "-ate-slow-detail"])
        let row = app.descendants(matching: .any).matching(identifier: "feed.slip.dish").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let name = row.label.components(separatedBy: ",").first ?? row.label
        row.tap()
        let place = app.buttons["dish.place"].firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 1.5), "the place is there before the read answers")
        let title = app.staticTexts[name].firstMatch
        XCTAssertTrue(title.exists, "and the dish's name")
        let top = title.frame.minY
        XCTAssertFalse(app.buttons["dish.save"].exists, "the read has not answered yet")
        XCTAssertTrue(app.buttons["dish.save"].waitForExistence(timeout: 8), "then it does")
        XCTAssertEqual(title.frame.minY, top, accuracy: 0.5, "and the name did not move")
    }

    /// The top bar's glass group waits for its controls: while the dish's read is held back there is
    /// no glass in the corner at all (never an empty capsule), and once it answers the glass is there
    /// around the bookmark, at its full width.
    func testTheCornerGlassWaitsForItsControls() {
        launch(["-ate-open-feed", "-ate-slow-detail"])
        let row = app.descendants(matching: .any).matching(identifier: "feed.slip.dish").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let controls = app.descendants(matching: .any).matching(identifier: "nav.controls").firstMatch
        XCTAssertTrue(app.buttons["dish.place"].firstMatch.waitForExistence(timeout: 1.5), "the page is up")
        XCTAssertFalse(controls.exists, "no glass before there is anything to put in it")
        XCTAssertTrue(app.buttons["dish.save"].waitForExistence(timeout: 8), "the read answers")
        XCTAssertTrue(controls.waitForExistence(timeout: 2), "and the glass comes with the bookmark")
        XCTAssertGreaterThanOrEqual(controls.frame.width, 64, "a lone control sits in a 64-wide pill")
    }

    /// The same for a place opened from a slip's pin line.
    func testAPlacePageDrawsItsNameAtOnce() {
        launch(["-ate-open-feed", "-ate-slow-detail"])
        let line = app.descendants(matching: .any).matching(identifier: "feed.slip.place").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        line.tap()
        let heading = app.staticTexts.matching(NSPredicate(format: "label == %@", "Tipo 00")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 1.5), "the place's name is there before the read answers")
        let top = heading.frame.minY
        XCTAssertTrue(app.descendants(matching: .any)["place.menu"].waitForExistence(timeout: 8))
        XCTAssertEqual(heading.frame.minY, top, accuracy: 0.5, "and it did not move")
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
