import Foundation
import Testing

@testable import AteKit

/// An entry page's "More at <place>" and "More like this" (build 87, note 8).
@MainActor
@Suite("Entry more")
struct EntryMoreTests {

    private static let place = UUID()

    private static func item(_ position: Int, score: Rating?, dish: UUID = UUID()) -> EntryCard.Item {
        EntryCard.Item(reviewID: UUID(), dishID: dish, dishName: "Dish \(position)", score: score, position: position)
    }

    private static func menu(_ name: String, score: Double?, reviews: Int = 1, id: UUID = UUID()) -> MenuDish {
        MenuDish(dishID: id, name: name, score: score, peopleCount: reviews, reviewCount: reviews)
    }

    private static func similar(_ name: String, id: UUID = UUID()) -> SimilarDish {
        SimilarDish(dishID: id, name: name, restaurantID: UUID(), restaurantName: "Elsewhere", score: 4)
    }

    private static func placeSummary() -> PlaceSummary {
        PlaceSummary(restaurantID: place, name: "Tipo 00", address: nil, locality: "CBD", city: nil,
                     cuisine: nil, avgRating: 4, reviewCount: 3, entryCount: 1, peopleCount: 1, dishCount: 3,
                     myVisits: 1)
    }

    // MARK: - The anchor

    @Test func theAnchorIsTheHighestScoredDishWithASecretSixAboveAFive() throws {
        let six = UUID()
        let items = [
            Self.item(0, score: Rating(rounding: 5)),
            Self.item(1, score: nil),
            Self.item(2, score: .blownAway, dish: six)
        ]
        #expect(EntryMoreStore.anchor(items) == six)
    }

    @Test func aTieGoesToTheEarlierLine() {
        let first = UUID()
        let items = [Self.item(1, score: Rating(rounding: 4)), Self.item(0, score: Rating(rounding: 4), dish: first)]
        #expect(EntryMoreStore.anchor(items) == first)
    }

    @Test func withNothingScoredTheFirstDishAnchorsAndNoScoreIsGuessed() {
        let first = UUID()
        let items = [Self.item(1, score: nil), Self.item(0, score: nil, dish: first)]
        #expect(EntryMoreStore.anchor(items) == first)
        #expect(EntryMoreStore.anchor([]) == nil)
    }

    // MARK: - The shelves' rules

    @Test func moreAtThePlaceDropsTheEntrysOwnDishesKeepsTheServersOrderAndCapsAtTen() {
        let own = UUID()
        let rows = [Self.menu("Mine", score: 5, id: own)] + (0..<14).map { Self.menu("D\($0)", score: 4) }
        let best = EntryMoreStore.best(rows, excluding: [own])
        #expect(best.count == EntryMoreStore.cap)
        #expect(best.map(\.name) == (0..<10).map { "D\($0)" })
    }

    @Test func atTheSamePlaceADishOfTheSameNameIsTheEntrysOwn() {
        let rows = [Self.menu("Tiramisù ", score: 4), Self.menu("Cannoli", score: 3)]
        #expect(EntryMoreStore.best(rows, excluding: [], named: ["tiramisu"]).map(\.name) == ["Cannoli"])
    }

    @Test func moreLikeThisDropsTheEntrysDishesAndRepeats() {
        let own = UUID(), repeated = UUID()
        let rows = [Self.similar("Own", id: own), Self.similar("A", id: repeated), Self.similar("B"),
                    Self.similar("A again", id: repeated)]
        #expect(EntryMoreStore.others(rows, excluding: [own]).map(\.name) == ["A", "B"])
    }

    // MARK: - The store

    @Test func bothShelvesFillAndSettle() async {
        let places = FakePlaceDishSource(), explore = FakeDishExplore()
        let own = UUID()
        places.seed(place: Self.placeSummary(), dishes: [
            Self.menu("Mine", score: 5, id: own), Self.menu("Cacio e pepe", score: 4.5)
        ])
        explore.seed(dishID: own, similar: [Self.similar("Carbonara")])
        let store = EntryMoreStore(places: places, explore: explore)
        let subject = EntryMoreStore.Subject(restaurantID: Self.place, anchorDishID: own, ownDishIDs: [own])
        #expect(store.showsPlace == false, "nothing is asked about before load")
        await store.load(subject)
        #expect(store.atPlace.map(\.name) == ["Cacio e pepe"])
        #expect(store.similar.map(\.name) == ["Carbonara"])
        #expect(store.showsPlace && store.showsSimilar)
        #expect(explore.similarLimits == [EntryMoreStore.cap + 1], "asks for enough to fill ten after excluding")
    }

