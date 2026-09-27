import AteKit
import SwiftUI

/// **How a score pill is dressed.** Every score is butter — except the two that mean something
/// more: a perfect **5.0** (``perfect``) and the secret **6** (``blownAway``, round 4).
///
/// One token, read by every lane that draws a person's score (the composer's pills, prose pills, a
/// slip's numeral), so a 6 looks like a 6 wherever it is printed. **Aggregates never take it**: an
/// average of 5.0 is not somebody's perfect score.
///
/// Eamon's pick (round 4, option B): the colours stay, and a single sweep of light crosses the pill
/// the first time it appears — once, never a loop, never with Reduce Motion.
/// - **5.0** — butter, like any score, with the sweep.
/// - **6** — brick with white lettering and the sweep. Not coral-and-ink: "not high enough
///   contrast" (Eamon). White on brick is 5.97:1, the same in light and dark, and it reads nothing
///   like the butter 5.0 beside it.
struct ScoreStyle: Hashable {
    /// The pill.
    let fill: Color
    /// The numerals.
    let ink: Color
    /// The star glyph inside the pill.
    let star: Color
    /// A one-shot light sweep the first time the pill appears (never with Reduce Motion).
    let shimmers: Bool

    /// Every other score: butter, ink.
    static let standard = ScoreStyle(fill: AteColor.butter, ink: AteColor.ink, star: AteColor.ink, shimmers: false)

    /// A perfect 5.0.
    static let perfect = ScoreStyle(fill: AteColor.butter, ink: AteColor.ink, star: AteColor.ink, shimmers: true)

    /// The secret 6.
    static let blownAway = ScoreStyle(fill: AteColor.brick, ink: .white, star: .white, shimmers: true)

    /// The sixth star on the slider, filled: the 6's own colour.
    static let sixthStar = AteColor.brick

    /// The style a person's own score prints in.
    static func of(_ rating: Rating) -> ScoreStyle {
        if rating.isBlownAway { return blownAway }
        if rating.isPerfect { return perfect }
        return standard
    }
}
