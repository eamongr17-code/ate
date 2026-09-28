import XCTest

/// **The shell's chrome, driven** — the things only a drive can see: a tab root keeps its top safe
/// area through rapid tab switching and re-taps, its header gets out of the way on the way down and
/// comes back on the way up (with the bar), and no page pushed from a tab shows the bar.
///
/// Against `-ate-preview-data`, so it needs no backend and writes nothing. With `TABBAR_SHOT_DIR`
/// set it also drops PNGs there for a side-by-side.
final class TabChromeUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Round 4's bug: a re-tap scrolled the Journal's *segment* to the top of the visible area, which
    /// put the logo under the status bar — and the counter was shared, so re-tapping any tab did it
    /// to the Journal behind. Rapid switching, re-taps included, leaves the header where it started.
    func testRapidSwitchingAndRetapsKeepTheHeaderBelowTheStatusBar() {
        launch()
        let button = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let home = button.frame.minY
        XCTAssertGreaterThan(home, 50, "the header starts below the status bar")
        let taps = ["Journal", "Feed", "Feed", "Journal", "Journal", "You", "You", "Journal",
                    "Search", "Journal", "Feed", "Journal"]
        for _ in 0..<2 {
            for name in taps { tap(name) }
        }
        sleep(1)
        save("chrome-journal-after-switching")
        XCTAssertEqual(button.frame.minY, home, accuracy: 0.5, "the header keeps its place under the status bar")
        tap("Feed")
        sleep(1)
        let area = app.buttons["feed.area"].firstMatch
        XCTAssertGreaterThan(area.frame.minY, 50, "the Feed's header is below the status bar too")
        save("chrome-feed-after-switching")
    }

    /// Down: the header slides away and the bar minimises. Up, from the middle of the list: both are
    /// straight back — the whole bar, not just the minimised pill.
    func testHeaderAndBarHideOnScrollDownAndReturnOnScrollUp() {
        launch(["-ate-open", "feed"])
        let area = app.buttons["feed.area"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 10))
        let home = area.frame.minY
        // The header in the list, and the copy that floats back over it: whichever is on screen.
        let areas = app.buttons.matching(identifier: "feed.area")
        func onScreen() -> XCUIElement? { areas.allElementsBoundByIndex.first { $0.isHittable } }
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { onScreen() == nil }, "the header slides away")
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["Search"].exists == false }, "the bar minimises")
        save("chrome-feed-scrolled-down")
        // A short drag down: nowhere near the top of the list.
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 120)))
        XCTAssertTrue(waitUntil(timeout: 2) { onScreen() != nil }, "the header is back on the way up")
        // Round 6: what comes back is the compact header — its chip in the row just under the status
        // bar, not the big header's copy — and no title as big as the page's.
        let chipTop = onScreen()?.frame.minY ?? 0
        XCTAssertGreaterThan(chipTop, 50, "under the status bar")
        XCTAssertLessThan(chipTop, home + 16, "in the compact row at the top, not further down the page")
        XCTAssertTrue(waitUntil(timeout: 2) { app.buttons["Search"].isHittable }, "and the bar is whole again")
        save("chrome-feed-scrolled-up")
    }

    /// Every page a tab pushes hides the bar — Ratings and Suggestions included — and a swipe back
    /// brings it back with the page, not half a second after it.
    func testEveryPushedPageHidesTheTabBar() {
        launch()
        let suggestions = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(suggestions.waitForExistence(timeout: 10))

        suggestions.tap()
        assertBarHidden("Suggestions")
        swipeBack()
        assertBarBack("Suggestions")

        app.buttons.matching(identifier: "journal.slip.body").firstMatch.tap()
        XCTAssertTrue(app.otherElements["entry.dishes"].waitForExistence(timeout: 10))
        assertBarHidden("Entry")
        swipeBack()
        assertBarBack("Entry")

        tap("You")
        let ratings = app.buttons["you.ratings"].firstMatch
        if ratings.waitForExistence(timeout: 10) {
            ratings.tap()
            assertBarHidden("Ratings")
            swipeBack()
            assertBarBack("Ratings")
        }
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        assertBarHidden("Settings")
        swipeBack()
        assertBarBack("Settings")

        tap("Feed")
        app.scrollToFeedSlip().tap()
        XCTAssertTrue(app.otherElements["entry.dishes"].waitForExistence(timeout: 10))
        assertBarHidden("Someone's entry")
        let byline = app.buttons["entry.byline"].firstMatch
        if byline.waitForExistence(timeout: 5) {
            byline.tap()
            sleep(1)
            assertBarHidden("Profile")
        }
    }

    /// A cancelled swipe back leaves the page and the hidden bar exactly as they were.
    func testCancelledSwipeBackKeepsTheBarHidden() {
        launch()
        let suggestions = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(suggestions.waitForExistence(timeout: 10))
        suggestions.tap()
        assertBarHidden("Suggestions")
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 60, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(1)
        assertBarHidden("Suggestions, after a cancelled swipe")
        save("chrome-cancelled-swipe")
    }

    /// The bug's own path: scrolled, then the tab re-tapped — the page goes to its true top, the logo
    /// below the status bar, not the segment at the top with the logo under the clock.
    func testRetapFromAScrolledJournalLandsTheLogoBelowTheStatusBar() {
        launch()
        let button = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let home = button.frame.minY
        app.swipeUp()
        sleep(1)
        tap("Journal")
        if waitUntil(timeout: 2, { abs(button.frame.minY - home) < 0.5 }) == false {
            tap("Journal") // the first tap on a minimised bar only expands it
        }
        XCTAssertTrue(waitUntil(timeout: 3) { abs(button.frame.minY - home) < 0.5 }, "back to the true top")
        save("chrome-journal-retap")
    }

    /// QA on #75: the tab root's scroll position held the slip at the top of the screen through a
    /// change to the list, so an entry written from a scrolled Journal landed above the screen. Done
    /// lands on the Journal's true top with the new entry on it.
    func testAnEntryWrittenFromAScrolledJournalLandsOnScreen() {
        launch()
        let button = app.buttons["journal.suggestions"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let home = button.frame.minY
        app.swipeUp()
        app.swipeUp()
        sleep(1)
        XCTAssertFalse(button.isHittable, "the Journal is scrolled away from its top")

        tap("New entry")
        let editor = app.textViews["composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let marker = "Landed from the middle"
        editor.typeText("\(marker) of the list.")
        app.buttons["composer.key.place"].tap()
        let row = app.buttons["row.Tipo 00"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["Use Tipo 00"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.buttons["composer.post"].tap()
        let done = app.buttons["share.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Done hands over to the Summary")
        done.tap()

        XCTAssertTrue(waitUntil(timeout: 5) { abs(button.frame.minY - home) < 0.5 },
                      "the Journal is back at its true top")
        let written = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(waitUntil(timeout: 5) { written.exists && written.isHittable },
                      "the entry just written is on screen")
        save("chrome-journal-landed")
    }

    /// QA on #75: scroll a tab down, switch away and back, scroll down again — the bar minimised and
    /// its full-size shadow stayed over empty linen. The shadow is never drawn under a minimised bar.
    func testTheShadowNeverOutlastsTheBarAcrossTabSwitches() {
        // The longer journal: since round 5's one-bar header the two-entry fixture no longer scrolls
        // far enough for the system to minimise the bar.
        for (start, other, arguments) in [
            ("Journal", "Feed", ["-ate-fixture", "journal"]), ("Feed", "Journal", ["-ate-open", "feed"])
        ] {
            launch(arguments)
            XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 10))
            XCTAssertEqual(shadow(), "shown", "\(start): at rest, the full bar has its shadow")
            app.swipeUp()
            assertShadowGoesWithTheBar("\(start), scrolled down")
            tap(other)
            sleep(1)
            tap(start)
            XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["Search"].isHittable }, "\(start): back on the full bar")
            XCTAssertEqual(shadow(), "shown", "\(start): back on the full bar, with its shadow")
            app.swipeUp()
            assertShadowGoesWithTheBar("\(start), scrolled down again after switching back")
            save("chrome-shadow-\(start)-after-switching")
            app.terminate()
        }
    }

    /// The bottom bounce: back on a tab left at the very bottom, a drag into the bounce may minimise
    /// the bar — and if it does, the shadow goes with it.
    func testTheShadowGoesWithTheBarInTheBottomBounce() {
        launch(["-ate-open", "feed"])
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 10))
        for _ in 0..<12 { app.swipeUp(velocity: .fast) }
        sleep(2)
        tap("Journal")
        sleep(1)
        tap("Feed")
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["Search"].isHittable })
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -160)))
        sleep(1)
        if app.buttons["Search"].exists == false {
            XCTAssertEqual(shadow(), "hidden", "a bar minimised in the bounce has no shadow")
        }
        save("chrome-shadow-bottom-bounce")
    }

    // MARK: - Helpers

    /// What the shell is drawing under the bar: "shown" or "hidden" (a UI-testing probe).
    private func shadow() -> String {
        // Round 5: the shadow is the bar's own (it shrinks with it), so it is "shown" exactly when the
        // app's bar says it is at full size.
        let state = (app.otherElements["tabbar.state"].firstMatch.value as? String) ?? "missing"
        if state.hasPrefix("expanded") { return "shown" }
        if state.hasPrefix("minimised") { return "hidden" }
        return state
    }

    /// The bar minimises on the scroll down (its tabs go), and the shadow goes with it.
    private func assertShadowGoesWithTheBar(_ moment: String, line: UInt = #line) {
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["Search"].exists == false },
                      "\(moment): the bar minimises", line: line)
        XCTAssertTrue(waitUntil(timeout: 1) { shadow() == "hidden" },
                      "\(moment): the minimised bar has no shadow (it reads \(shadow()))", line: line)
    }

    private func assertBarHidden(_ page: String, line: UInt = #line) {
        sleep(1)
        save("chrome-pushed-\(page)")
        XCTAssertFalse(app.buttons["Search"].firstMatch.isHittable, "\(page) hides the tab bar", line: line)
    }

    /// Back on the tab root, the bar is back — it is drawn on the root itself (round 5), so it
    /// arrives with the root by construction and cannot lag the pop.
    ///
    /// Round 4 timed this at 0.35s, which measured the test runner as much as the app: one
    /// accessibility snapshot can take longer than that, so a query that happened to land mid-pop
    /// failed the step (the flake on main). Now the wait is for the pop itself — and a swipe that
    /// did not pop fails here, with no second try.
    private func assertBarBack(_ page: String, line: UInt = #line) {
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["Search"].firstMatch.isHittable },
                      "the bar is back with the swipe from \(page)", line: line)
    }

    /// A full swipe back, edge to edge. The edge pan only starts recognising a little way in, so a
    /// 330pt drag could hand UIKit well under half the width, and it cancelled the pop (seen on the
    /// recording of a failed run: the page came 40% across and settled back). Released at the far
    /// edge, the pop commits on position alone, whatever the synthesised velocity.
    private func swipeBack() {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let far = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: far, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// A tab, by name — expanding a minimised bar first (its one visible item is the current tab).
    private func tap(_ name: String) {
        let button = app.buttons[name].firstMatch
        if button.exists == false {
            let current = ["Journal", "Feed", "Search", "You"].map { app.buttons[$0].firstMatch }.first { $0.exists }
            current?.tap()
            XCTAssertTrue(button.waitForExistence(timeout: 3), "the bar expands to show \(name)")
        }
        button.tap()
    }

    private func launch(_ arguments: [String] = []) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = app.wait(for: .runningForeground, timeout: 0.05)
        }
        return condition()
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["TABBAR_SHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
