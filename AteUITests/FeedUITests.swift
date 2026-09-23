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

        // **The stale bookmark QA found.** Feed → profile → their entry → toggle → Back used to
        // come back to a profile that still drew the old bookmark, because the propagation was a
        // hand-maintained list of stores and the profile was not on it. Every list listens now, and
        // this is the drive that keeps it that way.
        let profileBookmark = app.buttons.matching(identifier: "slip.save").firstMatch
        XCTAssertTrue(profileBookmark.waitForExistence(timeout: 5))
        let savedOnProfile = profileBookmark.isSelected
        app.buttons.matching(identifier: "profile.slip.body").firstMatch.tap()
        let line = app.buttons.matching(identifier: "entry.save").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "their entry's bill carries bookmarks")
        line.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { line.isSelected != savedOnProfile },
                      "the line flips at the tap")
        attach("05-entry-toggled")
        app.buttons["Back"].tap()
        let backOnProfile = app.buttons.matching(identifier: "slip.save").firstMatch
        XCTAssertTrue(backOnProfile.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { backOnProfile.isSelected != savedOnProfile },
                      "and the profile behind it already agrees")
        attach("06-profile-agrees")

        // **The actions sheet.** Four answers about a person, and the two that cannot be taken back
        // ask first. Driven rather than read: a sheet, a confirmation dialog and a destructive role
        // are three presentations, and a unit test sees none of them.
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["actions.Share"].waitForExistence(timeout: 5),
                      "the profile's ellipsis opens the actions sheet")
        XCTAssertTrue(app.buttons["actions.Report"].exists)
        XCTAssertFalse(app.buttons["actions.Save this place"].exists,
                       "a profile has no visit to save — the row is absent, not disabled")
        let block = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "actions.Block @")
        ).firstMatch
        XCTAssertTrue(block.exists, "and the last row is the block, by name")
        attach("07-actions")

        app.buttons["actions.Report"].tap()
        // Two matches: SwiftUI keeps the dialog's button in the hierarchy under its presenter as
        // well as in the dialog itself. Either one is the same button; the drive takes the first.
        let confirm = app.buttons.matching(identifier: "actions.confirmReport").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "reporting asks before it reports")
        attach("08-report-confirm")
        confirm.tap()
        // Confirming is the whole feedback the design carries: the sheet closes and the page is
        // where it was. No toast, no banner, no helper copy (design rule 1).
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5),
                      "reporting closes the sheet and leaves the profile up")
        XCTAssertFalse(app.buttons["actions.Report"].exists)
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
