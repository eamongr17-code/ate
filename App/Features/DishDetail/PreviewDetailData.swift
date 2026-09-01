#if DEBUG
import AteKit
import Foundation

/// Fixtures for the detail previews — including the two states staging can't reliably show on
/// demand: a dish with `dish_stats.score IS NULL`, and a live merge tombstone.
///
/// DEBUG-only so it can't be reached from a Release build, and immutable so it satisfies
/// `DetailDataSource`'s `Sendable` requirement without any locking.
enum PreviewDetailData {
    static let restaurantID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let unratedRestaurantID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let ratedDishID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let unratedDishID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let tombstonedDishID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    static let dataSource: any DetailDataSource = PreviewDetailDataSource()
}

struct PreviewDetailDataSource: DetailDataSource {
    private static let now = Date()
    private static let author = User(
        id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
        username: "eamon",
        name: "Eamon",
        createdAt: now
    )

    private static let restaurant = Restaurant(
        id: PreviewDetailData.restaurantID,
        source: .places,
        googlePlaceID: "preview_place",
        name: "Tipo 00",
        address: "361 Little Bourke St",
        city: "Melbourne",
        cuisine: "Italian",
        createdAt: now
    )

    private static let unratedRestaurant = Restaurant(
        id: PreviewDetailData.unratedRestaurantID,
        source: .manual,
        googlePlaceID: nil,
        name: "The New Place",
        address: nil,
        city: "Fitzroy",
        createdAt: now
    )

    private static func dish(_ id: UUID, _ name: String, mergedInto: UUID? = nil) -> Dish {
        Dish(id: id, name: name, restaurantID: restaurant.id, mergedIntoDishID: mergedInto, createdAt: now)
    }

    func dishDetail(id: UUID) async throws -> DishDetailSnapshot {
        switch id {
        case PreviewDetailData.unratedDishID:
            return DishDetailSnapshot(
                dish: Self.dish(id, "Sicilian cannoli"),
                restaurant: Self.restaurant,
                stats: DishStats(dishID: id, restaurantID: Self.restaurant.id, score: nil, reviewCount: 0)
            )
        case PreviewDetailData.tombstonedDishID:
            // Redirected: the requested id is a tombstone, the survivor is what's shown.
            return DishDetailSnapshot(
                dish: Self.dish(PreviewDetailData.ratedDishID, "Tagliolini"),
                restaurant: Self.restaurant,
                stats: DishStats(
                    dishID: PreviewDetailData.ratedDishID,
                    restaurantID: Self.restaurant.id,
                    score: 4.6,
                    reviewCount: 12
                ),
                requestedDishID: id
            )
        default:
            return DishDetailSnapshot(
                dish: Self.dish(PreviewDetailData.ratedDishID, "Tagliolini"),
                restaurant: Self.restaurant,
                stats: DishStats(
                    dishID: PreviewDetailData.ratedDishID,
                    restaurantID: Self.restaurant.id,
                    score: 4.6,
                    reviewCount: 12
                )
            )
        }
    }

    func reviews(dishID: UUID, request: PageRequest) async throws -> Page<Review> {
        guard dishID == PreviewDetailData.ratedDishID else {
            return Page(items: [], nextCursor: nil)
        }
        let notes = [
            "Best pasta in the city. The butter sauce is absurd.",
            "Worth the queue. Ask for a seat at the pass.",
            "Good, not life-changing — the crab one is better."
        ]
        let items = notes.enumerated().map { index, note in
            Review(
                id: UUID(),
                reviewerID: Self.author.id,
                dishID: dishID,
                restaurantID: Self.restaurant.id,
                score: Rating(rounding: 5 - Double(index) * 0.5),
                note: note,
                createdAt: Self.now.addingTimeInterval(TimeInterval(-3600 * (index + 1))),
                updatedAt: Self.now
            )
        }
        return Page(items: items, nextCursor: nil)
    }

    func authors(ids: [UUID]) async throws -> [User] {
        ids.contains(Self.author.id) ? [Self.author] : []
    }

    func restaurantDetail(id: UUID) async throws -> RestaurantDetailSnapshot {
        if id == PreviewDetailData.unratedRestaurantID {
            let dish = Dish(
                id: PreviewDetailData.unratedDishID,
                name: "Everything, untried",
                restaurantID: id,
                createdAt: Self.now
            )
            return RestaurantDetailSnapshot(
                restaurant: Self.unratedRestaurant,
                stats: RestaurantStats(restaurantID: id, avgRating: nil, reviewCount: 0),
                dishes: [RankedDish(dish: dish, stats: DishStats(
                    dishID: dish.id, restaurantID: id, score: nil, reviewCount: 0
                ))]
            )
        }

        let menu: [(UUID, String, Double?, Int)] = [
            (PreviewDetailData.ratedDishID, "Tagliolini", 4.6, 12),
            (UUID(), "Ragù rigatoni", 4.9, 3),
            (PreviewDetailData.unratedDishID, "Sicilian cannoli", nil, 0)
        ]
        return RestaurantDetailSnapshot(
            restaurant: Self.restaurant,
            stats: RestaurantStats(restaurantID: id, avgRating: 4.8, reviewCount: 15),
            dishes: DishRanking.rank(
                dishes: menu.map { Self.dish($0.0, $0.1) },
                stats: menu.map {
                    DishStats(dishID: $0.0, restaurantID: id, score: $0.2, reviewCount: $0.3)
                }
            )
        )
    }
}
#endif
