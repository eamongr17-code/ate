import Foundation

@testable import AteKit

// The reads behind the v1 feed, diary and detail screens. No screen calls them any more; they live
// here only because `StagingContractTests` and `DetailContractTests` still exercise them. Delete this
// file with those tests.

/// The v1 global feed: every review, newest first, keyset-paginated. Signed-out reads throw rather
/// than return the empty page RLS hands `anon`.
struct GlobalFeedClient {
    let api: AteAPIClient

    func feedPage(_ request: PageRequest = PageRequest()) async throws -> Page<FeedEntry> {
        try await api.requireCurrentUserID()
        return try await api.page(FeedEntry.self, request: request)
    }
}

/// The v1 diary: the signed-in person's own reviews, newest first.
struct DiaryClient {
    let api: AteAPIClient

    func diaryPage(_ request: PageRequest = PageRequest()) async throws -> Page<FeedEntry> {
        let reviewerID = try await api.requireCurrentUserID().uuidString.lowercased()
        return try await api.page(FeedEntry.self, request: request) { query in
            query.eq("reviewer_id", value: reviewerID)
        }
    }
}

/// The v1 dish and restaurant detail reads.
struct AteDetailClient {
    struct DishSnapshot {
        let dish: Dish
        let restaurant: Restaurant
        let stats: DishStats?
        let requestedDishID: UUID

        var wasRedirected: Bool { requestedDishID != dish.id }
        var score: Double? { stats?.score }
        var isRated: Bool { score != nil }
    }

    struct RankedDish {
        let dish: Dish
        let stats: DishStats?

        var id: UUID { dish.id }
        var score: Double? { stats?.score }
        var isRated: Bool { score != nil }
        var menuRow: MenuDish {
            MenuDish(dishID: id, name: dish.name, score: score, reviewCount: stats?.reviewCount ?? 0)
        }
    }

    struct RestaurantSnapshot {
        let restaurant: Restaurant
        let stats: RestaurantStats?
        let dishes: [RankedDish]

        var avgRating: Double? { stats?.avgRating }
        var reviewCount: Int { stats?.reviewCount ?? 0 }
    }

    /// Merge hops a read follows before giving up; the visited set makes a cycle impossible to hang on.
    static let maximumMergeHops = 4
    static let dishListLimit = 200

    let api: AteAPIClient

    func dishDetail(id: UUID) async throws -> DishSnapshot {
        var dish = try await api.fetchByID(Dish.self, id: id)
        var visited: Set<UUID> = [dish.id]
        for _ in 0..<Self.maximumMergeHops {
            guard let successor = dish.mergedIntoDishID, !visited.contains(successor) else { break }
            dish = try await api.fetchByID(Dish.self, id: successor)
            visited.insert(dish.id)
        }
        let (dishID, restaurantID) = (dish.id, dish.restaurantID)
        async let restaurant = api.fetchByID(Restaurant.self, id: restaurantID)
        async let stats = api.findRow(DishStats.self) { $0.eq("dish_id", value: dishID.uuidString) }
        return DishSnapshot(dish: dish, restaurant: try await restaurant, stats: try await stats, requestedDishID: id)
    }

    func reviews(dishID: UUID, request: PageRequest) async throws -> Page<Review> {
        try await api.page(Review.self, request: request) { $0.eq("dish_id", value: dishID.uuidString) }
    }

    func authors(ids: [UUID]) async throws -> [User] {
        try await api.fetchByIDs(User.self, ids: ids)
    }

    /// The menu ranked by printed score (unscored last), then review count, then name.
    func restaurantDetail(id: UUID) async throws -> RestaurantSnapshot {
        async let restaurant = api.fetchByID(Restaurant.self, id: id)
        async let stats = api.findRow(RestaurantStats.self) { $0.eq("restaurant_id", value: id.uuidString) }
        async let dishes = api.fetchAll(Dish.self) {
            $0.eq("restaurant_id", value: id.uuidString)
                .is("merged_into_dish_id", value: nil)
                .limit(Self.dishListLimit)
        }
        async let dishStats = api.fetchAll(DishStats.self) {
            $0.eq("restaurant_id", value: id.uuidString).limit(Self.dishListLimit)
        }
        let statsByDish = Dictionary(
            try await dishStats.map { ($0.dishID, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let rows = try await dishes
            .filter { !$0.isTombstoned }
            .map { RankedDish(dish: $0, stats: statsByDish[$0.id]) }
        return RestaurantSnapshot(
            restaurant: try await restaurant,
            stats: try await stats,
            dishes: rows.sorted { MenuDish.isRankedBefore($0.menuRow, $1.menuRow) }
        )
    }
}
