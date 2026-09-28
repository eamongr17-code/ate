import XCTest

/// **Coming back to a scrolled list.** Scrolled to mid-list, over to the other tab and back again:
/// the list must answer at once. The Feed used to lock the main thread for minutes here — its lazy
/// stack, nested in a `VStack` under the header, flipping a prefetched slip between two states on
/// every layout pass — which on a device is the watchdog killing the app.
///
/// The loop only closes at particular scroll depths (a slip sitting just below the fold), so the drag
/// is fixed: 250pt on the preview feed lands in it, three times out of three, before the fix. The
/// Journal, a profile, a place's visits and a dish's reviews had the same nested shape and are
/// flat now too; their drives guard them (none of them reproduced the loop at these depths).
///
/// A hung app still "passes" an existence check eventually (XCTest gives up waiting for idle after a
/// minute and carries on), so the assertion is on the clock. Against `-ate-preview-data`, so it needs
/// no backend and writes nothing.
final class FeedTabReturnUITests: XCTestCase {

    func testReturningToAScrolledFeedStaysResponsive() {
        let app = launch(["-ate-open", "feed"])
        XCTAssertTrue(slip("feed", in: app).waitForExistence(timeout: 10))
        for round in 0..<3 {
            drag(app, by: -250)
            tab("Journal", in: app)
            XCTAssertTrue(slip("journal", in: app).waitForExistence(timeout: 5), "round \(round): on the Journal")
            assertAnswers(round: round, "the Feed") {
                tab("Feed", in: app)
                return slip("feed", in: app)
            }
        }
    }

    func testReturningToAScrolledJournalStaysResponsive() {
        let app = launch(["-ate-fixture", "journal"])
        XCTAssertTrue(slip("journal", in: app).waitForExistence(timeout: 10))
        for round in 0..<3 {
            drag(app, by: -250)
            tab("Feed", in: app)
            XCTAssertTrue(slip("feed", in: app).waitForExistence(timeout: 5), "round \(round): on the Feed")
            assertAnswers(round: round, "the Journal") {
                tab("Journal", in: app)
                return slip("journal", in: app)
            }
        }
    }

    // MARK: - Pushed pages

    // A pushed page hides the tab bar, so "away and back" is an entry pushed over it and popped.
    // The `deep` fixture makes the first feed entry's author, place and dish (the pages opened
    // here) long enough to be mid-list.

    private static let jess = "profile/11111111-0000-4000-8000-000000000003"
    private static let tipo = "place/b7e00000-0000-4000-8000-000000000001"
    private static let prawnSpaghetti = "dish/d0000001-0000-4000-8000-000000000001"

    func testReturningToAScrolledProfileStaysResponsive() {
        returnsToPushedPage(opening: Self.jess, list: "profile.slip.dish", door: "profile.slip.body")
    }

    func testReturningToAScrolledPlaceStaysResponsive() {
        returnsToPushedPage(opening: Self.tipo, list: "place.slip.dish", door: "place.slip.body")
    }

    func testReturningToAScrolledDishStaysResponsive() {
        returnsToPushedPage(opening: Self.prawnSpaghetti, list: "dish.review.entry", door: "dish.review.entry")
    }

    private func returnsToPushedPage(opening: String, list: String, door: String, line: UInt = #line) {
        let app = launch(["-ate-open", opening, "-ate-fixture", "deep"])
        let row = app.buttons.matching(identifier: list).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), line: line)
        for round in 0..<3 {
            drag(app, by: -250)
            let doors = app.buttons.matching(identifier: door).allElementsBoundByIndex
            guard let open = doors.first(where: { $0.isHittable }) else {
                return XCTFail("round \(round): no \(door) on screen", line: line)
            }
            open.tap()
            XCTAssertTrue(app.otherElements["entry.dishes"].waitForExistence(timeout: 5),
                          "round \(round): the entry is up", line: line)
            assertAnswers(round: round, opening, line: line) {
                app.buttons["Back"].firstMatch.tap()
                return row
            }
        }
    }

    // MARK: -

    /// Generous for a simulator under load; the hang this guards against ran past two minutes.
    private static let budget: TimeInterval = 8

    private func assertAnswers(
        round: Int, _ screen: String, line: UInt = #line, _ action: () -> XCUIElement
    ) {
        let start = Date()
        let element = action()
        XCTAssertTrue(element.waitForExistence(timeout: 5), "round \(round): \(screen)'s slips are back", line: line)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, Self.budget, "round \(round): \(screen) took \(Int(elapsed))s to answer", line: line)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
        return app
    }

    private func slip(_ list: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "\(list).slip.dish").firstMatch
    }

    private func drag(_ app: XCUIApplication, by dy: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)))
    }

    /// A minimised bar shows only the current tab; tapping it expands the bar first.
    private func tab(_ name: String, in app: XCUIApplication) {
        let button = app.buttons[name].firstMatch
        if button.exists == false {
            let current = ["Journal", "Feed", "Search", "You"].map { app.buttons[$0].firstMatch }.first { $0.exists }
            current?.tap()
            _ = button.waitForExistence(timeout: 3)
        }
        button.tap()
    }
}
