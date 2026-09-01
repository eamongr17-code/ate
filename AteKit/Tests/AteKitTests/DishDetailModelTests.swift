import Foundation
import Testing

@testable import AteKit

@MainActor
@Suite("Dish detail model")
struct DishDetailModelTests {

    /// A restaurant, one dish, `reviewCount` reviews by one author, and matching stats.
    private func seeded(
        score: Double? = 4.5,
        reviewCount: Int = 3
    ) async -> FakeDetailDataSource {
        let source = FakeDetailDataSource()
        await source.insert(restaurant: DetailFixtures.restaurant())
        await source.insert(
            dish: DetailFixtures.dish(),
            stats: DetailFixtures.dishStats(score: score, reviewCount: reviewCount)
        )
        await source.insert(reviews: DetailFixtures.reviews(count: reviewCount))
        await source.insert(user: DetailFixtures.user())
        return source
    }

    @Test("loads the header, the first page of reviews, and their authors")
    func loadsDetail() async {
        let source = await seeded(reviewCount: 3)
        let model = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: source)

        await model.load()

        #expect(model.state == .loaded)
        #expect(model.dish?.name == "Tagliolini")
        #expect(model.restaurant?.name == "Tipo 00")
        #expect(model.score == 4.5)
        #expect(model.isRated)
        #expect(model.reviewCount == 3)
        #expect(model.reviews.count == 3)
        #expect(model.hasMoreReviews == false)
        // Newest first.
        let timestamps = model.reviews.map(\.createdAt)
        #expect(timestamps == timestamps.sorted(by: >))
        let author = try? #require(model.author(of: model.reviews[0]))
        #expect(author?.username == "eamon")
    }

    @Test("a dish nobody has reviewed renders the unrated state, not 0.0")
    func unratedDishRendersDash() async {
        // The staging seed really contains dishes like this (dish_stats.score IS NULL).
        let source = FakeDetailDataSource()
        await source.insert(restaurant: DetailFixtures.restaurant())
        await source.insert(
            dish: DetailFixtures.dish(),
            stats: DetailFixtures.dishStats(score: nil, reviewCount: 0)
        )
        let model = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: source)

        await model.load()

        #expect(model.state == .loaded)
        #expect(model.score == nil)
        #expect(model.isRated == false)
        #expect(model.reviewCount == 0)
        #expect(model.reviews.isEmpty)
        #expect(model.showsEmptyReviewState)
        #expect(ScoreFormat.outOfFive(model.score) == "–/5")
    }

    @Test("a dish with no dish_stats row at all is unrated, not an error")
    func missingStatsRowIsUnrated() async {
        let source = FakeDetailDataSource()
        await source.insert(restaurant: DetailFixtures.restaurant())
        await source.insert(dish: DetailFixtures.dish())
        let model = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: source)

        await model.load()

        #expect(model.state == .loaded)
        #expect(model.score == nil)
        #expect(model.isRated == false)
    }

    // MARK: - Merge tombstones (data-model §4)

    @Test("a link to a merged-away dish lands on the survivor, with the survivor's reviews")
    func followsMergeTombstone() async {
        let source = FakeDetailDataSource()
        let survivorID = DetailFixtures.id("dish-2")
        await source.insert(restaurant: DetailFixtures.restaurant())
        await source.insert(dish: DetailFixtures.dish("dish-1", name: "Taglioni (typo)", mergedInto: survivorID))
        await source.insert(
            dish: DetailFixtures.dish("dish-2", name: "Tagliolini"),
            stats: DetailFixtures.dishStats("dish-2", score: 4.5, reviewCount: 2)
        )
        await source.insert(reviews: DetailFixtures.reviews(count: 2, dish: survivorID))
        await source.insert(user: DetailFixtures.user())

        let events = EventLog()
        let model = DishDetailModel(
            dishID: DetailFixtures.id("dish-1"),
            source: .search,
            dataSource: source,
            analytics: events.recorder
        )
        await model.load()

        #expect(model.dish?.id == survivorID)
        #expect(model.dish?.name == "Tagliolini")
        #expect(model.snapshot?.wasRedirected == true)
        // The trap: reviews must be scoped to the survivor, or the screen shows an empty list.
        #expect(model.reviews.count == 2)
        let requestedDishIDs = await source.reviewRequests.map(\.dishID)
        #expect(requestedDishIDs.allSatisfy { $0 == survivorID })
        // And the funnel counts the dish people actually saw.
        #expect(events.first(named: "dish_detail_viewed")?.parameters["dish_id"] == survivorID.uuidString.lowercased())
    }

    @Test("a merge chain resolves to the end, and a cycle terminates instead of hanging")
    func mergeChainsAndCycles() async {
        let source = FakeDetailDataSource()
        await source.insert(restaurant: DetailFixtures.restaurant())
        await source.insert(dish: DetailFixtures.dish("dish-1", mergedInto: DetailFixtures.id("dish-2")))
        await source.insert(dish: DetailFixtures.dish("dish-2", mergedInto: DetailFixtures.id("dish-3")))
        await source.insert(dish: DetailFixtures.dish("dish-3", name: "Final"))

        let chained = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: source)
        await chained.load()
        #expect(chained.dish?.name == "Final")

        // A cycle can only exist as data corruption — it must still return a dish, not spin.
        let cyclic = FakeDetailDataSource()
        await cyclic.insert(restaurant: DetailFixtures.restaurant())
        await cyclic.insert(dish: DetailFixtures.dish("dish-1", mergedInto: DetailFixtures.id("dish-2")))
        await cyclic.insert(dish: DetailFixtures.dish("dish-2", mergedInto: DetailFixtures.id("dish-1")))

        let model = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: cyclic)
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.dish != nil)
    }

    // MARK: - Pagination

    @Test("reviews page with the keyset cursor: no gaps, no repeats, and it stops")
    func paginatesReviews() async {
        let pageSize = DishDetailModel.reviewPageSize
        let total = pageSize * 2 + 5
        let source = FakeDetailDataSource()
        await source.insert(restaurant: DetailFixtures.restaurant())
        await source.insert(
            dish: DetailFixtures.dish(),
            stats: DetailFixtures.dishStats(score: 4.2, reviewCount: total)
        )
        await source.insert(reviews: DetailFixtures.reviews(count: total))
        await source.insert(user: DetailFixtures.user())

        let model = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: source)
        await model.load()
        #expect(model.reviews.count == pageSize)
        #expect(model.hasMoreReviews)

        // Scrolling to the end of what's loaded pulls the next page.
        await model.loadMoreIfNeeded(currentReviewID: model.reviews.last!.id)
        #expect(model.reviews.count == pageSize * 2)

        await model.loadMoreIfNeeded(currentReviewID: model.reviews.last!.id)
        #expect(model.reviews.count == total)
        #expect(model.hasMoreReviews == false)

        // Nothing served twice, and strictly newest-first across page boundaries.
        #expect(Set(model.reviews.map(\.id)).count == total)
        for (newer, older) in zip(model.reviews, model.reviews.dropFirst()) {
            #expect(newer.createdAt > older.createdAt)
        }

        // The cursor actually travelled: page 2 asked to start after the last row of page 1.
        let requests = await source.reviewRequests
        #expect(requests.count == 3)
        #expect(requests[0].cursor == nil)
        #expect(requests[1].cursor == DetailFixtures.reviews(count: total)[pageSize - 1].pageCursor)

        // Exhausted: a further scroll is a no-op, not another request.
        await model.loadMoreIfNeeded(currentReviewID: model.reviews.last!.id)
        #expect(await source.reviewRequests.count == 3)
    }

    @Test("scrolling in the middle of a loaded page doesn't fetch")
    func loadMoreOnlyNearTheEnd() async {
        let source = await seeded(reviewCount: DishDetailModel.reviewPageSize * 2)
        let model = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: source)
        await model.load()

        await model.loadMoreIfNeeded(currentReviewID: model.reviews.first!.id)
        #expect(await source.reviewRequests.count == 1)
    }

    @Test("a failed second page keeps the reviews already on screen")
    func failedSecondPageKeepsContent() async {
        let total = DishDetailModel.reviewPageSize + 4
        let source = FakeDetailDataSource()
        await source.insert(restaurant: DetailFixtures.restaurant())
        await source.insert(dish: DetailFixtures.dish(), stats: DetailFixtures.dishStats(score: 4.0, reviewCount: total))
        await source.insert(reviews: DetailFixtures.reviews(count: total))
        await source.insert(user: DetailFixtures.user())

        let model = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: source)
        await model.load()
        await source.setReviewFailures(1)
        await model.loadMoreIfNeeded(currentReviewID: model.reviews.last!.id)

        #expect(model.state == .loaded)  // not blanked
        #expect(model.reviews.count == DishDetailModel.reviewPageSize)
        #expect(model.hasMoreReviews == false)
    }

    // MARK: - Failure + funnel

    @Test("a failed header load surfaces an error and emits no view event")
    func failedLoad() async {
        let source = FakeDetailDataSource()
        await source.setDishDetailFailure(FakeDetailDataSource.Failure(message: "offline"))
        let events = EventLog()
        let model = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: source, analytics: events.recorder)

        await model.load()

        #expect(model.state.errorMessage != nil)
        #expect(model.dish == nil)
        #expect(events.names.isEmpty)
    }

    @Test("the view event fires once, with the source it was opened from")
    func viewEventFiresOnce() async {
        let source = await seeded()
        let events = EventLog()
        let model = DishDetailModel(
            dishID: DetailFixtures.id("dish-1"),
            source: .feed,
            dataSource: source,
            analytics: events.recorder
        )

        await model.load()
        await model.load()  // .task can run twice; the funnel must not double-count
        await model.reload()

        #expect(events.events(named: "dish_detail_viewed").count == 1)
        #expect(events.first(named: "dish_detail_viewed")?.parameters["source"] == "feed")
    }

    @Test("source defaults to unknown rather than guessing an entry point")
    func defaultSource() async {
        let source = await seeded()
        let events = EventLog()
        let model = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: source, analytics: events.recorder)
        await model.load()
        #expect(events.first(named: "dish_detail_viewed")?.parameters["source"] == "unknown")
    }

    @Test("the log CTA is hidden until a host wires it, but the tap always instruments")
    func logCTA() async {
        let source = await seeded()
        let events = EventLog()

        let unwired = DishDetailModel(dishID: DetailFixtures.id("dish-1"), dataSource: source, analytics: events.recorder)
        #expect(unwired.canLogDish == false)

        var tapped = 0
        let wired = DishDetailModel(
            dishID: DetailFixtures.id("dish-1"),
            dataSource: source,
            analytics: events.recorder,
            onLogDish: { tapped += 1 }
        )
        #expect(wired.canLogDish)

        wired.logDishTapped()
        #expect(tapped == 1)
        let event = try? #require(events.first(named: "log_cta_tapped"))
        #expect(event?.parameters["from"] == "dish_detail")

        // Fires even with no log flow attached — the intent is measured before the sheet exists.
        unwired.logDishTapped()
        #expect(events.events(named: "log_cta_tapped").count == 2)
    }
}
