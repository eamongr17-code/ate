import Foundation
import Testing

@testable import AteKit

@MainActor
@Suite("Restaurant detail model")
struct RestaurantDetailModelTests {

    @Test("the rating is read from restaurant_stats, never recomputed from the dish list")
    func aggregateComesFromTheView() async {
        // The stats row says 4.1 (the server's mean of per-dish averages). The dish list on screen
        // averages to 3.0. If the model ever computed its own number, this test breaks — which is
        // exactly the legacy client's bug (data-model §1.2).
        let source = FakeDetailDataSource()
        await source.insert(
            restaurant: DetailFixtures.restaurant(),
            stats: DetailFixtures.restaurantStats(avgRating: 4.1, reviewCount: 9)
        )
        await source.insert(
            dish: DetailFixtures.dish("dish-1", name: "A"),
            stats: DetailFixtures.dishStats("dish-1", score: 2.0, reviewCount: 6)
        )
        await source.insert(
            dish: DetailFixtures.dish("dish-2", name: "B"),
            stats: DetailFixtures.dishStats("dish-2", score: 4.0, reviewCount: 3)
        )

        let model = RestaurantDetailModel(restaurantID: DetailFixtures.id("rest-1"), dataSource: source)
        await model.load()

        #expect(model.state == .loaded)
        #expect(model.avgRating == 4.1)
        #expect(model.reviewCount == 9)
        #expect(ScoreFormat.outOfFive(model.avgRating) == "4.1/5")
    }

    @Test("a restaurant with nothing rated yet shows –/5, not 0.0")
    func unratedRestaurant() async {
        let source = FakeDetailDataSource()
        await source.insert(
            restaurant: DetailFixtures.restaurant(),
            stats: DetailFixtures.restaurantStats(avgRating: nil, reviewCount: 0)
        )
        await source.insert(
            dish: DetailFixtures.dish("dish-1", name: "Want to try"),
            stats: DetailFixtures.dishStats("dish-1", score: nil, reviewCount: 0)
        )

        let model = RestaurantDetailModel(restaurantID: DetailFixtures.id("rest-1"), dataSource: source)
        await model.load()

        #expect(model.avgRating == nil)
        #expect(model.isRated == false)
        #expect(ScoreFormat.outOfFive(model.avgRating) == "–/5")
        #expect(model.dishes.count == 1)
        #expect(model.dishes[0].isRated == false)
    }

    @Test("the dish list is ranked most-reviewed then best-rated")
    func dishListIsRanked() async {
        let source = FakeDetailDataSource()
        await source.insert(
            restaurant: DetailFixtures.restaurant(),
            stats: DetailFixtures.restaurantStats(avgRating: 4.3, reviewCount: 14)
        )
        await source.insert(
            dish: DetailFixtures.dish("dish-1", name: "One perfect review"),
            stats: DetailFixtures.dishStats("dish-1", score: 5.0, reviewCount: 1)
        )
        await source.insert(
            dish: DetailFixtures.dish("dish-2", name: "The house dish"),
            stats: DetailFixtures.dishStats("dish-2", score: 4.4, reviewCount: 12)
        )
        await source.insert(
            dish: DetailFixtures.dish("dish-3", name: "Nobody's tried it"),
            stats: DetailFixtures.dishStats("dish-3", score: nil, reviewCount: 0)
        )

        let model = RestaurantDetailModel(restaurantID: DetailFixtures.id("rest-1"), dataSource: source)
        await model.load()

        #expect(model.dishes.map(\.name) == ["The house dish", "One perfect review", "Nobody's tried it"])
    }

    @Test("an empty restaurant is an empty state, not a failure")
    func emptyRestaurant() async {
        let source = FakeDetailDataSource()
        await source.insert(restaurant: DetailFixtures.restaurant(), stats: nil)

        let model = RestaurantDetailModel(restaurantID: DetailFixtures.id("rest-1"), dataSource: source)
        await model.load()

        #expect(model.state == .loaded)
        #expect(model.showsEmptyDishState)
        #expect(model.avgRating == nil)
        #expect(model.reviewCount == 0)
    }

    @Test("a missing restaurant fails loudly and emits no view event")
    func missingRestaurant() async {
        let events = EventLog()
        let model = RestaurantDetailModel(
            restaurantID: DetailFixtures.id("rest-1"),
            dataSource: FakeDetailDataSource(),
            analytics: events.recorder
        )
        await model.load()

        #expect(model.state.errorMessage != nil)
        #expect(events.names.isEmpty)
    }

    @Test("view event fires once with its source; the log CTA instruments even unwired")
    func funnel() async {
        let source = FakeDetailDataSource()
        await source.insert(
            restaurant: DetailFixtures.restaurant(),
            stats: DetailFixtures.restaurantStats(avgRating: 4.0, reviewCount: 2)
        )
        let events = EventLog()
        let model = RestaurantDetailModel(
            restaurantID: DetailFixtures.id("rest-1"),
            source: .receipt,
            dataSource: source,
            analytics: events.recorder
        )

        await model.load()
        await model.refresh()
        #expect(events.events(named: "restaurant_detail_viewed").count == 1)
        let viewed = try? #require(events.first(named: "restaurant_detail_viewed"))
        #expect(viewed?.parameters["restaurant_id"] == DetailFixtures.id("rest-1").uuidString.lowercased())
        #expect(viewed?.parameters["source"] == "receipt")

        #expect(model.canLogDish == false)
        model.logDishTapped()
        #expect(events.first(named: "log_cta_tapped")?.parameters["from"] == "restaurant_detail")
    }
}
