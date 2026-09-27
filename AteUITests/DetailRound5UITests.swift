import XCTest

/// **Round 5, detail + share**: a link opens the entry it points at, somebody else's entry is shared
/// as a link (never their receipt), and a sheet rises with its rows already in it.
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

    private func launch(_ arguments: [String]) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
    }
}
