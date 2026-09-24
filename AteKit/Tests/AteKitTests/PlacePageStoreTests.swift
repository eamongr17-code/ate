import Foundation
import Testing

@testable import AteKit

@MainActor
@Suite("Place page")
struct PlacePageStoreTests {

    private let placeID = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!

    private func summary(
        rating: Double? = 4.3,
        people: Int = 31,
        cuisine: String? = "Italian",
        locality: String? = "CBD",
        visits: Int = 3
    ) -> PlaceSummary {
        PlaceSummary(
            restaurantID: placeID, name: "Tipo 00", address: "361 Little Bourke St",
            locality: locality,
            // The mangled `city` the design must never print — the suburb chip reads `locality`.
            city: "361 Little Bourke St, Melbourne VIC 3000, Australia",
            cuisine: cuisine, avgRating: rating, reviewCount: 52, entryCount: 40,
            peopleCount: people, dishCount: 9, myVisits: visits
        )
    }

    private func dish(_ name: String, score: Double?, reviews: Int, people: Int? = nil) -> MenuDish {
        MenuDish(
            dishID: UUID(), name: name, score: score,
            peopleCount: people ?? reviews, reviewCount: reviews
        )
    }

    private func card(_ minutesAgo: Double, mine: Bool) -> EntryCard {
        EntryCard(
            id: UUID(),
            authorID: UUID(),
            body: "Tipo 00 was good.",
            orderNumber: 1,
            sortStatus: .sorted,
            createdAt: Date(timeIntervalSince1970: 1_789_776_000 - minutesAgo * 60),
            isMine: mine,
            author: EntryCard.Author(id: UUID(), username: mine ? "eamon" : "jessw"),
            place: EntryCard.Place(id: placeID, name: "Tipo 00")
        )
    }

    private func store(
        _ source: FakePlaceDishSource,
        pageSize: Int = 2,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) -> PlacePageStore {
        PlacePageStore(
            restaurantID: placeID, source: .feed, places: source,
            pageSize: pageSize, analytics: analytics
        )
    }

    // MARK: - The header

