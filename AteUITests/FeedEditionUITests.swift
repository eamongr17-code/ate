import XCTest

/// **The Feed's edition, driven** (round 8) — the three things it adds that a unit test cannot see:
/// a bookmark on The Top Ate wins its tap against the line that opens the dish, the cravings picker
/// rises, toggles and saves a shelf into the page, and a shelf's See all opens the tag's page.
///
/// Against `-ate-preview-data`: no backend, no session, never a row written anywhere.
final class FeedEditionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing", "-ate-open-feed"]
        // A UserDefaults argument, not a launch flag: the Feed was last opened long ago, so every
        // launch has New to the record in it (keyed to the preview drive's one person).
        app.launchArguments += ["-ate.feedLastOpened.00000000-0000-4000-8000-00000000a7e0", "0"]
        app.launch()
    }

    func testSavingFromTheTopAteFlipsInPlace() {
        let receipt = app.descendants(matching: .any).matching(identifier: "feed.topAte").firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 10), "the edition opens on The Top Ate")
        keep("feed-top")
        let bookmark = app.buttons.matching(identifier: "feed.save").firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5), "every line carries its own bookmark")
        let wasSaved = bookmark.isSelected
        bookmark.tap()
        XCTAssertTrue(waitUntil { bookmark.isSelected != wasSaved }, "it flips at the tap")
        XCTAssertTrue(receipt.exists, "and saving does not open the dish")

        // Mid-list, a scroll up brings the compact header back on the one frost (`Scrolled`).
        app.swipeUp(velocity: .slow)
        app.swipeUp(velocity: .slow)
        app.swipeDown(velocity: .slow)
        XCTAssertTrue(app.descendants(matching: .any)["compact.title"].waitForExistence(timeout: 5))
        keep("feed-compact")
    }

    func testChoosingACravingSavesItsShelf() {
        let choose = app.buttons["feed.cravings.choose"]
        scroll(to: choose)
        keep("feed-mid")
        choose.tap()
        let chip = app.buttons["cravings.style:burger"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the picker rises with its chips")
        XCTAssertFalse(chip.isSelected)
        chip.tap()
        XCTAssertTrue(waitUntil { chip.isSelected }, "a chip toggles on")
        keep("cravings-picker")
        app.buttons["sheet.primary"].tap()
        XCTAssertTrue(app.staticTexts["Burger"].waitForExistence(timeout: 10), "and its shelf joins the page")
    }

    func testAShelfsSeeAllOpensTheTagPage() {
        let seeAll = app.buttons.matching(identifier: "feed.shelf.seeAll").firstMatch
        scroll(to: seeAll)
        keep("feed-shelves")
        seeAll.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tag.page"].waitForExistence(timeout: 10),
                      "See all is the tag's own page")
        XCTAssertTrue(app.buttons.matching(identifier: "search.dish").firstMatch.waitForExistence(timeout: 10))
        app.buttons["Back"].tap()
        let end = app.descendants(matching: .any)["feed.caughtUp"]
        scroll(to: end, swipes: 12)
        XCTAssertTrue(end.exists, "and the edition ends, quietly")
        keep("feed-end")
    }

    private func scroll(to element: XCUIElement, swipes: Int = 10) {
        for _ in 0..<swipes where element.exists == false || element.isHittable == false
            || element.frame.maxY > app.frame.maxY - 120 {
            app.swipeUp(velocity: .slow)
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = app.wait(for: .runningForeground, timeout: 0.1)
        }
        return condition()
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
