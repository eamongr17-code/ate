import Foundation

/// The rating gesture's mapping from a finger position to a score (§2.2), and nothing else.
///
/// Pulled out of the view because it is the only part of the gesture that can be *wrong* in a way a
/// screenshot won't show: the zone arithmetic decides whether the leading edge of the track means
/// 0.5 or 1.0, whether the trailing pixel is reachable as 5.0, and whether a tap and a drag agree.
/// All three are asserted in `RatingTrackTests`.
public enum RatingTrack {
    /// Ten equal zones — one per half-step. There is no zero zone: an unrated card is a *state*, not
    /// a score of nothing (§2.2, and the `reviews_score_halfstep` CHECK).
    public static let zoneCount = 10

    /// The score for a touch at `x` points from the track's leading edge.
    ///
    /// `ceil` rather than `round`: it makes each zone the region you must have *entered*, so the
    /// score under the thumb is the one the finger has crossed into — which is what makes a slow
    /// scrub feel 1:1. Everything left of the track (the 24pt leading slop, §2.1) is 0.5; everything
    /// right of it is 5.0.
    public static func rating(atX position: Double, trackWidth: Double) -> Rating {
        guard trackWidth > 0 else { return .minimum }
        let fraction = position / trackWidth
        let zone = (fraction * Double(zoneCount)).rounded(.up)
        let halfSteps = Int(min(Double(zoneCount), max(1, zone)))
        return Rating(rounding: Double(halfSteps) / 2)
    }

    /// Centre of the zone a score occupies, for drawing a thumb or scrolling a value into view.
    public static func x(for rating: Rating, trackWidth: Double) -> Double {
        (Double(rating.halfSteps) - 0.5) / Double(zoneCount) * trackWidth
    }

    // MARK: - Axis lock

    /// What the first few points of a touch on the track turned out to mean.
    public enum ScrubIntent: Sendable, Hashable {
        /// Too little movement to tell yet — commit to nothing.
        case undecided
        /// Horizontal: this is a rating scrub and the enclosing list must not scroll.
        case scrub
        /// Vertical: the person is scrolling the sitting, and the rating must not move.
        case scroll
    }

    /// Points of movement before the axis is called.
    ///
    /// Deliberately *smaller* than `UIScrollView`'s own pan slop (~10 pt): the decision has to be
    /// made before the list can claim the touch, or the scroll view wins every ambiguous drag and
    /// the scrub dies mid-gesture. Small enough to be imperceptible at the start of a scrub.
    public static let axisLockSlop: Double = 4

    /// The axis lock (device lesson): a real thumb on a card inside a scrolling list is never
    /// perfectly horizontal, so "any movement = scrub" both fights the list and repaints the score
    /// when someone was only trying to scroll past the card.
    ///
    /// A perfect diagonal resolves to ``ScrubIntent/scroll``: giving an ambiguous drag to the list
    /// costs a scroll the person can repeat, while giving it to the track silently rewrites a score.
    public static func intent(dx: Double, dy: Double, slop: Double = axisLockSlop) -> ScrubIntent {
        guard max(abs(dx), abs(dy)) >= slop else { return .undecided }
        return abs(dx) > abs(dy) ? .scrub : .scroll
    }

    /// VoiceOver's `.accessibilityAdjustableAction` (§2.5): ±0.5, clamped, and an unset control
    /// starts at 0.5 on increment rather than jumping to the middle.
    public static func adjusted(_ rating: Rating?, by steps: Int) -> Rating {
        guard let rating else { return .minimum }
        let halfSteps = min(zoneCount, max(1, rating.halfSteps + steps))
        return Rating(rounding: Double(halfSteps) / 2)
    }

    /// The VoiceOver value string: "4 and a half out of 5" / "Not rated" (§2.5). Spoken, so it spells
    /// the half out instead of reading "four point five".
    public static func accessibilityValue(_ rating: Rating?) -> String {
        guard let rating else { return "Not rated" }
        let whole = rating.filledStars
        if rating.hasHalfStar {
            return whole == 0 ? "Half a star out of 5" : "\(whole) and a half out of 5"
        }
        return "\(whole) out of 5"
    }
}
