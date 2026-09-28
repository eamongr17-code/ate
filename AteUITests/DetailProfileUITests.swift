import XCTest

/// **How fast a dish or a place page shows something, on staging's seeded data** (round 6).
///
/// Not part of an ordinary run: it reads the live staging project (reads only — it never signs in,
/// it browses), so it is skipped unless `ATE_PROFILE=1` is in the runner's environment
/// (`TEST_RUNNER_ATE_PROFILE=1`). Each open prints a `PROFILE` line — milliseconds from the tap to
/// the dish's place line (the header drawn) and to its bookmark (the header read answered).
final class DetailProfileUITests: XCTestCase {

    private var app: XCUIApplication!

    func testOpeningDishesAndAPlaceOnStaging() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATE_PROFILE"] == "1", "a staging profile, on request")
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-ate-ui-testing"]
        app.launch()
        // Signed out: the feed, browsing.
        let browse = app.buttons["welcome.browse"].firstMatch
        if browse.waitForExistence(timeout: 15) { browse.tap() }
        let rows = app.descendants(matching: .any).matching(identifier: "feed.slip.dish")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "the seeded feed")
        sleep(2)

        for index in 0..<3 {
            let row = rows.element(boundBy: index)
            guard row.waitForExistence(timeout: 10) else { break }
            let started = Date()
            row.tap()
            let place = app.buttons["dish.place"].firstMatch
            let drawn = place.waitForExistence(timeout: 20) ? Date().timeIntervalSince(started) : -1
            let save = app.buttons["dish.save"].firstMatch
            let read = save.waitForExistence(timeout: 20) ? Date().timeIntervalSince(started) : -1
            print("PROFILE dish \(index) drawn_ms=\(Int(drawn * 1000)) read_ms=\(Int(read * 1000))")
            sleep(2)
            back()
            sleep(1)
        }

        let line = app.descendants(matching: .any).matching(identifier: "feed.slip.place").firstMatch
        if line.waitForExistence(timeout: 10) {
            let name = line.label
            let started = Date()
            line.tap()
            let heading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                               String(name.prefix(6)))).firstMatch
            let drawn = heading.waitForExistence(timeout: 20) ? Date().timeIntervalSince(started) : -1
            let menu = app.descendants(matching: .any)["place.menu"].firstMatch
            let read = menu.waitForExistence(timeout: 20) ? Date().timeIntervalSince(started) : -1
            print("PROFILE place drawn_ms=\(Int(drawn * 1000)) menu_ms=\(Int(read * 1000))")
            sleep(2)
        }
    }

    private func back() {
        let back = app.buttons["nav.back"].firstMatch
        if back.exists {
            back.tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }
}
