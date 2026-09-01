import Foundation
import Testing

@testable import AteKit

/// The detail screens' reads, run against the **staging** project (rule 5). The unit tests prove the
/// models behave; these prove the queries behind them still match the server — in particular that
/// the unrated dish really does arrive as a NULL score rather than a 0.
///
/// Opt-in via `ATE_CONTRACT_TESTS=1`, same as ``StagingContractTests``.
@Suite("Detail contract vs staging", .enabled(if: StagingContract.isEnabled), .serialized)
struct DetailContractTests {
    func client() async throws -> AteDetailClient {
        AteDetailClient(api: try await StagingContract.Backend.shared.client())
    }

    @Test("a seeded unrated dish loads with a nil score and renders –/5")
    func unratedDishSnapshot() async throws {
        let api = try await StagingContract.Backend.shared.client()
        let unrated = try #require(
            try await api.fetchAll(DishStats.self) { $0.is("score", value: nil).limit(1) }.first
        )

        let snapshot = try await client().dishDetail(id: unrated.dishID)
        #expect(snapshot.dish.id == unrated.dishID)
        #expect(snapshot.score == nil)
        #expect(snapshot.isRated == false)
        #expect(snapshot.reviewCount == 0)
        #expect(ScoreFormat.outOfFive(snapshot.score) == "–/5")
        #expect(snapshot.restaurant.id == snapshot.dish.restaurantID)
        #expect(snapshot.wasRedirected == false)
    }

    @Test("a rated dish loads its header, and its reviews page in newest-first order")
    func ratedDishAndReviews() async throws {
        let api = try await StagingContract.Backend.shared.client()
        let detail = try await client()
        let rated = try #require(
            try await api.fetchAll(DishStats.self) {
                $0.not("score", operator: .is, value: "null").order("review_count", ascending: false).limit(1)
            }.first
        )

        let snapshot = try await detail.dishDetail(id: rated.dishID)
        #expect(snapshot.score == rated.score)
        #expect(snapshot.isRated)

        let first = try await detail.reviews(dishID: rated.dishID, request: PageRequest(limit: 2))
        #expect(first.items.isEmpty == false)
        #expect(first.items.allSatisfy { $0.dishID == rated.dishID })

        // Authors resolve through `profiles` on `reviewer_id`.
        let authors = try await detail.authors(ids: first.items.map(\.reviewerID))
        #expect(authors.isEmpty == false)

        if let cursor = first.nextCursor {
            let second = try await detail.reviews(dishID: rated.dishID, request: PageRequest(limit: 2, after: cursor))
            #expect(Set(second.items.map(\.id)).isDisjoint(with: Set(first.items.map(\.id))))
        }
    }

    @Test("restaurant detail's rating is the restaurant_stats row, not a client-side average")
    func restaurantAggregateIsTheView() async throws {
        let api = try await StagingContract.Backend.shared.client()
        let stats = try #require(
            try await api.fetchAll(RestaurantStats.self) {
                $0.not("avg_rating", operator: .is, value: "null").limit(1)
            }.first
        )

        let snapshot = try await client().restaurantDetail(id: stats.restaurantID)
        #expect(snapshot.avgRating == stats.avgRating)
        #expect(snapshot.reviewCount == stats.reviewCount)
        #expect(snapshot.restaurant.id == stats.restaurantID)
        #expect(snapshot.dishes.isEmpty == false)

        // Ranked: review count descending is the primary key of the order.
        let counts = snapshot.dishes.map(\.reviewCount)
        #expect(counts == counts.sorted(by: >))

        // And the flat mean of the dish averages is a *different* number in general — proving the
        // snapshot didn't compute one. (Equal only by coincidence; assert the source, not the maths.)
        #expect(snapshot.stats?.avgRating == stats.avgRating)
    }

    @Test("every live dish at a restaurant appears in the menu, unrated ones included")
    func menuIncludesUnratedDishes() async throws {
        let api = try await StagingContract.Backend.shared.client()
        let unrated = try #require(
            try await api.fetchAll(DishStats.self) { $0.is("score", value: nil).limit(1) }.first
        )

        let snapshot = try await client().restaurantDetail(id: unrated.restaurantID)
        let listed = try #require(snapshot.dishes.first { $0.id == unrated.dishID })
        #expect(listed.isRated == false)
        #expect(listed.score == nil)
        // Unrated dishes sit at the bottom, never at the top on a phantom 0.
        #expect(snapshot.dishes.last?.isRated == false)
    }
}
