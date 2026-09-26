import XCTest

/// **Round 3's composer interactions, driven** — the ones a unit test cannot see: a long press on a
/// staged photo takes it out, and the place sheet and "New place" are native sheets. Runs on
/// `-ate-preview-data`, so nothing is written anywhere.
final class ComposerRound3UITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing", "-ate-open-composer", "-ate-seed-draft"]
    }

    func testLongPressRemovesAPhotoAndThePlaceSheetsAreNative() {
        app.launch()
        let cluster = app.otherElements["3 photos"].firstMatch
        XCTAssertTrue(cluster.waitForExistence(timeout: 10), "the seeded draft stages three photos")
        attach("r3-01-composer-three-photos")

        // The first tile's visible left half: a long press brings the system menu.
        cluster.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).press(forDuration: 1.2)
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "a long press offers Remove")
        attach("r3-02-photo-menu")
        remove.tap()
        XCTAssertTrue(app.otherElements["2 photos"].firstMatch.waitForExistence(timeout: 5), "the photo is gone")
        attach("r3-03-photo-removed")

        app.buttons["composer.key.place"].tap()
        let add = app.buttons["place.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "the place sheet opens")
        attach("r3-04-place-sheet")
        add.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "New place opens over it")
        attach("r3-05-new-place-sheet")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
