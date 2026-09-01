import Foundation

/// One dish row in the picker (§11.3: *"dish name + ScoreMark trailing (avg + count; –/5 when null).
/// Own prior rating as caption 'you rated 4.0' in the history section"*).
public struct DishRowModel: Sendable, Hashable, Identifiable {
    /// **Canonical** id — a tombstone's `merged_into_dish_id`, never the tombstone itself (§6.3).
    public let dishID: UUID
    public let name: String
    public let restaurantID: UUID
    /// Only populated for the global Dishes scope, where the row has to say where the dish is.
    public let restaurantName: String?
    /// Community average. **nil is a real state** (unrated) and renders `–/5`, never `0`.
    public let score: Double?
    public let reviewCount: Int
    /// The viewer's own most recent rating of this dish here. Non-nil only in "You've had here".
    public let yourScore: Rating?
    /// When the viewer last logged it — orders the history section.
    public let yourLastReviewedAt: Date?

    public var id: UUID { dishID }

    public init(
        dishID: UUID,
        name: String,
        restaurantID: UUID,
        restaurantName: String? = nil,
        score: Double? = nil,
        reviewCount: Int = 0,
        yourScore: Rating? = nil,
        yourLastReviewedAt: Date? = nil
    ) {
        self.dishID = dishID
        self.name = name
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.score = score
        self.reviewCount = reviewCount
        self.yourScore = yourScore
        self.yourLastReviewedAt = yourLastReviewedAt
    }

    /// Builds a row from a dish plus its (optional) stats row. A dish with no `dish_stats` row is
    /// unrated, not zero-rated.
    public init(
        dish: Dish,
        stats: DishStats? = nil,
        restaurantName: String? = nil,
        yourScore: Rating? = nil,
        yourLastReviewedAt: Date? = nil
    ) {
        self.init(
            dishID: dish.canonicalDishID,
            name: dish.name,
            restaurantID: dish.restaurantID,
            restaurantName: restaurantName,
            score: stats?.score,
            reviewCount: stats?.reviewCount ?? 0,
            yourScore: yourScore,
            yourLastReviewedAt: yourLastReviewedAt
        )
    }

    public var isRated: Bool { score != nil }
}

/// The value ``SearchPicker`` hands back when a dish is picked.
public struct PickedDish: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let restaurantID: UUID
    /// True when this pick created the dish (drives `dish_create_fallback_used`).
    public let wasCreated: Bool

    public init(id: UUID, name: String, restaurantID: UUID, wasCreated: Bool = false) {
        self.id = id
        self.name = name
        self.restaurantID = restaurantID
        self.wasCreated = wasCreated
    }

    public init(_ dish: Dish, wasCreated: Bool = false) {
        self.init(
            id: dish.canonicalDishID,
            name: dish.name,
            restaurantID: dish.restaurantID,
            wasCreated: wasCreated
        )
    }
}

/// Pure ordering, dedup and merge rules for the dish picker. Every one of these is a behaviour the
/// spec names, kept out of the view so it can be asserted.
public enum DishSearchRanking {
    /// §11.3 "On the menu": `review_count desc, score desc`, then a total tiebreak so paging is
    /// deterministic.
    ///
    /// Unrated dishes sort **last within their review-count band**, not as zero — with a review
    /// count of 0 they are already at the bottom, and the nil-last rule keeps that honest if a
    /// stats row ever lands with a count but no score.
    public static func menuOrder(_ rows: [DishRowModel]) -> [DishRowModel] {
        rows.sorted { lhs, rhs in
            if lhs.reviewCount != rhs.reviewCount { return lhs.reviewCount > rhs.reviewCount }
            switch (lhs.score, rhs.score) {
            case (let l?, let r?) where l != r: return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            // Total, stable tiebreak: name, then id. Two dishes can't share a name here (the
            // identity index), but the global scope can, hence the id.
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.dishID.uuidString < rhs.dishID.uuidString
        }
    }

    /// §11.3 "You've had here": the viewer's prior reviews at this restaurant, most recent first,
    /// **deduped by dish** (one row per dish, keeping the most recent review), capped.
    ///
    /// `reviews` is expected newest-first (the keyset order), but the dedup does not rely on it.
    public static func historyDishIDs(from reviews: [Review], limit: Int = 5) -> [UUID] {
        var newest: [UUID: Date] = [:]
        for review in reviews {
            if let existing = newest[review.dishID], existing >= review.createdAt { continue }
            newest[review.dishID] = review.createdAt
        }
        return newest
            .sorted { lhs, rhs in
                lhs.value == rhs.value
                    ? lhs.key.uuidString > rhs.key.uuidString
                    : lhs.value > rhs.value
            }
            .prefix(limit)
            .map(\.key)
    }

    /// The viewer's most recent score per dish — the "you rated 4.0" caption.
    public static func latestOwnScores(from reviews: [Review]) -> [UUID: (score: Rating, at: Date)] {
        var latest: [UUID: (score: Rating, at: Date)] = [:]
        for review in reviews {
            if let existing = latest[review.dishID], existing.at >= review.createdAt { continue }
            latest[review.dishID] = (review.score, review.createdAt)
        }
        return latest
    }

    /// §11.3 (≥1 char): *"Filtered — flat list, your-history matches first, then catalogue."*
    ///
    /// The two inputs overlap (a dish you've had is also on the menu); history wins and the
    /// catalogue copy is dropped, so a dish never appears twice. Neither input is re-sorted —
    /// history stays recency-ordered, catalogue stays server-ranked.
    public static func flatten(history: [DishRowModel], catalogue: [DishRowModel]) -> [DishRowModel] {
        var seen = Set(history.map(\.dishID))
        var out = history
        for row in catalogue where seen.insert(row.dishID).inserted {
            out.append(row)
        }
        return out
    }
}
