import Foundation
import Supabase
import Testing
@testable import AteKit

@Suite("Round 5 — Search, Saved and the cities")
@MainActor
struct Round5ShelfTests {
    /// A shelf that holds a fixed list and pages it like the view does.
    private final class Shelf: DishSaving, @unchecked Sendable {
        let dishes: [SavedDish]
        init(_ dishes: [SavedDish]) { self.dishes = dishes }
        func save(dishID: UUID, sourceEntryID: UUID?) async throws {}
        func unsave(dishID: UUID) async throws {}
        func saveEntryDishes(entryID: UUID) async throws -> Int { 0 }
        func savedDishesPage(after cursor: PageCursor?, pageSize: Int) async throws -> Page<SavedDish> {
            let start = cursor.flatMap { cursor in dishes.firstIndex { $0.dishID == cursor.id }.map { $0 + 1 } } ?? 0
            return Page(items: Array(dishes.dropFirst(start).prefix(pageSize)), requestedLimit: pageSize)
        }
    }

    private static func dish(_ name: String, score: Double?, city: String?, minutes: Double) -> SavedDish {
        SavedDish(
            dishID: UUID(), dishName: name, restaurantID: UUID(), restaurantName: "Somewhere",
            restaurantCity: city, dishScore: score,
            savedAt: Date(timeIntervalSince1970: 1_789_776_000 - minutes * 60)
        )
    }

    private let shelf = Shelf([
        dish("Ragù", score: 4.5, city: "Melbourne", minutes: 1),
        dish("Toast", score: nil, city: "Melbourne", minutes: 2),
        dish("Laksa", score: 3.0, city: "Sydney", minutes: 3),
        dish("Burger", score: 6, city: "Gold Coast", minutes: 4)
    ])

    @Test("changing filters while People is loading never strands People on its skeleton")
    func peopleNotStranded() async {
        let service = FakeSearchService()
        service.seed(people: [.fixture("pastaindex"), .fixture("pat")])
        let store = SearchStore(service: service, scope: .people, pageSize: 10, debounce: .milliseconds(20))
        service.setLatency(.milliseconds(150), for: .people)
        store.query = "pa"
        await service.waitForCall { $0.scope == .people }
        // A filter set (or a pill taken off) while People's answer is in the air.
        store.setFilters(SearchFilters(minimumScore: 4))
        await store.settle()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(store.phase == .ready, "People lands — the filters are not People's to throw away")
        #expect(store.rows.count == 2)
    }

    @Test("filters narrow Places, Dishes and Saved — never People")
    func scopes() {
        #expect(SearchFilters.applies(to: .saved))
        #expect(SearchFilters.applies(to: .people) == false)
    }

    @Test("the Saved shelf narrows to a range and a city, read again from the top")
    func savedFilter() async {
        let store = SavedDishesStore(saves: shelf, pageSize: 2)
        await store.loadIfNeeded()
        #expect(store.dishes.count == 2)
        await store.apply(SavedDishFilter(band: ScoreBand(lower: 4, upper: 5)))
        #expect(store.dishes.map(\.dishName) == ["Ragù", "Burger"], "unscored out; the 6 clears an open top")
        await store.apply(SavedDishFilter(band: ScoreBand(lower: 4, upper: 5), city: "melbourne"))
        #expect(store.dishes.map(\.dishName) == ["Ragù"])
        await store.apply(SavedDishFilter(city: "nowhere"))
        #expect(store.phase == .empty)
        await store.apply(.none)
        #expect(store.dishes.count == 2 && store.phase == .ready)
    }

    @Test("search_saved's filter arguments: nulls when unused, no ceiling on an open top")
    func savedParameters() {
        #expect(SavedDishFilter.none.parameters["p_min_score"] == AnyJSON.null)
        let filter = SavedDishFilter(band: ScoreBand(lower: 3, upper: 5), city: "melbourne")
        #expect(filter.parameters["p_min_score"] == .double(3))
        #expect(filter.parameters["p_max_score"] == AnyJSON.null)
        #expect(filter.parameters["p_city"] == .string("melbourne"))
    }

    @Test("the shelf's cities: every city a saved dish is in, most first")
    func savedCities() async throws {
        let store = SavedDishesStore(saves: shelf)
        await store.loadCities()
        #expect(store.cities.map(\.city) == ["melbourne", "gold-coast", "sydney"])
        #expect(store.cities.first?.entryCount == 2)
    }

    @Test("the Journal's cities come from its reader")
    func journalCities() async {
        let entries = InMemoryEntryService()
        let store = JournalStore(entries: entries, querying: InMemoryJournalQuery(entries: entries))
        await store.loadCities()
        #expect(store.cities.allSatisfy { $0.city == AteCity.slug(for: $0.name) })
    }

    @Test("slugs and names go both ways")
    func slugs() {
        #expect(AteCity.slug(for: "Gold Coast") == "gold-coast")
        #expect(AteCity.slug(for: "  ") == nil)
        #expect(AteCity.displayName(for: "gold-coast") == "Gold Coast")
        #expect(AteCity.displayName(for: "melbourne", in: [AteCity(city: "melbourne", name: "Melb")]) == "Melb")
    }
}
