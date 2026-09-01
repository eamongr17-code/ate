import Foundation

@testable import AteKit

/// An in-memory catalogue standing in for PostgREST, so the detail models can be tested without a
/// network — including the two things staging can't show us: a live merge tombstone, and a review
/// list long enough to page more than once.
///
/// It implements keyset paging *for real* (sort by `(created_at, id)` desc, cut strictly after the
/// cursor) rather than slicing by index, because index-slicing would pass even if the model threaded
/// the cursor wrongly.
actor FakeDetailDataSource: DetailDataSource {
    struct Failure: Error, Equatable {
        let message: String
    }

    var dishes: [UUID: Dish] = [:]
    var restaurants: [UUID: Restaurant] = [:]
    var dishStats: [UUID: DishStats] = [:]
    var restaurantStats: [UUID: RestaurantStats] = [:]
    var reviews: [Review] = []
    var users: [UUID: User] = [:]

    /// Fail the next N `reviews(dishID:request:)` calls — the "page 2 fell over" case.
    var reviewFailures = 0
    var dishDetailFailure: Failure?

    /// Every dish id a header read touched, in order: the tombstone-hop trace.
    private(set) var dishFetches: [UUID] = []
    /// Every reviews page request, so a test can assert what the cursor asked for.
    private(set) var reviewRequests: [(dishID: UUID, cursor: PageCursor?)] = []
    private(set) var authorFetches: [[UUID]] = []

    init() {}

    // MARK: - Seeding

    func insert(dish: Dish, stats: DishStats? = nil) {
        dishes[dish.id] = dish
        if let stats { dishStats[dish.id] = stats }
    }

    func insert(restaurant: Restaurant, stats: RestaurantStats? = nil) {
        restaurants[restaurant.id] = restaurant
        if let stats { restaurantStats[restaurant.id] = stats }
    }

    func insert(reviews newReviews: [Review]) {
        reviews.append(contentsOf: newReviews)
    }

    func insert(user: User) {
        users[user.id] = user
    }

    func setReviewFailures(_ count: Int) {
        reviewFailures = count
    }

    func setDishDetailFailure(_ failure: Failure?) {
        dishDetailFailure = failure
    }

    // MARK: - DetailDataSource

    func dishDetail(id: UUID) async throws -> DishDetailSnapshot {
        if let dishDetailFailure { throw dishDetailFailure }

        var dish = try require(dishes[id], "dish \(id)")
        dishFetches.append(id)
        var visited: Set<UUID> = [dish.id]
        for _ in 0..<AteDetailClient.maximumMergeHops {
            guard let successor = dish.mergedIntoDishID, !visited.contains(successor) else { break }
            dish = try require(dishes[successor], "dish \(successor)")
            dishFetches.append(successor)
            visited.insert(dish.id)
        }

        return DishDetailSnapshot(
            dish: dish,
            restaurant: try require(restaurants[dish.restaurantID], "restaurant \(dish.restaurantID)"),
            stats: dishStats[dish.id],
            requestedDishID: id
        )
    }

    func reviews(dishID: UUID, request: PageRequest) async throws -> Page<Review> {
        reviewRequests.append((dishID, request.cursor))
        if reviewFailures > 0 {
            reviewFailures -= 1
            throw Failure(message: "reviews unavailable")
        }

        let ordered = reviews
            .filter { $0.dishID == dishID }
            .sorted { isNewer($0, than: $1) }

        let page = ordered
            .drop { row in
                guard let cursor = request.cursor else { return false }
                // Keep only rows strictly older than the cursor, in (created_at, id) desc order.
                return !isOlder(row, than: cursor)
            }
            .prefix(request.limit)

        return Page(items: Array(page), requestedLimit: request.limit)
    }

    func authors(ids: [UUID]) async throws -> [User] {
        authorFetches.append(ids)
        return ids.compactMap { users[$0] }
    }

    func restaurantDetail(id: UUID) async throws -> RestaurantDetailSnapshot {
        let restaurant = try require(restaurants[id], "restaurant \(id)")
        let menu = dishes.values.filter { $0.restaurantID == id }
        let stats = menu.compactMap { dishStats[$0.id] }
        return RestaurantDetailSnapshot(
            restaurant: restaurant,
            stats: restaurantStats[id],
            dishes: DishRanking.rank(dishes: Array(menu), stats: stats)
        )
    }

    // MARK: - Helpers

    private func require<Value>(_ value: Value?, _ what: String) throws -> Value {
        guard let value else { throw Failure(message: "missing \(what)") }
        return value
    }

    private func isNewer(_ lhs: Review, than rhs: Review) -> Bool {
        lhs.createdAt == rhs.createdAt
            ? lhs.id.uuidString > rhs.id.uuidString
            : lhs.createdAt > rhs.createdAt
    }

    private func isOlder(_ review: Review, than cursor: PageCursor) -> Bool {
        review.createdAt == cursor.createdAt
            ? review.id.uuidString < cursor.id.uuidString
            : review.createdAt < cursor.createdAt
    }
}

/// Deterministic rows. Ids are readable (`dish-1`, `rest-1`) so a failure message points at
/// something, and timestamps step by whole minutes so paging order is unambiguous.
enum DetailFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_756_000_000)

    static func id(_ seed: String) -> UUID {
        var bytes = Array(seed.utf8.prefix(16))
        bytes.append(contentsOf: Array(repeating: UInt8(0), count: 16 - bytes.count))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func restaurant(_ seed: String = "rest-1", name: String = "Tipo 00", city: String = "Melbourne") -> Restaurant {
        Restaurant(
            id: id(seed),
            source: .places,
            googlePlaceID: "place_\(seed)",
            name: name,
            address: "361 Little Bourke St",
            city: city,
            cuisine: "Italian",
            createdAt: epoch
        )
    }

    static func dish(
        _ seed: String = "dish-1",
        name: String = "Tagliolini",
        restaurant: UUID = id("rest-1"),
        mergedInto: UUID? = nil
    ) -> Dish {
        Dish(
            id: id(seed),
            name: name,
            restaurantID: restaurant,
            mergedIntoDishID: mergedInto,
            createdAt: epoch
        )
    }

    static func dishStats(
        _ seed: String = "dish-1",
        restaurant: UUID = id("rest-1"),
        score: Double?,
        reviewCount: Int
    ) -> DishStats {
        DishStats(dishID: id(seed), restaurantID: restaurant, score: score, reviewCount: reviewCount)
    }

    static func restaurantStats(_ seed: String = "rest-1", avgRating: Double?, reviewCount: Int) -> RestaurantStats {
        RestaurantStats(restaurantID: id(seed), avgRating: avgRating, reviewCount: reviewCount)
    }

    static func user(_ seed: String = "user-1", username: String = "eamon") -> User {
        User(id: id(seed), username: username, name: username.capitalized, createdAt: epoch)
    }

    /// `count` reviews for one dish, newest first, one minute apart.
    static func reviews(
        count: Int,
        dish: UUID = id("dish-1"),
        restaurant: UUID = id("rest-1"),
        reviewer: UUID = id("user-1"),
        score: Double = 4.5
    ) -> [Review] {
        (0..<count).map { index in
            let created = epoch.addingTimeInterval(TimeInterval(-60 * index))
            return Review(
                id: id("review-\(String(format: "%03d", index))"),
                reviewerID: reviewer,
                dishID: dish,
                restaurantID: restaurant,
                score: Rating(rounding: score),
                note: "note \(index)",
                createdAt: created,
                updatedAt: created
            )
        }
    }
}
