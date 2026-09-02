import Foundation

/// How a derived average is written down. Lives here, not in a view, because the one rule that
/// matters is a *data* rule: `nil` is the unrated ("want-to-try") state and must never be rendered
/// as `0.0` (data-model §1.3). A view that formats its own score can quietly break that; a view
/// that asks this type cannot.
public enum ScoreFormat {
    /// What an unrated aggregate reads as. An em-dash, not a zero, not "N/A".
    public static let unratedPlaceholder = "–"

    /// The bare average: `"4.3"`, or the placeholder when unrated.
    public static func average(_ score: Double?) -> String {
        guard let score else { return unratedPlaceholder }
        return score.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// A single half-step rating, always one decimal: `"4.0"`, `"4.5"`. Unlike ``average``, a
    /// rating never has a fraction to drop, and a live readout must not change width between
    /// `4` and `4.5` under the finger.
    public static func halfStep(_ score: Double?) -> String {
        guard let score else { return unratedPlaceholder }
        return score.formatted(.number.precision(.fractionLength(1)))
    }

    /// The average with its scale: `"4.3/5"` or `"–/5"`.
    public static func outOfFive(_ score: Double?) -> String {
        "\(average(score))/5"
    }

    /// Review-count line for a header. Unrated dishes get the invitation, not "0 reviews".
    public static func reviewCount(_ count: Int) -> String {
        switch count {
        case ..<1: "No reviews yet"
        case 1: "1 review"
        default: "\(count) reviews"
        }
    }

    /// Whole and half stars for an *average* (which lands anywhere, e.g. 4.3 → 4 full + 1 half).
    /// ``Rating`` answers this for a single review; an average is not a `Rating`.
    ///
    /// Rounds to the nearest half star, exactly like the rating gesture snaps.
    public static func stars(for score: Double?) -> (full: Int, half: Bool) {
        guard let score, score > 0 else { return (0, false) }
        let halfSteps = min(10, max(0, Int((score * 2).rounded())))
        return (halfSteps / 2, !halfSteps.isMultiple(of: 2))
    }
}
