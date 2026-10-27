import XCTest

/// **The dish map's Search here, driven** (build 243: it never showed). Pan the map off what the
/// sheet lists and Search here must be in the top bar, tappable; tapped, the sheet lists the screen
/// and the button goes. Against `-ate-preview-data`: the map opens framed on its one place.
@MainActor
final class DishMapUITests: XCTestCase {

    func testSearchHereShowsInTheBarAfterAPan() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing", "-ate-open", "feed"]
        // The map asks for the location the first time; without it, it opens on the busiest place.
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            let decline = alert.buttons["Don’t Allow"]
            guard decline.exists else { return false }
            decline.tap()
            return true
        }
        app.launch()

        let open = app.descendants(matching: .any)["feed.map"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the Feed's map button")
        open.tap()
        let page = app.descendants(matching: .any)["map.page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "the map is pushed")
        app.tap() // lets the interruption monitor answer the location prompt
        attach("opened")

        let searchHere = app.descendants(matching: .any)["map.searchHere"].firstMatch
        XCTAssertFalse(searchHere.exists, "no Search here before the map has moved")

        // Drag the middle of the map well off the listed area (the sheet lists its middle half).
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        let from = map.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3))
        let to = map.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3))
        from.press(forDuration: 0.05, thenDragTo: to)

        let shown = searchHere.waitForExistence(timeout: 8)
        attach("panned")
        XCTAssertTrue(shown, "Search here shows once the map has moved")
        XCTAssertTrue(searchHere.isHittable, "and is tappable, in the bar")
        let bar = app.navigationBars.firstMatch.frame
        XCTAssertTrue(bar.isEmpty || bar.intersects(searchHere.frame), "in the top bar's row")

        searchHere.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { searchHere.exists == false }, "tapped, the sheet lists the screen")
        attach("searched")
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["V2_SHOT_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("map-\(name).png")
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCUIApplication().wait(for: .runningForeground, timeout: 0.1)
        }
        return condition()
    }
}
