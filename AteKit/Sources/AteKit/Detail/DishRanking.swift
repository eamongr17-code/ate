import Foundation

/// A dish paired with its derived stats — what a restaurant's dish list is made of. The stats are
/// Optional because the join is client-side: a dish row with no `dish_stats` row (only possible for
/// a tombstoned dish, which the view excludes) is rendered unrated rather than dropped.
public struct RankedDish: Sendable, Hashable, Identifiable {
    public let dish: Dish
    public let stats: DishStats?

    public init(dish: Dish, stats: DishStats?) {
        self.dish = dish
        self.stats = stats
    }

    public var id: UUID { dish.id }
    public var name: String { dish.name }
    /// nil = unrated. Never coalesce to 0 (data-model §1.3).
    public var score: Double? { stats?.score }
    public var reviewCount: Int { stats?.reviewCount ?? 0 }
    public var isRated: Bool { score != nil }
    public var coverURL: URL? { stats?.coverURL ?? dish.photoURL }
}

/// The order a restaurant's dishes are listed in: **most-reviewed first, then best-rated**.
///
/// Reviews before score is deliberate — one 5.0 from one person must not outrank a 4.4 from twelve
/// people on the "what should I order here?" screen. Unrated dishes therefore sink to the bottom
/// naturally (review_count 0) rather than needing a special case, and a `nil` score never compares
/// as 0 — it sorts *after* every real score at the same review count.
public enum DishRanking {
    public static func rank(dishes: [Dish], stats: [DishStats]) -> [RankedDish] {
        let statsByDish = Dictionary(stats.map { ($0.dishID, $0) }, uniquingKeysWith: { first, _ in first })
        let joined = dishes
            .filter { !$0.isTombstoned }  // merged-away dishes are history, not menu
            .map { RankedDish(dish: $0, stats: statsByDish[$0.id]) }
        return joined.sorted(by: isOrderedBefore)
    }

    /// Total, deterministic order: review count desc → score desc (nil last) → name → id.
    /// The name/id tiebreaks exist so the list doesn't shuffle between refreshes.
    static func isOrderedBefore(_ lhs: RankedDish, _ rhs: RankedDish) -> Bool {
        if lhs.reviewCount != rhs.reviewCount { return lhs.reviewCount > rhs.reviewCount }
        switch (lhs.score, rhs.score) {
        case let (left?, right?) where left != right: return left > right
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