    @Test("the header, the menu and both entry lists land from one load")
    func loadsEverything() async {
        let source = FakePlaceDishSource()
        source.seed(
            place: summary(),
            dishes: [dish("Tiramisu", score: 4.2, reviews: 11), dish("Tagliatelle", score: 4.6, reviews: 24)],
            entries: [card(10, mine: true), card(20, mine: false), card(30, mine: false)]
        )
        let store = store(source)
        await store.load()

        #expect(store.name == "Tipo 00")
        #expect(store.dishes.map(\.name) == ["Tiramisu", "Tagliatelle"],
                "the server's order, exactly as sent — a paged list cannot be re-sorted on arrival")
        #expect(store.visits.entries.count == 1)
        #expect(store.entries.entries.count == 2)
        #expect(source.entryScopes.contains(.mine))
        #expect(source.entryScopes.contains(.others))
        #expect(source.entryScopes.contains(.all) == false, "the page never mixes yours with theirs")
    }

    @Test("the average is READ, never averaged from the dish list")
    func ratingComesFromTheServer() async {
        let source = FakePlaceDishSource()
        // Every dish is a 5.0; the place's own aggregate says 4.3. The header must say 4.3.
        source.seed(
            place: summary(rating: 4.3),
            dishes: [dish("A", score: 5.0, reviews: 4), dish("B", score: 5.0, reviews: 2)]
        )
        let store = store(source)
        await store.load()

        #expect(store.summary?.avgRating == 4.3)
        #expect(store.facts.first == .rating("4.3"))
    }

    /// **The order is the server's, and the client must not second-guess it.** `place_dishes` is
    /// paged on a four-part keyset (0029), so re-sorting a page on arrival would interleave the
    /// next one into it. ``DishRanking`` disagrees with that order — it would put the well-reviewed
    /// dish first — and that disagreement has to be settled in the `ORDER BY`, not here.
    @Test("what to order is printed in the order the server sent it, never re-sorted")
    func menuKeepsTheServersOrder() async {
        let source = FakePlaceDishSource()
        source.seed(place: summary(), dishes: [
            dish("Lonely 5.0", score: 5.0, reviews: 1),
            dish("Beloved 4.4", score: 4.4, reviews: 12),
            dish("Never scored", score: nil, reviews: 0)
        ])
        let store = store(source, pageSize: 10)
        await store.load()

        #expect(store.dishes.map(\.name) == ["Lonely 5.0", "Beloved 4.4", "Never scored"])
    }

    @Test("the menu walks its four-part cursor without serving a dish twice")
    func menuPages() async {
        let source = FakePlaceDishSource()
        source.seed(place: summary(), dishes: (0..<5).map {
            dish("Dish \($0)", score: 5.0 - Double($0) / 10, reviews: 5 - $0)
        })
        let store = PlacePageStore(
            restaurantID: placeID, source: .feed, places: source, menuPageSize: 2
        )
        await store.load()
        #expect(store.dishes.count == 2)

        await store.loadMoreDishes()
        await store.loadMoreDishes()
        #expect(store.dishes.map(\.name) == ["Dish 0", "Dish 1", "Dish 2", "Dish 3", "Dish 4"])
        #expect(Set(store.dishes.map(\.dishID)).count == 5)
        // The cursor is the LAST row of the page before it, all four parts of it.
        #expect(source.menuCursors.count == 3)
        #expect(source.menuCursors.last??.name == "Dish 3")
        #expect(source.menuCursors.last??.score == 4.7)
    }

    @Test("a fact is only a chip when we have it — nothing is drawn on a guess")
    func factsAreOnlyWhatIsKnown() async {
        let source = FakePlaceDishSource()
        source.seed(place: summary(rating: nil, people: 0, cuisine: nil, locality: nil))
        let store = store(source)
        await store.load()

        #expect(store.facts.isEmpty, "no rating, nobody, no cuisine, no suburb → no chips")
    }

    @Test("the chips read average, people, cuisine, suburb — in the artboard's order")
    func factsAreOrdered() async {
        let source = FakePlaceDishSource()
        source.seed(place: summary())
        let store = store(source)
        await store.load()

        #expect(store.facts == [.rating("4.3"), .people("31"), .word("Italian"), .word("CBD")])
    }

    /// `city` on a live Google row is a slice of the formatted address. Printing it would put
    /// "361 Little Bourke St, Melbourne VIC 3000, Australia" in a 32pt chip.
    @Test("the suburb chip is `locality` and never `city`")
    func suburbIsLocality() async {
        let source = FakePlaceDishSource()
        source.seed(place: summary(locality: "Carlton"))
        let store = store(source)
        await store.load()

        #expect(store.facts.last == .word("Carlton"))
        #expect(store.facts.contains { $0.text.contains("Australia") } == false)
    }

    @Test("a place that is not there is unavailable, not a spinner forever")
    func missingPlace() async {
        let store = store(FakePlaceDishSource())
        await store.load()

        #expect(store.header == .unavailable)
        #expect(store.summary == nil)
    }

    @Test("a menu that fails does not take the header down with it")
    func menuFailsAlone() async {
        let source = FakePlaceDishSource()
        source.seed(place: summary())
        source.failMenu(FakePlaceDishSource.Failure(message: "nope"))
        let store = store(source)
        await store.load()

        #expect(store.menu == .failed)
        #expect(store.name == "Tipo 00")
    }

    @Test("your visits band is absent at zero rather than saying none")
    func noVisits() async {
        let source = FakePlaceDishSource()
        source.seed(place: summary(visits: 0))
        let store = store(source)
        await store.load()

        #expect(store.hasVisits == false)
        #expect(store.myVisits == 0)
    }

    // MARK: - Paging

    @Test("the entries list walks a keyset without serving a row twice")
    func entriesPage() async {
        let source = FakePlaceDishSource()
        let theirs = (0..<5).map { card(Double($0 * 10 + 5), mine: false) }
        source.seed(place: summary(), entries: theirs + [card(1, mine: true)])
        let store = store(source, pageSize: 2)
        await store.load()

        #expect(store.entries.entries.count == 2)
        await store.entries.loadMore()
        await store.entries.loadMore()
        #expect(store.entries.entries.count == 5)
        #expect(Set(store.entries.entries.map(\.id)).count == 5)
        // Newest first, and the viewer's own entry is not in the others list.
        #expect(store.entries.entries.allSatisfy { $0.isMine == false })
    }

    // MARK: - Funnel

    @Test("restaurant_detail_viewed fires once, after the header resolves, with its source")
    func recordsOneView() async {
        let source = FakePlaceDishSource()
        source.seed(place: summary())
        let log = EventLog()
        let store = store(source, analytics: log.recorder)
        await store.load()
        await store.refresh()

        let views = log.events(named: "restaurant_detail_viewed")
        #expect(views.count == 1)
        #expect(views.first?.parameters["source"] == "feed")
        #expect(views.first?.parameters["restaurant_id"] == placeID.uuidString.lowercased())
    }

    @Test("a failed header records nothing — the funnel counts places people saw")
    func noViewWithoutAHeader() async {
        let log = EventLog()
        let store = store(FakePlaceDishSource(), analytics: log.recorder)
        await store.load()

        #expect(log.names.contains("restaurant_detail_viewed") == false)
    }
}
