import Foundation

/// How a derived average is written down. Lives here, not in a view, because the one rule that
/// matters is a *data* rule: `nil` is the unrated ("want-to-try") state and must never be rendered
/// as `0.0` (data-model §1.3). A view that formats its own score can quietly break that; a view
/// that asks this type cannot.
public enum ScoreFormat {
    /// What an unrated aggregate reads as. An em-dash, not a zero, not "N/A".
    public static let unratedPlaceholder = "–"

    /// The bare average: `"4.3"`, `"4.0"`, or the placeholder when unrated.
    ///
    /// **One decimal, always.** `docs/DESIGN.md`: "Scores print like prices: right-aligned, one
    /// decimal" — and a price column where one row reads `4` and the next reads `4.4` is not a
    /// column. The artboards print `4.0` and `5.0` for exactly this reason. (This used to drop the
    /// trailing `.0`; it shipped that way for one afternoon and read as a bug in the place page's
    /// menu, which is where the rule finally had to be obeyed rather than argued with.)
    ///
    /// **AGGREGATES ONLY**, still: a derived average can land anywhere (4.3), a single review's
    /// score is always a half-step. They now *render* the same for a whole number, but they mean
    /// different things and ``halfStep`` is the one to reach for when the number is one person's.
    public static func average(_ score: Double?) -> String {
        guard let score else { return unratedPlaceholder }
        return score.formatted(.number.precision(.fractionLength(1)))
    }

    /// A single half-step rating, always one decimal: `"4.0"`, `"4.5"`. A live readout must not
    /// change width between `4` and `4.5` under the finger.
    public static func halfStep(_ score: Double?) -> String {
        guard let score else { return unratedPlaceholder }
        return score.formatted(.number.precision(.fractionLength(1)))
    }

    /// **An entry's own average**, as a receipt foots it: two decimals, always — `"3.75"`,
    /// `"4.00"`.
    ///
    /// Two rather than ``average``'s one because this number is arithmetic the reader can check
    /// against the lines directly above it. `4.5 + 3.0 + 4.0` over three dishes is `3.8333…`, and a
    /// receipt that rounds its own sum to `3.8` invites exactly the "that is not what those add up
    /// to" double-take a printed total must never cause. A community aggregate over dozens of
    /// reviews has no such audit trail, which is why it keeps one decimal.
    ///
    /// Unscored lines are not zeros and are not counted — the caller passes the mean of the scored
    /// ones, or `nil`.
    /// A TOTAL of stars ("Stars handed out 57.5", "… 86"): a quantity, not a score, so a whole
    /// number keeps no decimal — only the halves show theirs.
    public static func starsTotal(_ stars: Double) -> String {
        stars.formatted(.number.precision(.fractionLength(0...1)))
    }

    public static func entryAverage(_ score: Double?) -> String {
        guard let score else { return unratedPlaceholder }
        return score.formatted(.number.precision(.fractionLength(2)))
    }

    /// The average with its scale: `"4.3/5"`, `"5.0/5"`, or `"–/5"`.
    public static func outOfFive(_ score: Double?) -> String {
        "\(average(score))/5"
    }

    /// How many dishes sit at a score — the Ratings screen's own count line ("36 dishes"). Singular
    /// at one, because "1 dishes" is how a screen tells you nobody read it.
    public static func dishCount(_ count: Int) -> String {
        count == 1 ? "1 dish" : "\(max(0, count)) dishes"
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
