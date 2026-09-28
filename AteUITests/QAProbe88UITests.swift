import XCTest

/// QA scratch probes for PR #88 — never merged.
final class QAProbe88UITests: XCTestCase {
    private var app: XCUIApplication!
    private let link = "ate://entry/e0000000-0000-4000-8000-000000000001"

    private func launch(_ arguments: [String]) {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-ate-preview-data", "-ate-ui-testing"] + arguments
        app.launch()
    }

    private var viewer: XCUIElement { app.descendants(matching: .any)["entry.photoViewer"].firstMatch }
    private var close: XCUIElement { app.buttons["Close"].firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func waitGone(_ element: XCUIElement, _ timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists == false { return true }
            _ = app.wait(for: .runningForeground, timeout: 0.2)
        }
        return element.exists == false
    }

    /// A link while the restored viewer is up waits for it, then opens.
    func testProbeLinkWaitsForTheViewer() {
        launch(["-ate-open-entry"])
        let photo = app.buttons["photo.1"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        sleep(1)
        photo.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.open(URL(string: link)!)
        let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        sleep(3)
        print("QA88: viewer still up after link = \(viewer.exists) byline=\(app.buttons["entry.byline"].exists)")
        shot("link-under-viewer")
        XCTAssertTrue(viewer.exists, "the link did not dismiss or push under the viewer")
        close.tap()
        XCTAssertTrue(waitGone(viewer))
        let opened = app.buttons["entry.byline"].firstMatch.waitForExistence(timeout: 8)
        print("QA88: after close, linked entry opened = \(opened)")
        XCTAssertTrue(opened)
        shot("link-after-viewer")
    }

    /// Every other photo door opens the same viewer, and it closes.
    func testProbeEveryPhotoDoor() {
        launch(["-ate-open-feed"])
        let slipPhoto = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo 1 of'")).firstMatch
        XCTAssertTrue(slipPhoto.waitForExistence(timeout: 15))
        slipPhoto.tap()
        print("QA88: feed slip viewer = \(close.waitForExistence(timeout: 5))")
        shot("feed-viewer")
        close.tap()
        print("QA88: feed slip viewer closed = \(waitGone(viewer))")

        launch(["-ate-open-dish"])
        let hero = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo 1 of'")).firstMatch
        print("QA88: dish hero found = \(hero.waitForExistence(timeout: 15))")
        if hero.exists {
            hero.tap()
            print("QA88: dish viewer = \(close.waitForExistence(timeout: 5))")
            shot("dish-viewer")
            close.tap()
            print("QA88: dish viewer closed = \(waitGone(viewer))")
        }

        launch(["-ate-open-place"])
        let menuPhoto = app.buttons["place.dish.photo"].firstMatch
        print("QA88: place menu photo found = \(menuPhoto.waitForExistence(timeout: 15))")
        if menuPhoto.exists {
            menuPhoto.tap()
            print("QA88: place viewer = \(close.waitForExistence(timeout: 5))")
            shot("place-viewer")
            close.tap()
            print("QA88: place viewer closed = \(waitGone(viewer))")
        }
    }

    /// A slip never passes a score: before the read, the dish page prints no aggregate.
    func testProbeSlipPassesNoScore() {
        launch(["-ate-open-feed", "-ate-slow-detail"])
        let row = app.descendants(matching: .any).matching(identifier: "feed.slip.dish").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.buttons["dish.place"].firstMatch.waitForExistence(timeout: 1.5))
        let rated = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Rated'")).firstMatch
        print("QA88: slip → before read, aggregate printed = \(rated.exists)")
        shot("slip-preview")
        XCTAssertFalse(rated.exists, "no score from a slip")
        XCTAssertTrue(app.buttons["dish.save"].waitForExistence(timeout: 8))
        print("QA88: slip → after read, aggregate = \(rated.exists ? rated.label : "none")")
    }

    /// A menu row passes the aggregate: the number before the read is the number after it.
    func testProbeMenuRowScoreIsTheAggregate() {
        launch(["-ate-open-place", "-ate-slow-detail"])
        let dish = app.buttons["place.dish"].firstMatch
        XCTAssertTrue(dish.waitForExistence(timeout: 15))
        print("QA88: menu row label = \(dish.label)")
        dish.tap()
        let rated = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Rated'")).firstMatch
        let early = rated.waitForExistence(timeout: 1.5) ? rated.label : "none"
        let saveEarly = app.buttons["dish.save"].exists
        shot("menu-preview")
        XCTAssertTrue(app.buttons["dish.save"].waitForExistence(timeout: 8))
        sleep(1)
        let late = rated.exists ? rated.label : "none"
        print("QA88: menu → before read = \(early) (read answered already: \(saveEarly)); after = \(late)")
        XCTAssertEqual(early, late)
    }
}

/// Diagnose the link-under-viewer result.
final class QAProbe88bUITests: XCTestCase {
    private var app: XCUIApplication!
    private let link = "ate://entry/e0000000-0000-4000-8000-000000000001"
    private var viewer: XCUIElement { app.descendants(matching: .any)["entry.photoViewer"].firstMatch }
    private var close: XCUIElement { app.buttons["Close"].firstMatch }

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

    private func openLink() {
        app.open(URL(string: link)!)
        let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
    }

    func testDiagnoseLinkUnderViewer() {
        launch(["-ate-open-entry"])
        let photo = app.buttons["photo.1"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        sleep(1)
        shot("d0-entry")
        photo.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        sleep(1)
        shot("d1-viewer")
        openLink()
        shot("d2-right-after-link")
        for i in 0..<6 {
            sleep(1)
            print("QA88d: t+\(i + 1)s viewer=\(viewer.exists) close=\(close.exists) byline=\(app.buttons["entry.byline"].exists) photo1=\(photo.exists)")
        }
        shot("d3-after-6s")
        print("QA88d: tree=\(app.debugDescription.prefix(3000))")
    }

    /// Control: the same link while the actions sheet (a #83 page cover) is up.
    func testDiagnoseLinkUnderSheet() {
        launch(["-ate-open-feed"])
        let slip = app.descendants(matching: .any).matching(identifier: "feed.slip.body").element(boundBy: 1)
        XCTAssertTrue(slip.waitForExistence(timeout: 15))
        slip.tap()
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        XCTAssertTrue(app.buttons["actions.Share"].firstMatch.waitForExistence(timeout: 5))
        openLink()
        sleep(3)
        print("QA88c: sheet still up after link = \(app.buttons["actions.Share"].exists)")
        shot("c1-sheet-after-link")
    }
}
