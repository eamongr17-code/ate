import Foundation

/// **A dish's reviews, bundled by stars** (Eamon, 6 Oct: "it shouldn't list every review, it should
/// bundle 5 star ratings, 4 star ratings etc."). One band per whole star, best first: the secret 6,
/// then 5 down to 1, then the reviews that gave no number. A half lands in the star below it (a 4.5
/// is one of the 4s), and every review keeps its own exact score inside the band — the band is a
/// heading, never a rounded score. The viewer's own review is not banded: it stays on its own, first.
public struct DishReviewBand: Sendable, Hashable, Identifiable {
    /// `6`, `5`…`1`, or `nil` for no number.
    public let stars: Int?
    /// In the order the page holds them (newest first).
    public let reviews: [DishReview]

    public var id: Int { stars ?? 0 }

    /// "5 stars", "1 star", "No score".
    public var title: String {
        guard let stars else { return "No score" }
        return stars == 1 ? "1 star" : "\(stars) stars"
    }

    /// "1 person", "12 people".
    public var countLine: String {
        reviews.count == 1 ? "1 person" : "\(reviews.count) people"
    }

    public init(stars: Int?, reviews: [DishReview]) {
        self.stars = stars
        self.reviews = reviews
    }

    /// The band a score belongs in.
    public static func stars(for rating: Rating?) -> Int? {
        guard let rating else { return nil }
        return max(1, rating.halfSteps / 2)
    }

    /// Everyone else's reviews in their bands, best first, unscored last. Empty bands are left out.
    public static func bands(_ reviews: [DishReview]) -> [DishReviewBand] {
        let others = reviews.filter { $0.isMine == false }
        let grouped = Dictionary(grouping: others) { stars(for: $0.score) }
        return grouped.keys
            .sorted { ($0 ?? 0) > ($1 ?? 0) }
            .map { DishReviewBand(stars: $0, reviews: grouped[$0] ?? []) }
    }
}
