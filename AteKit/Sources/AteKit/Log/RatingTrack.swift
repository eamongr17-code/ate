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
