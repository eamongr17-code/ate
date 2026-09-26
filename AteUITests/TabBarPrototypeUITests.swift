import XCTest

/// **The `-ate-tabbar` prototype, photographed.** Each bar — the custom pill, native A, native B —
/// on the Journal and the Feed, light and dark, at rest and after a scroll down (which is when the
/// native bar minimises). Against `-ate-preview-data`, so it touches no backend.
///
/// Runs only when `TABBAR_SHOT_DIR` is set (`TEST_RUNNER_TABBAR_SHOT_DIR=… xcodebuild test`); the
/// PNGs land there as `tabbar-<bar>-<screen>-<appearance>-<state>.png`.
final class TabBarPrototypeUITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = true
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["TABBAR_SHOT_DIR"],
                                 "set TEST_RUNNER_TABBAR_SHOT_DIR to photograph the tab bars")
        directory = URL(fileURLWithPath: path)
    }

    func testCustom() { photograph(bar: "custom", arguments: [], scrolls: true) }
    func testNativeA() { photograph(bar: "A", arguments: ["-ate-tabbar", "A"], scrolls: true) }
    func testNativeB() { photograph(bar: "B", arguments: ["-ate-tabbar", "B"], scrolls: true) }

    /// Whether the full-screen composer covers the native bar.
    func testComposerOverNativeBars() {
        for bar in ["A", "B"] {
            let app = launch(["-ate-tabbar", bar, "-ate-open-composer"], appearance: "light")
            settle(app, 3)
            save(name: "tabbar-\(bar)-composer-light")
            app.terminate()
        }
    }

    /// The compose control presents the composer, and closing it leaves the tab you were on
    /// selected — A's borrowed search slot must never become the selection.
    func testComposeTapPresentsAndReturns() {
        for bar in ["A", "B"] {
            let app = launch(["-ate-tabbar", bar, "-ate-open-feed"], appearance: "light")
            settle(app, 3)
            let compose = app.buttons["New entry"].firstMatch
            XCTAssertTrue(compose.waitForExistence(timeout: 5), "\(bar): the compose control is on screen")
            compose.tap()
            let close = app.buttons["Close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5), "\(bar): compose presents the composer")
            save(name: "tabbar-\(bar)-composer-tapped")
            close.tap()
            settle(app, 1.5)
            XCTAssertTrue(app.buttons["Feed"].firstMatch.isSelected, "\(bar): the Feed is still the tab")
            save(name: "tabbar-\(bar)-composer-closed")
            app.terminate()
        }
    }

    /// Scrolled down, the bar minimises; tapping the current tab brings the page back to its top.
    func testRetapScrollsToTop() {
        for bar in ["A", "B"] {
            let app = launch(["-ate-tabbar", bar, "-ate-open-feed"], appearance: "light")
            settle(app, 3)
            let title = app.staticTexts["Feed"].firstMatch
            app.swipeUp()
            app.swipeUp()
            settle(app, 1)
            XCTAssertFalse(title.isHittable, "\(bar): the header has scrolled away")
            app.buttons["Feed"].firstMatch.tap()
            settle(app, 1)
            if title.isHittable == false {
                // The first tap on a minimised bar only expands it.
                app.buttons["Feed"].firstMatch.tap()
                settle(app, 1)
            }
            save(name: "tabbar-\(bar)-retap")
            XCTAssertTrue(title.isHittable, "\(bar): re-tapping the tab scrolls to the top")
            app.terminate()
        }
    }

    private func photograph(bar: String, arguments: [String], scrolls: Bool) {
        for appearance in ["light", "dark"] {
            for screen in ["journal", "feed"] {
                let extra = screen == "feed" ? ["-ate-open-feed"] : []
                let app = launch(arguments + extra, appearance: appearance)
                settle(app, 3)
                let name = "tabbar-\(bar.lowercased())-\(screen)-\(appearance)"
                save(name: "\(name)-rest")
                if scrolls {
                    app.swipeUp(velocity: .slow)
                    settle(app, 1.5)
                    save(name: "\(name)-minimized")
                }
                app.terminate()
            }
        }
    }

    private func launch(_ arguments: [String], appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate.appearance", appearance] + arguments
        app.launch()
        return app
    }

    private func settle(_ app: XCUIApplication, _ seconds: TimeInterval) {
        _ = app.wait(for: .unknown, timeout: seconds)
    }

    private func save(name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
