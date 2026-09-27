import XCTest

/// Driving the one filter sheet (round 5): the ruler is dragged, not tapped, and its cities are
/// pills keyed by slug.
extension XCUIApplication {
    /// The score ruler, once the sheet is up.
    var scoreRuler: XCUIElement { descendants(matching: .any).matching(identifier: "filter.score").firstMatch }

    /// Drags the ruler's lower end from 0.5 to `score` (half-steps). The ruler is the sheet's last
    /// 64 points of the element: a 36-tall band over the numbers, ten equal columns.
    func raiseLowestScore(to score: Double) {
        let ruler = scoreRuler
        XCTAssertTrue(ruler.waitForExistence(timeout: 5), "the ruler is on the sheet")
        let frame = ruler.frame
        let bandY = frame.maxY - 64 + 18
        let column = frame.width / 10
        let stop = CGFloat((score - 0.5) / 0.5)
        let origin = coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: frame.minX + column / 2, dy: bandY))
        let to = origin.withOffset(CGVector(dx: frame.minX + column * (stop + 0.5), dy: bandY))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// The range as the sheet prints it — "4.0+", "Any".
    var scoreRangeValue: String {
        staticTexts.matching(identifier: "filter.score.value").firstMatch.label
    }

    /// A city pill (`melbourne`), or Everywhere (`@everywhere`), or Near me (`@near-me`).
    func cityPill(_ id: String) -> XCUIElement {
        buttons.matching(identifier: "city.\(id)").firstMatch
    }
}
