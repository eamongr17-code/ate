import XCTest

/// **The glass header, driven** (`lighter-header.html` B): slow drags down and back up each root
/// that wears it, for a screen recording to be read frame by frame. Nothing is asserted beyond the
/// root showing up; it runs only with `HEADER_DRIVE` set (`scripts/ci-sim.sh`), against
/// `-ate-preview-data`.
@MainActor
final class HeaderScrollUITests: XCTestCase {

    func testDriveHeaders() throws {
        guard ProcessInfo.processInfo.environment["HEADER_DRIVE"] != nil else { throw XCTSkip("no HEADER_DRIVE") }
        for root in ["journal", "feed", "saved"] {
            let app = XCUIApplication()
            app.launchArguments = ["-ate-preview-data", "-ate-ui-testing", "-ate-open", root]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["v2.root.\(root)"].firstMatch.waitForExistence(timeout: 10))
            pause(1.2)
            // Down the page in slow steps, a short way back up, on down again, then home.
            for _ in 0..<3 { drag(app, by: -220) }
            drag(app, by: 120)
            drag(app, by: 90)
            for _ in 0..<2 { drag(app, by: -220) }
            app.swipeUp()
            pause(0.8)
            app.swipeDown()
            pause(0.8)
            app.terminate()
        }
    }

    /// A finger's drag at reading speed, then a beat to see where everything settled.
    private func drag(_ app: XCUIApplication, by points: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: points < 0 ? 0.72 : 0.4))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: points)),
            withVelocity: XCUIGestureVelocity(260),
            thenHoldForDuration: 0.05
        )
        pause(0.5)
    }

    private func pause(_ seconds: TimeInterval) {
        _ = XCUIApplication().wait(for: .runningBackground, timeout: seconds)
    }
}
