import XCTest

/// A dish page's "More to explore" and "More like this": a card opens that dish, and a tag chip on it
/// opens the tag's page of dishes.
final class DishExploreUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing", "-ate-open", "dish/d0000001-0000-4000-8000-000000000001"]
        app.launch()
    }

    func testASimilarDishOpensAndItsTagOpensTheTagsPage() {
        let card = app.descendants(matching: .any).matching(identifier: "dish.explore.card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "More like this arrives under the reviews")
        scroll(to: card)
        keep("dish-explore")
        let name = card.label.components(separatedBy: ",").first ?? card.label
        card.tap()

        let title = app.staticTexts[name].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "that dish's page")
        let chip = app.buttons.matching(identifier: "dish.explore.tag").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "with its own tags")
        scroll(to: chip)
        let tag = chip.label
        chip.tap()

        let heading = app.staticTexts[tag].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5), "the tag's page, named for it")
        let row = app.buttons.matching(identifier: "search.dish").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "and its dishes, as Search's dish rows")
        keep("tag-page")
    }

    private func scroll(to element: XCUIElement) {
        for _ in 0..<6 where element.isHittable == false || element.frame.maxY > app.frame.maxY - 60 {
            app.swipeUp(velocity: .slow)
        }
    }

    /// The screen as the lead compares it against the artboard.
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
