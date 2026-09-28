import XCTest

extension XCUIApplication {
    /// **The Feed's latest receipts run under the edition** (round 8): The Top Ate, the shelves and
    /// the cravings row come first, so a drive that wants a feed slip swipes down to it.
    @discardableResult
    func scrollToFeedSlip(_ identifier: String = "feed.slip.body", timeout: TimeInterval = 10) -> XCUIElement {
        let target = descendants(matching: .any).matching(identifier: identifier).firstMatch
        _ = descendants(matching: .any)["feed.topAte"].waitForExistence(timeout: timeout)
        for _ in 0..<14 where target.exists == false || target.isHittable == false
            || target.frame.maxY > frame.maxY - 140 {
            swipeUp(velocity: .slow)
        }
        return target
    }
}
