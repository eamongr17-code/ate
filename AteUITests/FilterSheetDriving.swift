import XCTest

/// Driving Search's filter sheet: the score slider is dragged, not tapped, and its cities are
/// pills keyed by slug.
extension XCUIApplication {
    /// The score slider, once the sheet is up.
    var scoreRuler: XCUIElement { descendants(matching: .any).matching(identifier: "filter.score").firstMatch }

    /// Drags the score slider's lower thumb from 0.5 to `score`. The slider's first 44 points are the
    /// track's row; its eleven stops (0.5 … 5.0, then 6) run between the thumbs' 14pt insets.
    func raiseLowestScore(to score: Double) {
        let slider = scoreRuler
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "the slider is on the sheet")
        let frame = slider.frame
        let trackY = frame.minY + 22
        let inset: CGFloat = 14
        let step = (frame.width - 2 * inset) / 10
        let stop = CGFloat(score >= 6 ? 10 : (score - 0.5) / 0.5)
        let origin = coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: frame.minX + inset, dy: trackY))
        let to = origin.withOffset(CGVector(dx: frame.minX + inset + step * stop, dy: trackY))
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
