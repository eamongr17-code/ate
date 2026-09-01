import Foundation

/// Derived per-restaurant aggregates (`public.restaurant_stats` view, migrations 0005 + 0009).
///
/// **The rating is the mean of per-dish averages** (data-model §1.2), not the mean of all reviews —
/// each dish counts once, unrated dishes are excluded. Don't recompute it client-side from a page
/// of reviews; that gives a different, wrong number.
///
/// `avgRating` is `nil` when the restaurant has no rated dish — again never `0`.
public struct RestaurantStats: AteRecord, Hashable {
    public static let table = "restaurant_stats"
    public static let columns = "restaurant_id,avg_rating,review_count,cover_url"
    public static let primaryKeyColumn = "restaurant_id"

    public let restaurantID: UUID
    /// Mean of the per-dish averages to 1dp — nil when nothing here is rated yet.
    public let avgRating: Double?
    /// Total reviews across the restaurant (all dishes).
    public let reviewCount: Int
    /// Live-derived (IMG-1): the photo of the most-recent photo'd review at this restaurant, any
    /// dish, any user. Prefer this over the stored `restaurants.cover_url`.
    public let coverURLString: String?

    public var id: UUID { restaurantID }

    public init(
        restaurantID: UUID,
        avgRating: Double?,
        reviewCount: Int,
        coverURLString: String? = nil
    ) {
        self.restaurantID = restaurantID
        self.avgRating = avgRating
        self.reviewCount = reviewCount
        self.coverURLString = coverURLString
    }

    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }

    public var isRated: Bool { avgRating != nil }

    private enum CodingKeys: String, CodingKey {
        case restaurantID = "restaurant_id"
        case avgRating = "avg_rating"
        case reviewCount = "review_count"
        case coverURLString = "cover_url"
    }
}
