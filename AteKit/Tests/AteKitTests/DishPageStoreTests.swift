import Foundation
import Testing

@testable import AteKit

@MainActor
@Suite("Dish page")
struct DishPageStoreTests {

    private let dishID = UUID(uuidString: "D7E00000-0000-4000-8000-000000000001")!
    private let placeID = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!

    private func summary(score: Double? = 4.6, saved: Bool = false, people: Int = 24) -> DishSummary {
        DishSummary(
            dishID: dishID, name: "Tagliatelle al ragù",
            restaurantID: placeID, restaurantName: "Tipo 00", restaurantCity: "Melbourne",
            score: score, reviewCount: 26, scoredCount: 24, peopleCount: people,
            isSaved: saved, myLastScore: 4.5
        )
    }

    private func review(
        _ minutesAgo: Double,
        mine: Bool = false,
        handle: String = "jessw",
        score: Double? = 5.0
    ) -> DishReview {
        DishReview(
            reviewID: UUID(),
            entryID: UUID(),
            author: EntryCard.Author(id: UUID(), username: handle),
            score: score.map { Rating(rounding: $0) },
            note: "Still the best thing on Little Bourke.",
            createdAt: Date(timeIntervalSince1970: 1_789_776_000 - minutesAgo * 60),
            isMine: mine
        )
    }

    private func store(
        _ source: FakePlaceDishSource,
        pageSize: Int = 2,
        savedDishes: SavedDishBroadcast? = nil,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) -> DishPageStore {
        DishPageStore(
            dishID: dishID, source: .place, dishes: source,
            pageSize: pageSize, savedDishes: savedDishes, analytics: analytics
        )
    }

    // MARK: - The header

