import XCTest

/// **Lists, driven** (build 92 notes): a new list opens its page with the picker over it and
/// "Add N dishes" ends on that page; an existing list's "Add dishes" returns to its page too.
/// Against `-ate-preview-data`; with `V2_SHOT_DIR` set, stills land there as `A-*.png`.
@MainActor
final class ListsUITests: XCTestCase {

    func testNewListEndsOnItsPageAndAddDishesStaysThere() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["v2.root.journal"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Lists"].firstMatch.tap()

        let newCard = app.buttons["lists.newCard"].firstMatch
        XCTAssertTrue(newCard.waitForExistence(timeout: 5), "the New list card leads the shelf")
        shoot("A-01-shelf")
        newCard.tap()
        let name = app.textFields["lists.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Late snacks")
        shoot("A-02-name")
        app.buttons["sheet.primary"].firstMatch.tap()

        let picks = app.buttons.matching(identifier: "lists.pick")
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 8), "the picker rises over the new page")
        XCTAssertTrue(app.descendants(matching: .any)["list.page"].firstMatch.exists, "the page is under it")
        picks.element(boundBy: 0).tap()
        picks.element(boundBy: 1).tap()
        shoot("A-03-picker")
        app.buttons["Add 2 dishes"].firstMatch.tap()

        let rows = app.descendants(matching: .any).matching(identifier: "list.row")
        XCTAssertTrue(waitUntil(5) { picks.firstMatch.exists == false && rows.count == 2 }, "on the new list's page with 2 rows")
        XCTAssertTrue(app.descendants(matching: .any)["list.page"].firstMatch.exists)
        shoot("A-04-new-list")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let cards = app.buttons.matching(identifier: "lists.card")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        let pasta = app.buttons["Pasta worth the trip"].firstMatch
        XCTAssertTrue(pasta.waitForExistence(timeout: 5))
        pasta.tap()
        XCTAssertTrue(waitUntil(5) { rows.count == 2 }, "the pasta list's two rows")
        app.buttons["list.add"].firstMatch.tap()
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 8))
        picks.element(boundBy: 0).tap()
        app.buttons["Add 1 dish"].firstMatch.tap()
        XCTAssertTrue(waitUntil(5) { picks.firstMatch.exists == false && rows.count == 3 }, "still on the list page, one more row")
        XCTAssertTrue(app.descendants(matching: .any)["list.page"].firstMatch.exists)
        shoot("A-05-existing-list")
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 0.2)
        }
        return condition()
    }

    private func shoot(_ name: String) {
        _ = XCUIApplication().wait(for: .runningBackground, timeout: 0.9)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["V2_SHOT_DIR"] else { return }
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
