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

/// Anything the "what to order" order can be applied to. Two rows arrive at that question by
/// different roads — a client-side join (``RankedDish``) and the `place_dishes` RPC
/// (``PlaceDish``) — and they must come out in the same order, so the comparator is written once
/// against what both actually have.
public protocol DishRankable: Identifiable, Sendable where ID == UUID {
    /// The menu's spelling. A tiebreak only; it is never an identifier.
    var name: String { get }
    /// `nil` = unrated. Never coalesce to 0 (data-model §1.3).
    var score: Double? { get }
    var reviewCount: Int { get }
}

extension RankedDish: DishRankable {}

/// The order a restaurant's dishes are listed in: **by rating** (0051 — Eamon, build 81: the list
/// reads top-down by the number it prints).
///
/// 1. The **printed** score, one decimal, highest first — two rows that read "4.6" tie, never split
///    by a hidden third decimal; a 6 sits above every 5.
/// 2. Of two equal scores, the one ordered more times (review count) first — the surer bet.
/// 3. Then name, case-insensitive, then id, so nothing shuffles between refreshes.
///
/// Unscored dishes (logged, never given a number) come after every scored one, ordered the same way
/// among themselves — a `nil` is never compared as 0. Accepted consequence: a single 5.0 leads a
/// menu of 4.5s.
///
/// **The server owns the menu's order.** `place_dishes` returns this very order (0051), and the
/// place page shows it as it arrives — it never re-sorts (``PlacePageStore``). This type is the rule
/// written down: the in-memory stand-in sorts with it, and the tests pin it.
public enum DishRanking {
    public static func rank(dishes: [Dish], stats: [DishStats]) -> [RankedDish] {
        let statsByDish = Dictionary(stats.map { ($0.dishID, $0) }, uniquingKeysWith: { first, _ in first })
        let joined = dishes
            .filter { !$0.isTombstoned }  // merged-away dishes are history, not menu
            .map { RankedDish(dish: $0, stats: statsByDish[$0.id]) }
        return joined.sorted(by: isOrderedBefore)
    }

    /// The same order, applied to rows that arrive already joined — `place_dishes`.
    public static func rank<D: DishRankable>(_ dishes: [D]) -> [D] {
        dishes.sorted(by: isOrderedBefore)
    }

    /// Total, deterministic order: printed score desc (unscored last) → review count desc → name → id.
    static func isOrderedBefore<D: DishRankable>(_ lhs: D, _ rhs: D) -> Bool {
        switch (lhs.score.map(printed), rhs.score.map(printed)) {
        case let (left?, right?) where left != right: return left > right
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if lhs.reviewCount != rhs.reviewCount { return lhs.reviewCount > rhs.reviewCount }
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// The score as the row prints it: one decimal, in tenths so equal prints compare equal.
    private static func printed(_ score: Double) -> Int {
        Int((score * 10).rounded())
    }
}