    @Test("the header carries the dish, its place and its aggregate")
    func loadsHeader() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary(), reviews: [review(10)])
        let store = store(source)
        await store.load()

        #expect(store.name == "Tagliatelle al ragù")
        #expect(store.restaurantID == placeID)
        #expect(store.score == 4.6)
        #expect(store.peopleCount == 24)
        #expect(store.summary?.myLastRating == Rating(rounding: 4.5))
    }

    @Test("an unscored dish has no score — never a zero")
    func unratedDish() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary(score: nil))
        let store = store(source)
        await store.load()

        #expect(store.score == nil)
        #expect(store.summary?.isRated == false)
    }

    @Test("a dish that is not there is unavailable, not a spinner forever")
    func missingDish() async {
        let store = store(FakePlaceDishSource())
        await store.load()

        #expect(store.header == .unavailable)
    }

    @Test("a header that never came back is unreachable, not missing — and a retry recovers it")
    func unreachableIsNotMissing() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary())
        source.failSummary(FakePlaceDishSource.Failure(message: "offline"))
        let store = store(source)
        await store.load()
        #expect(store.header == .unreachable)

        source.failSummary(nil)
        await store.retry()
        #expect(store.name == "Tagliatelle al ragù")
    }

    // MARK: - Reviews

    @Test("You comes first, then everybody else newest first")
    func youFirst() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary(), reviews: [
            review(5, handle: "marcus.eats"),
            review(500, mine: true, handle: "eamon"),
            review(50, handle: "jessw")
        ])
        let store = store(source, pageSize: 10)
        await store.load()

        #expect(store.reviews.map { $0.author?.username } == ["eamon", "marcus.eats", "jessw"])
        #expect(store.reviews.first?.isMine == true)
    }

    @Test("your review stays at the top even when it lands on a later page")
    func youFirstAcrossPages() async {
        let source = FakePlaceDishSource()
        // The fake orders as the RPC does, so `mine` leads — but the store's own re-order is what
        // this asserts: a page that arrives second must not push You down the list.
        source.seed(dish: summary(), reviews: [
            review(5, handle: "a"), review(15, handle: "b"), review(25, handle: "c")
        ])
        let store = store(source, pageSize: 2)
        await store.load()
        #expect(store.reviews.count == 2)

        await store.loadMore()
        #expect(store.reviews.count == 3)
        #expect(store.reviews.map { $0.author?.username } == ["a", "b", "c"])
    }

    @Test("the three-part cursor is what the next page asks for")
    func threePartCursor() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary(), reviews: [
            review(5, mine: true, handle: "eamon"), review(15), review(25), review(35)
        ])
        let store = store(source, pageSize: 2)
        await store.load()
        await store.loadMore()

        #expect(source.reviewRequests.count == 2)
        #expect(source.reviewRequests.first == .some(nil), "the first page passes nulls")
        let cursor = try? #require(source.reviewRequests.last.flatMap { $0 })
        #expect(cursor?.isMine == false, "the last row of page one was not mine")
        #expect(store.reviews.count == 4)
        #expect(Set(store.reviews.map(\.id)).count == 4, "a keyset page must not serve a row twice")
    }

    @Test("an unscored review is nil, so it draws the empty star rather than a 0")
    func unscoredReview() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary(), reviews: [review(5, score: nil)])
        let store = store(source, pageSize: 10)
        await store.load()

        #expect(store.reviews.first?.score == nil)
    }

    @Test("nobody has written about it yet is empty, not an error")
    func emptyReviews() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary(), reviews: [])
        let store = store(source)
        await store.load()

        #expect(store.phase == .empty)
    }

    @Test("a first page that fails is a failure; a later one only says so inline")
    func failures() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary(), reviews: [review(5), review(15), review(25)])
        source.failReviews(times: 1)
        let store = store(source, pageSize: 2)
        await store.load()
        #expect(store.phase == .failed(message: "Couldn't load these reviews."))

        await store.refresh()
        #expect(store.phase == .ready)
        #expect(store.reviews.count == 2)

        source.failReviews(times: 1)
        await store.loadMore()
        #expect(store.reviews.count == 2, "the good rows stay on screen")
        #expect(store.inlineErrorMessage != nil)
    }

    // MARK: - The bookmark

    @Test("the bookmark is seeded from the header and then listens to the broadcast")
    func bookmarkFollowsTheBroadcast() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary(saved: true))
        let broadcast = SavedDishBroadcast()
        let store = store(source, savedDishes: broadcast)
        await store.load()
        #expect(store.isSaved)

        broadcast.send(dishID: dishID, isSaved: false)
        #expect(store.isSaved == false)

        // …and a roll-back after a refusal puts it back, exactly as the feed's does.
        broadcast.send(dishID: dishID, isSaved: true)
        #expect(store.isSaved)
    }

    @Test("another dish's save does not move this one's bookmark")
    func bookmarkIgnoresOtherDishes() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary(saved: false))
        let broadcast = SavedDishBroadcast()
        let store = store(source, savedDishes: broadcast)
        await store.load()

        broadcast.send(dishID: UUID(), isSaved: true)
        #expect(store.isSaved == false)
    }

    // MARK: - Funnel

    @Test("dish_detail_viewed fires once, after the header resolves, with its source")
    func recordsOneView() async {
        let source = FakePlaceDishSource()
        source.seed(dish: summary())
        let log = EventLog()
        let store = store(source, analytics: log.recorder)
        await store.load()
        await store.refresh()

        let views = log.events(named: "dish_detail_viewed")
        #expect(views.count == 1)
        #expect(views.first?.parameters["source"] == "place")
        #expect(views.first?.parameters["dish_id"] == dishID.uuidString.lowercased())
    }
}

@Suite("Dish review order")
struct DishReviewOrderTests {

    private func review(_ mine: Bool, _ handle: String, _ minutesAgo: Double) -> DishReview {
        DishReview(
            reviewID: UUID(),
            entryID: UUID(),
            author: EntryCard.Author(id: UUID(), username: handle),
            createdAt: Date(timeIntervalSince1970: 1_789_776_000 - minutesAgo * 60),
            isMine: mine
        )
    }

    @Test("mine first, and the order inside each group is left exactly as it arrived")
    func stablePartition() {
        let ordered = DishReviewOrder.youFirst([
            review(false, "a", 5), review(true, "me", 900), review(false, "b", 15),
            review(false, "c", 25)
        ])
        #expect(ordered.map { $0.author?.username } == ["me", "a", "b", "c"])
    }

    @Test("with no review of your own it changes nothing at all")
    func noneOfMine() {
        let input = [review(false, "a", 5), review(false, "b", 15)]
        #expect(DishReviewOrder.youFirst(input).map(\.id) == input.map(\.id))
    }
}
