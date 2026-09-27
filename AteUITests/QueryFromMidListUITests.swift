import XCTest

/// **A new query starts at the top.** A filter, a sort or a pill taken away, applied while scrolled
/// to mid-list, lands on the first of the new results with the header and its pills on screen —
/// never partway down them, where nothing says what the list is now showing.
///
/// Against `-ate-preview-data` with `-ate-preview-journal`'s longer journal, so it needs no backend
/// and writes nothing.
final class QueryFromMidListUITests: XCTestCase {

    /// Top rated, 4.0 and up, applied from the middle of the journal — then, from the middle of
    /// those results, one pill taken off the floating header.
    func testJournalQueryFromMidListStartsAtTheTop() {
        let app = launch(["-ate-preview-journal"])
        XCTAssertTrue(app.buttons["journal.filter"].firstMatch.waitForExistence(timeout: 10))
        let topOfJournal = firstRowLabel(app, "journal.slip.dish")
        toMidList(app)
        XCTAssertNotEqual(firstRowLabel(app, "journal.slip.dish"), topOfJournal, "precondition: mid-list")

        hittable(app.buttons.matching(identifier: "journal.filter"))?.tap()
        XCTAssertTrue(app.buttons["Top rated"].waitForExistence(timeout: 5))
        app.buttons["Top rated"].tap()
        app.buttons["4.0+"].firstMatch.tap()
        app.buttons["sheet.primary"].tap()
        assertAtTop(app, rows: "journal.slip.dish", pill: "Remove 4.0+", header: "journal.suggestions",
                    first: "Almond croissant")

        // A pill, taken off from mid-list: the rest of the query, from its first result.
        toMidList(app)
        let pill = hittable(app.buttons.matching(NSPredicate(format: "label == 'Remove Top rated'")))
        XCTAssertNotNil(pill, "the floating header carries the pills")
        pill?.tap()
        assertAtTop(app, rows: "journal.slip.dish", pill: "Remove 4.0+", header: "journal.suggestions", first: nil)
    }

    /// Search's filter sheet (round 4): the same rule. Search has no floating header — its control
    /// and pills scroll away with the page — so a filter is applied from as far down as the control
    /// is still on screen, and the results start at their top all the same.
    func testSearchFilterFromDownThePageStartsAtTheTop() {
        // `-ate-preview-deep`'s specials: a dish search for "ni" long enough to scroll.
        let app = launch(["-ate-open-search", "-ate-search-scope", "dishes", "-ate-search-query", "ni",
                          "-ate-preview-deep"])
        let control = app.buttons["search.filter"]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(identifier: "search.dish").firstMatch.waitForExistence(timeout: 10))
        let resting = control.frame.minY
        // Held at the end, so the page stops where the finger does.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(1)
        XCTAssertLessThan(control.frame.minY, resting - 60, "precondition: scrolled down the page")
        XCTAssertTrue(control.isHittable, "precondition: the control is still on screen")
        control.tap()
        XCTAssertTrue(app.buttons["4.0+"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["4.0+"].firstMatch.tap()
        app.buttons["sheet.primary"].tap()
        assertAtTop(app, rows: "search.dish", pill: "Remove 4.0+", header: "search.field", first: nil)
        XCTAssertEqual(control.frame.minY, resting, accuracy: 2, "the page is back at its top")
    }

    // MARK: -

    private func assertAtTop(
        _ app: XCUIApplication, rows: String, pill: String, header: String, first: String?,
        line: UInt = #line
    ) {
        let removable = app.buttons[pill].firstMatch
        XCTAssertTrue(removable.waitForExistence(timeout: 5), "the pill is there", line: line)
        // Settled: the scroll to the top is animated.
        sleep(2)
        let head = app.descendants(matching: .any).matching(identifier: header).firstMatch
        XCTAssertTrue(head.exists && head.isHittable, "the header is on screen", line: line)
        XCTAssertLessThan(head.frame.minY, 200, "…at the top of the page", line: line)
        XCTAssertTrue(hittable(app.buttons.matching(NSPredicate(format: "label == %@", pill))) != nil,
                      "the pills are on screen", line: line)
        let firstRow = app.buttons.matching(identifier: rows).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(firstRow, "results are on screen", line: line)
        if let firstRow {
            XCTAssertGreaterThan(firstRow.frame.minY, removable.frame.maxY - 1,
                                 "the first result sits under the pills, not behind them", line: line)
            XCTAssertLessThan(firstRow.frame.minY, 420, "the results start at their first row", line: line)
            if let first {
                XCTAssertTrue(firstRow.label.hasPrefix(first), "\(firstRow.label) is the first result", line: line)
            }
        }
    }

    private func toMidList(_ app: XCUIApplication) {
        drag(app, by: -600)
        drag(app, by: -600)
        sleep(1)
        // A little way back up: the floating header comes back, with its controls.
        drag(app, by: 140)
        sleep(1)
    }

    private func firstRowLabel(_ app: XCUIApplication, _ identifier: String) -> String? {
        app.buttons.matching(identifier: identifier).allElementsBoundByIndex.first { $0.isHittable }?.label
    }

    private func hittable(_ query: XCUIElementQuery) -> XCUIElement? {
        query.allElementsBoundByIndex.first { $0.isHittable }
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
        return app
    }

    private func drag(_ app: XCUIApplication, by dy: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy < 0 ? 0.8 : 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)))
    }
}
