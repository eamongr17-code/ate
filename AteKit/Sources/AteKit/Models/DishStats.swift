import Foundation

/// Derived per-dish aggregates (`public.dish_stats` view, migrations 0005 + 0009).
///
/// **The null trap:** `score` is `NULL` for a dish nobody has reviewed. That is a *product state*
/// ("want-to-try", rendered `?/5`), not missing data — so it is `Optional` here and must never be
/// coalesced to `0`. A 0 would be both a lie and unrepresentable as a ``Rating``. Null-score dishes
/// are likewise excluded from a restaurant's average.
///
/// The view already excludes tombstoned dishes (`merged_into_dish_id IS NULL`), so every row here
/// is a live catalogue dish.
public struct DishStats: AteRecord, Hashable {
    public static let table = "dish_stats"
    public static let columns = "dish_id,restaurant_id,score,review_count,cover_url"
    public static let primaryKeyColumn = "dish_id"

    public let dishID: UUID
    public let restaurantID: UUID
    /// Mean of this dish's review scores to 1dp — **nil when unrated**. Not a ``Rating``: an
    /// average lands anywhere (4.3), not on half-steps.
    public let score: Double?
    public let reviewCount: Int
    /// Live-derived (IMG-1): the photo of the most-recent photo'd review of this dish, any user.
    /// Distinct from the stored `dishes.photo_url`, which is effectively always null.
    public let coverURLString: String?

    public var id: UUID { dishID }

    public init(
        dishID: UUID,
        restaurantID: UUID,
        score: Double?,
        reviewCount: Int,
        coverURLString: String? = nil
    ) {
        self.dishID = dishID
        self.restaurantID = restaurantID
        self.score = score
        self.reviewCount = reviewCount
        self.coverURLString = coverURLString
    }

    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }

    /// False = the `?/5` want-to-try state, not "zero stars".
    public var isRated: Bool { score != nil }

    private enum CodingKeys: String, CodingKey {
        case dishID = "dish_id"
        case restaurantID = "restaurant_id"
        case score
        case reviewCount = "review_count"
        case coverURLString = "cover_url"
    }
}
