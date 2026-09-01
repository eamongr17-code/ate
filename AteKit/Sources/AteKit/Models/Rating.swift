import Foundation

/// A review score: half-steps from 0.5 to 5.0 (data-model §4).
///
/// The DB enforces exactly this with `reviews_score_halfstep` — `score >= 0.5 AND score <= 5.0 AND
/// score * 2 = floor(score * 2)`. Making it a type means the rating gesture can only ever produce a
/// value the server will accept; there is no "0 stars" state on a posted review (an *unrated dish*
/// is `DishStats.score == nil`, which is a different thing entirely).
public struct Rating: Sendable, Hashable, Comparable, Codable {
    /// Smallest postable score. There is no zero — posting requires a rating.
    public static let minimum = Rating(halfSteps: 1)
    public static let maximum = Rating(halfSteps: 10)

    /// The score in half-star units, 1…10. Integer storage keeps comparison and stepping exact.
    public let halfSteps: Int

    private init(halfSteps: Int) {
        self.halfSteps = halfSteps
    }

    /// Exact construction — fails for anything the server's CHECK would reject.
    public init?(exactly value: Double) {
        let doubled = value * 2
        guard doubled.rounded() == doubled, (1...10).contains(Int(doubled)) else { return nil }
        self.init(halfSteps: Int(doubled))
    }

    /// Snapping construction for the rating gesture: rounds to the nearest half-step and clamps
    /// into 0.5…5.0. A drag can't produce an unpostable score.
    public init(rounding value: Double) {
        let snapped = (value * 2).rounded()
        self.init(halfSteps: min(10, max(1, Int(snapped.isFinite ? snapped : 1))))
    }

    public var value: Double { Double(halfSteps) / 2 }

    /// Whole stars filled, and whether the next one is a half — the two numbers a star row needs.
    public var filledStars: Int { halfSteps / 2 }
    public var hasHalfStar: Bool { halfSteps.isMultiple(of: 2) == false }

    public static func < (lhs: Rating, rhs: Rating) -> Bool { lhs.halfSteps < rhs.halfSteps }

    /// Codes as the bare number the `reviews.score` column holds.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Double.self)
        guard let rating = Rating(exactly: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "score \(raw) is not a half-step in 0.5…5.0"
            )
        }
        self = rating
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
