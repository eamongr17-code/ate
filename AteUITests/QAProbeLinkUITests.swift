import XCTest

/// QA scratch probe — a link arriving while something covers the page. Never merged.
final class QAProbeLinkUITests: XCTestCase {
    private var app: XCUIApplication!
    private let link = "ate://entry/e0000000-0000-4000-8000-000000000001" // Marcus's cheeseburger

    private func launch(_ arguments: [String]) {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
    }

    private func shot(_ name: String) {
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: "/Users/runner/work/ate/ate/ci-out/\(name).png")
        )
    }

    private var marcus: Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'marcus.eats'")).firstMatch.exists
    }

    private var photoCover: Bool {
        app.descendants(matching: .any)["entry.photoViewer"].firstMatch.exists
            || app.descendants(matching: .any)["photo.preview"].firstMatch.exists
    }

    private func openLink() {
        app.open(URL(string: link)!)
        let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
    }

    private func poll(_ label: String, seconds: Int, _ state: () -> String) {
        for i in 0..<seconds {
            sleep(1)
            print("QALINK \(label) t+\(i + 1)s \(state())")
        }
    }

    func testLinkWhilePhotoIsUp() {
        launch(["-ate-open-entry"])
        let photo = app.buttons["photo.1"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        sleep(1)
        photo.tap()
        sleep(2)
        print("QALINK photo: cover up before link = \(photoCover)")
        openLink()
        poll("photo", seconds: 4) { "cover=\(photoCover) marcus=\(marcus)" }
        shot("photo-after-link")
        if photoCover {
            let close = app.buttons["Close"].firstMatch
            if close.exists { close.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14)).tap() }
            poll("photo-closed", seconds: 5) { "cover=\(photoCover) marcus=\(marcus)" }
        }
        shot("photo-end")
    }

    func testLinkWhileActionsSheetIsUp() {
        launch(["-ate-open-feed"])
        let slip = app.descendants(matching: .any).matching(identifier: "feed.slip.body").firstMatch
        XCTAssertTrue(slip.waitForExistence(timeout: 15))
        slip.tap()
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let share = app.buttons["actions.Share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        openLink()
        poll("sheet", seconds: 4) { "sheet=\(share.exists) marcus=\(marcus)" }
        shot("sheet-after-link")
        if share.exists {
            app.swipeDown(velocity: .fast)
            poll("sheet-closed", seconds: 5) { "sheet=\(share.exists) marcus=\(marcus)" }
        }
        shot("sheet-end")
    }

    func testLinkWhileComposerIsUp() {
        launch(["-ate-open-composer"])
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        openLink()
        poll("composer", seconds: 4) { "composer=\(close.exists) marcus=\(marcus)" }
        shot("composer-after-link")
    }
}
