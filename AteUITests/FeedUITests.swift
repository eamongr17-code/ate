import XCTest

/// **The feed, driven.**
///
/// The things a unit test cannot see, and every one of which is a whole feature if it is wrong:
/// whether a slip scrolls, whether the bookmark on a dish row is actually reachable next to a
/// button that opens the entry (nested controls are exactly where SwiftUI eats a tap), whether the
/// slip body opens the entry, and whether a byline opens a profile.
///
/// It runs against `-ate-preview-data` — the in-memory feed — so it needs no backend, no session and
/// no network, and can never write a row anywhere.
final class FeedUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing", "-ate-open-feed"]
    }

    /// Scroll → bookmark a dish → open the entry → open the profile.
    func testFeedScrollsSavesADishAndOpensAnEntryAndAProfile() {
        app.launch()

        let slips = app.otherElements.matching(identifier: "feed.slip")
        XCTAssertTrue(slips.firstMatch.waitForExistence(timeout: 10),
                      "the feed should draw other people's entries")
        attach("01-feed")

        // It scrolls, and paging does not empty it.
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(slips.firstMatch.exists, "the feed should still have slips after scrolling")
        app.swipeDown()
        app.swipeDown()

        // **The bookmark.** One dish, not the entry — and it has to win the tap against the button
        // underneath it that opens the entry.
        let bookmark = app.buttons.matching(identifier: "slip.save").firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5), "every dish row carries its own bookmark")
        let wasSaved = bookmark.isSelected
        bookmark.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { bookmark.isSelected != wasSaved },
                      "the bookmark flips at the tap, before any round trip")
        XCTAssertTrue(app.staticTexts["Feed"].exists, "and saving does not navigate anywhere")
        attach("02-feed-saved")

        // The slip's body is the door to the entry.
        app.buttons.matching(identifier: "feed.slip.body").firstMatch.tap()
        XCTAssertTrue(app.otherElements["entry.bill"].waitForExistence(timeout: 10),
                      "tapping a slip opens the entry, bill and all")
        // Somebody else's entry: a byline where the pencil is on your own, and a bookmark per line.
        let byline = app.buttons["entry.byline"]
        XCTAssertTrue(byline.waitForExistence(timeout: 5),
                      "somebody else's entry is signed, not editable")
        XCTAssertTrue(app.buttons["entry.saveAll"].exists,
                      "and the whole visit can be saved from the top bar")
        attach("03-entry-from-feed")

        // The byline is the door to their page.
        byline.tap()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 10),
                      "the byline opens their profile")
        XCTAssertTrue(app.otherElements.matching(identifier: "profile.slip").firstMatch
            .waitForExistence(timeout: 5), "with their entries under it")
        attach("04-profile")
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
