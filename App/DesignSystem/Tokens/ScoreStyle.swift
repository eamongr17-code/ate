import AteKit
import SwiftUI

/// **How a score pill is dressed.** Every score is butter — except the two that mean something
/// more: a perfect **5.0** (``perfect``) and the secret **6** (``blownAway``, round 4).
///
/// One token, read by every lane that draws a person's score (the composer's pills, prose pills, a
/// slip's numeral), so a 6 looks like a 6 wherever it is printed. **Aggregates never take it**: an
/// average of 5.0 is not somebody's perfect score.
///
/// ## Exploration (round 4) — NOT PICKED YET
///
/// The perfect and blown-away looks are an open question for Eamon. Three options sit behind the
/// Debug-only launch argument `-ate-perfect-style A|B|C`; without it the build keeps today's look
/// (5.0 is butter like any score), and the 6 — which has no "today" — takes coral, the one colour
/// the brand already shouts with. Nothing here becomes the default until an option is chosen.
///
/// - **A — colour:** 5.0 is a coral pill; the 6 is the inverted pill (ink, cream in dark) with a coral
///   star.
/// - **B — shimmer:** both keep their colour (5.0 butter, 6 coral) and a single light sweep crosses
///   the pill the first time it appears. Once, never a loop.
/// - **C — both:** A's colours and B's sweep.
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
    static var perfect: ScoreStyle {
        switch Option.launched {
        case .current: standard
        case .colour: coral
        case .shimmer: ScoreStyle(fill: AteColor.butter, ink: AteColor.ink, star: AteColor.ink, shimmers: true)
        case .both: coral.shimmering
        }
    }

    /// The secret 6.
    static var blownAway: ScoreStyle {
        switch Option.launched {
        case .current: coral
        case .colour: inverted
        case .shimmer: coral.shimmering
        case .both: inverted.shimmering
        }
    }

    /// The sixth star on the slider, filled: the special colour, in every option.
    static let sixthStar = AteColor.coral

    /// The style a person's own score prints in.
    static func of(_ rating: Rating) -> ScoreStyle {
        if rating.isBlownAway { return blownAway }
        if rating.isPerfect { return perfect }
        return standard
    }

    // MARK: - Pieces

    private static let coral = ScoreStyle(fill: AteColor.coral, ink: AteColor.ink, star: AteColor.ink, shimmers: false)
    /// The foreground's own pill: ink in light, cream in dark — the one pill that inverts.
    private static let inverted = ScoreStyle(
        fill: AtePalette.automatic.fg,
        ink: AtePalette.automatic.inverted,
        star: AteColor.coral,
        shimmers: false
    )

    private var shimmering: ScoreStyle { ScoreStyle(fill: fill, ink: ink, star: star, shimmers: true) }

    /// Which exploration option this launch shows.
    enum Option: String {
        case current = "current"
        case colour = "A"
        case shimmer = "B"
        case both = "C"

        static let launched: Option = {
            #if DEBUG
            // `-ate-perfect-style B` lands in the argument domain of the standard defaults.
            if let raw = UserDefaults.standard.string(forKey: "ate-perfect-style"),
               let option = Option(rawValue: raw.uppercased()) {
                return option
            }
            #endif
            return .current
        }()
    }
}