    @Test func aPlacelessEntryHasNoPlaceShelfAndAFailedReadHidesItsShelf() async {
        let places = FakePlaceDishSource(), explore = FakeDishExplore()
        explore.failSimilar(true)
        let store = EntryMoreStore(places: places, explore: explore)
        let dish = UUID()
        await store.load(.init(restaurantID: nil, anchorDishID: dish, ownDishIDs: [dish]))
        #expect(store.showsPlace == false)
        #expect(store.isSimilarSettled)
        #expect(store.showsSimilar == false)
        #expect(places.menuCursors.isEmpty, "no place, no menu read")
    }

    @Test func aMenuOfOnlyTheEntrysDishesHidesTheShelf() async {
        let places = FakePlaceDishSource(), explore = FakeDishExplore()
        let own = UUID()
        places.seed(place: Self.placeSummary(), dishes: [Self.menu("Mine", score: 5, id: own)])
        let store = EntryMoreStore(places: places, explore: explore)
        await store.load(.init(restaurantID: Self.place, anchorDishID: own, ownDishIDs: [own]))
        #expect(store.showsPlace == false)
        #expect(store.showsSimilar == false)
    }

    @Test func theSameSubjectIsReadOnceAndAChangedOneReadsAgain() async {
        let places = FakePlaceDishSource(), explore = FakeDishExplore()
        let dish = UUID()
        places.seed(place: Self.placeSummary(), dishes: [Self.menu("Other", score: 4)])
        let store = EntryMoreStore(places: places, explore: explore)
        let placeless = EntryMoreStore.Subject(restaurantID: nil, anchorDishID: dish, ownDishIDs: [dish])
        await store.load(placeless)
        await store.load(placeless)
        #expect(explore.similarLimits.count == 1)
        await store.load(.init(restaurantID: Self.place, anchorDishID: dish, ownDishIDs: [dish]))
        #expect(store.atPlace.map(\.name) == ["Other"], "a place attached reads the place's menu")
        #expect(explore.similarLimits.count == 2)
    }

    @Test func neitherSectionShowsUntilBothReadsHaveAnswered() async {
        let places = FakePlaceDishSource(), explore = GatedSimilar()
        let own = UUID()
        places.seed(place: Self.placeSummary(), dishes: [Self.menu("Cacio e pepe", score: 4.5)])
        let store = EntryMoreStore(places: places, explore: explore)
        let loading = Task { await store.load(.init(restaurantID: Self.place, anchorDishID: own, ownDishIDs: [own])) }
        while store.isPlaceSettled == false { await Task.yield() }
        #expect(store.atPlace.map(\.name) == ["Cacio e pepe"])
        #expect(store.isSettled == false && store.showsPlace == false && store.showsSimilar == false,
                "the place's answer waits for the similar one")
        await explore.answer([Self.similar("Carbonara")])
        await loading.value
        #expect(store.isSettled && store.showsPlace && store.showsSimilar)
    }

    @Test func theEventFollowsSimilarDishOpened() {
        let event = DetailEvents.entryMoreOpened(section: .place, position: 3)
        #expect(event.name == "entry_more_opened")
        #expect(event.parameters == ["section": "place", "position": "3"])
        #expect(DetailSource.entryMore.rawValue == "entry_more")
    }
}

/// A similar-dishes read that answers only when told to.
private actor GatedSimilar: DishExploreReading {
    private var waiting: [CheckedContinuation<[SimilarDish], Never>] = []
    private var answered: [SimilarDish]?

    func answer(_ rows: [SimilarDish]) {
        answered = rows
        waiting.forEach { $0.resume(returning: rows) }
        waiting = []
    }

    func dishTags(dishID: UUID) async throws -> [DishTag] { [] }

    func similarDishes(dishID: UUID, limit: Int) async throws -> [SimilarDish] {
        if let answered { return answered }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func dishesByTag(
        kind: DishTag.Kind, slug: String, city: String?, after cursor: TagDishCursor?, pageSize: Int
    ) async throws -> TagDishPage {
        TagDishPage(items: [], nextCursor: nil)
    }
}
