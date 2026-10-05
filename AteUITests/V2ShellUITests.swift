import XCTest

/// **The rebuilt app's shell, driven**: iOS 26's own tab bar with `+` in its
/// detached trailing slot. What only a drive can see: the tabs switch, `+` brings the composer up
/// without ever selecting itself or changing the tab under it, a push keeps the tab bar, and a
/// re-tap scrolls the root back to its top.
///
/// Against `-ate-preview-data`, so it needs no backend and writes nothing. With
/// `TEST_RUNNER_V2_SHOT_DIR` set, `testCaptureShots` drops the review stills there (prefixed with
/// `TEST_RUNNER_V2_SHOT_MODE`, `light` or `dark`, which the simulator must already be in).
@MainActor
final class V2ShellUITests: XCTestCase {

    func testTabsSwitch() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["v2.root.journal"].firstMatch.waitForExistence(timeout: 10))
        for (name, root) in [("Feed", "feed"), ("Saved", "saved"), ("You", "you"), ("Journal", "journal")] {
            tab(app, name).tap()
            XCTAssertTrue(app.descendants(matching: .any)["v2.root.\(root)"].firstMatch.waitForExistence(timeout: 5), name)
            XCTAssertTrue(waitUntil(timeout: 3) { self.tab(app, name).isSelected }, "\(name) is the selected tab")
            shootIfAsked("tab-\(root)")
        }
        XCTAssertFalse(tab(app, "Search").exists, "Search is no longer a tab")
    }

    /// `+` presents the composer, and the tab under it never changes — during, and after.
    func testComposeOpensTheSheetAndLeavesTheTab() {
        let app = launch(["-ate-open", "feed"])
        XCTAssertTrue(app.descendants(matching: .any)["v2.root.feed"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(tab(app, "Feed").isSelected)
        tab(app, "New entry").tap()
        let close = app.buttons["sheet.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "+ presents the composer")
        XCTAssertFalse(app.buttons["sheet.primary"].firstMatch.isEnabled, "the tick waits for a place")
        close.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { close.exists == false }, "close dismisses it")
        XCTAssertTrue(tab(app, "Feed").isSelected, "the Feed is still the tab")
        XCTAssertFalse(tab(app, "New entry").isSelected, "+ is never selected")
        XCTAssertTrue(app.descendants(matching: .any)["v2.root.feed"].firstMatch.exists, "and still on screen, not a blank slot")
    }

    /// A pushed page keeps the tab bar, and Back returns to the root: the Journal's first entry,
    /// opened from its slip.
    func testPushKeepsTheTabBar() {
        let app = launch()
        let slip = firstSlip(app)
        XCTAssertTrue(slip.waitForExistence(timeout: 10))
        openEntry(from: slip)
        XCTAssertTrue(app.descendants(matching: .any)["entry.page"].firstMatch.waitForExistence(timeout: 5),
                      "the entry is pushed")
        XCTAssertTrue(tab(app, "Journal").isHittable, "the tab bar stays on a pushed page")
        XCTAssertTrue(tab(app, "New entry").isHittable, "and so does +")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { slip.isHittable }, "back to the root")
    }

    /// Scrolled down the entry list, a tap of the current tab brings the Journal back to its top.
    func testRetapScrollsToTop() {
        let app = launch()
        let slip = firstSlip(app)
        XCTAssertTrue(slip.waitForExistence(timeout: 10))
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { slip.isHittable == false }, "scrolled: the first slip has left")
        // Scrolled down, the bar has minimised (the system's own): its first tap brings the bar back,
        // the next re-taps the tab. Tap until the root is home, twice at most.
        let journal = tab(app, "Journal")
        journal.tap()
        if waitUntil(timeout: 2, { slip.isHittable }) == false { journal.tap() }
        XCTAssertTrue(waitUntil(timeout: 3) { slip.isHittable }, "re-tapping the tab scrolls to the top")
    }

    /// Scrolled down the Saved shelf, a tap of its tab brings it back to its top.
    func testSavedRetapScrollsToTop() {
        let app = launch(["-ate-open", "saved"])
        XCTAssertTrue(app.descendants(matching: .any)["v2.root.saved"].firstMatch.waitForExistence(timeout: 10))
        let place = app.descendants(matching: .any).matching(identifier: "saved.place").firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 10), "the shelf has a place")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { place.isHittable == false }, "scrolled: the first place has left")
        let saved = tab(app, "Saved")
        saved.tap()
        if waitUntil(timeout: 2, { place.isHittable }) == false { saved.tap() }
        XCTAssertTrue(waitUntil(timeout: 3) { place.isHittable }, "re-tapping the tab scrolls to the top")
    }

    /// The review stills: each root at rest and scrolled, a pushed page, the composer.
    func testCaptureShots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["V2_SHOT_DIR"] != nil else { throw XCTSkip("no V2_SHOT_DIR") }
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["v2.root.journal"].firstMatch.waitForExistence(timeout: 10))
        var number = 1
        func shoot(_ what: String) {
            pause(0.9)
            save(String(format: "%02d-%@", number, what))
            number += 1
        }
        for (name, root) in [("Journal", "journal"), ("Feed", "feed"), ("Saved", "saved"), ("You", "you")] {
            tab(app, name).tap()
            XCTAssertTrue(app.descendants(matching: .any)["v2.root.\(root)"].firstMatch.waitForExistence(timeout: 5))
            shoot("\(root)-rest")
            let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -260)))
            shoot("\(root)-scrolled")
            app.swipeDown()
            app.swipeDown()
        }
        tab(app, "Journal").tap()
        pause(0.6)
        app.buttons["v2.placeholder.open"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["v2.page"].firstMatch.waitForExistence(timeout: 5))
        shoot("pushed-page")
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -260)))
        shoot("pushed-page-scrolled")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(0.6)
        tab(app, "New entry").tap()
        XCTAssertTrue(app.buttons["sheet.close"].firstMatch.waitForExistence(timeout: 5))
        shoot("composer")
    }

    /// A photo on a slip opens the one viewer the shell hosts, and its close puts it away — on the
    /// Journal and on the Feed (build 87, note 4).
    func testSlipPhotoOpensTheViewer() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["v2.root.journal"].firstMatch.waitForExistence(timeout: 10))
        for name in ["Journal", "Feed"] {
            tab(app, name).tap()
            let photo = app.buttons.matching(identifier: "photo.0").firstMatch
            var swipes = 0
            while photo.isHittable == false, swipes < 8 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(photo.isHittable, "\(name) has a slip with a photo")
            photo.tap()
            let viewer = app.descendants(matching: .any)["entry.photoViewer"].firstMatch
            XCTAssertTrue(viewer.waitForExistence(timeout: 5), "a \(name) slip's photo opens the viewer")
            shootIfAsked("A-photo-viewer-\(name.lowercased())")
            app.buttons["Close"].firstMatch.tap()
            XCTAssertTrue(waitUntil(timeout: 5) { viewer.exists == false }, "and the viewer closes")
            app.swipeDown()
            app.swipeDown()
        }
    }

    /// The header over scrolled paper: the Journal's white slips and the Feed's text passing under the
    /// title row (build 87, note 1). Stills only, with `V2_SHOT_DIR`.
    func testCaptureScrollEdge() throws {
        guard ProcessInfo.processInfo.environment["V2_SHOT_DIR"] != nil else { throw XCTSkip("no V2_SHOT_DIR") }
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["v2.root.journal"].firstMatch.waitForExistence(timeout: 10))
        for (name, root) in [("Journal", "journal"), ("Feed", "feed")] {
            tab(app, name).tap()
            XCTAssertTrue(app.descendants(matching: .any)["v2.root.\(root)"].firstMatch.waitForExistence(timeout: 5))
            pause(0.9)
            shootIfAsked("A-header-\(root)-rest")
            let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: -330)))
            pause(0.9)
            shootIfAsked("A-header-\(root)-scrolled")
            app.swipeDown()
            app.swipeDown()
        }
    }

    // MARK: - Helpers

    private func firstSlip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "journal.slip").firstMatch
    }

    /// The slip's paper opens the entry wherever nothing of its own claims the tap: its foot line's
    /// trailing day, clear of the dish rows, the photos and the place.
    private func openEntry(from slip: XCUIElement) {
        slip.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
    }

    /// A still named exactly `name-<mode>.png` in `V2_SHOT_DIR`, when it is set.
    private func shootIfAsked(_ name: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["V2_SHOT_DIR"] else { return }
        let mode = environment["V2_SHOT_MODE"] ?? "light"
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(mode).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.tabBars.buttons[name].firstMatch
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
        return app
    }

    private func pause(_ seconds: TimeInterval) {
        _ = XCUIApplication().wait(for: .runningBackground, timeout: seconds)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 0.1)
        }
        return condition()
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        add(attachment)
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["V2_SHOT_DIR"] else { return }
        let mode = environment["V2_SHOT_MODE"] ?? "light"
        let url = URL(fileURLWithPath: directory).appendingPathComponent("v2-\(mode)-\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }
}
