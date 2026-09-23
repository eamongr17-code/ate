import Foundation
import Testing
@testable import AteKit

/// A saves service a test drives: pages in, calls recorded, and a switch to make the server refuse.
private final class FakeSaves: DishSaving, @unchecked Sendable {
    var pages: [[SavedDish]]
    var refuses = false
    private(set) var saved: [(dish: UUID, entry: UUID?)] = []
    private(set) var unsaved: [UUID] = []
    private(set) var savedEntries: [UUID] = []
    private let lock = NSLock()

    init(pages: [[SavedDish]] = [[]]) {
        self.pages = pages
    }

    func save(dishID: UUID, sourceEntryID: UUID?) async throws {
        if refuses { throw AteAPIError.notAuthenticated }
        lock.withLock { saved.append((dishID, sourceEntryID)) }
    }

    func unsave(dishID: UUID) async throws {
        if refuses { throw AteAPIError.notAuthenticated }
        lock.withLock { unsaved.append(dishID) }
    }

    @discardableResult
    func saveEntryDishes(entryID: UUID) async throws -> Int {
        if refuses { throw AteAPIError.notAuthenticated }
        return lock.withLock {
            savedEntries.append(entryID)
            return 2
        }
    }

    func savedDishesPage(after cursor: PageCursor?, pageSize: Int) async throws -> Page<SavedDish> {
        if refuses { throw AteAPIError.notAuthenticated }
        return lock.withLock {
            let index = cursor == nil ? 0 : 1
            let items = index < pages.count ? pages[index] : []
            return Page(items: items, requestedLimit: pageSize)
        }
    }
}

private func saved(
    _ dish: String,
    at place: UUID,
    placeName: String,
    minutesAgo: Double,
    score: Double? = 4.5
) -> SavedDish {
    SavedDish(
        dishID: UUID(),
        dishName: dish,
        restaurantID: place,
        restaurantName: placeName,
        restaurantCity: "CBD",
        dishScore: score,
        sourceUsername: "jessw",
        savedAt: Date(timeIntervalSince1970: 1_789_776_000 - minutesAgo * 60)
    )
}

@Suite("Saved dish grouping")
struct SavedDishGroupingTests {

    private let tipo = UUID()
    private let kisume = UUID()

    @Test("Dishes group by place, in the order the rows arrived")
    func grouping() {
        let rows = [
            saved("Prawn spaghetti", at: tipo, placeName: "Tipo 00", minutesAgo: 1),
            saved("Salmon roll", at: kisume, placeName: "Kisume", minutesAgo: 2),
            saved("Tiramisu", at: tipo, placeName: "Tipo 00", minutesAgo: 3)
        ]
        let groups = SavedDishGrouping.groups(from: rows)
        #expect(groups.map(\.restaurantName) == ["Tipo 00", "Kisume"])
        #expect(groups[0].dishes.map(\.dishName) == ["Prawn spaghetti", "Tiramisu"],
                "a place split by another one's row is still one group")
        #expect(groups[0].city == "CBD")
    }

    @Test("Nothing saved is no groups, never an empty one")
    func empty() {
        #expect(SavedDishGrouping.groups(from: []).isEmpty)
    }
}

@MainActor
@Suite("Saved dishes store")
struct SavedDishesStoreTests {

    private let tipo = UUID()

    @Test("A short page is the end of the list, and it groups on arrival")
    func firstPage() async {
        let saves = FakeSaves(pages: [[
            saved("Prawn spaghetti", at: tipo, placeName: "Tipo 00", minutesAgo: 1),
            saved("Tiramisu", at: tipo, placeName: "Tipo 00", minutesAgo: 2)
        ]])
        let store = SavedDishesStore(saves: saves, pageSize: 10)
        await store.loadIfNeeded()
        #expect(store.phase == .ready)
        #expect(store.groups.count == 1)
        #expect(store.groups[0].dishes.count == 2)
        #expect(store.hasReachedEnd)
    }

    @Test("Nothing saved is the empty state")
    func empty() async {
        let store = SavedDishesStore(saves: FakeSaves(pages: [[]]))
        await store.loadIfNeeded()
        #expect(store.phase == .empty)
    }

    @Test("Signed out is its own state")
    func signedOut() async {
        let saves = FakeSaves()
        saves.refuses = true
        let store = SavedDishesStore(saves: saves)
        await store.loadIfNeeded()
        #expect(store.phase == .signedOut)
    }

    /// On this shelf the bookmark is the only reason a row exists, so an unsave removes it — and a
    /// server that refuses puts it back where it was.
    @Test("Unsaving removes the row, and restores it when the server refuses")
    func optimisticUnsave() async {
        let first = saved("Prawn spaghetti", at: tipo, placeName: "Tipo 00", minutesAgo: 1)
        let second = saved("Tiramisu", at: tipo, placeName: "Tipo 00", minutesAgo: 2)
        let saves = FakeSaves(pages: [[first, second]])
        let store = SavedDishesStore(saves: saves, pageSize: 10)
        await store.loadIfNeeded()

        await store.unsave(first)
        #expect(store.dishes.map(\.dishID) == [second.dishID])
        #expect(saves.unsaved == [first.dishID])

        saves.refuses = true
        await store.unsave(second)
        #expect(store.dishes.map(\.dishID) == [second.dishID], "a refusal puts the row back")
        #expect(store.phase == .ready)
    }

    /// The caller has things to do that must not happen on a refusal — telling every other list
    /// the dish is gone, and counting a `save_toggled` that never happened.
    @Test("Unsave says whether the server took it")
    func unsaveReportsTheOutcome() async {
        let first = saved("Prawn spaghetti", at: tipo, placeName: "Tipo 00", minutesAgo: 1)
        let second = saved("Tiramisu", at: tipo, placeName: "Tipo 00", minutesAgo: 2)
        let saves = FakeSaves(pages: [[first, second]])
        let store = SavedDishesStore(saves: saves, pageSize: 10)
        await store.loadIfNeeded()

        let landed = await store.unsave(first)
        #expect(landed)
        saves.refuses = true
        let refused = await store.unsave(second)
        #expect(refused == false)
        #expect(store.dishes.map(\.dishID) == [second.dishID], "and the row it kept is still there")
    }

    @Test("Unsaving the last row leaves the empty state")
    func unsaveEverything() async {
        let only = saved("Prawn spaghetti", at: tipo, placeName: "Tipo 00", minutesAgo: 1)
        let store = SavedDishesStore(saves: FakeSaves(pages: [[only]]), pageSize: 10)
        await store.loadIfNeeded()
        await store.unsave(only)
        #expect(store.phase == .empty)
        #expect(store.groups.isEmpty)
    }
}

@Suite("A save is one dish")
struct EntryCardSavesTests {

    private func card(dishes: [(UUID, Bool)]) -> EntryCard {
        EntryCard(
            id: UUID(),
            authorID: UUID(),
            body: "Tipo 00 was good.",
            orderNumber: 1,
            createdAt: Date(timeIntervalSince1970: 1_789_776_000),
            items: dishes.enumerated().map { index, dish in
                EntryCard.Item(reviewID: UUID(), dishID: dish.0, dishName: "Dish \(index)",
                               score: Rating(rounding: 4), position: index + 1, saved: dish.1)
            }
        )
    }

    @Test("Flipping one dish leaves the others alone")
    func flipsOneDish() {
        let first = UUID()
        let second = UUID()
        let entry = card(dishes: [(first, false), (second, false)])
        let updated = entry.settingSaved(dishID: first, to: true)
        #expect(updated.items[0].saved)
        #expect(updated.items[1].saved == false)
        #expect(updated.avgScore == entry.avgScore, "a bookmark is not a score")
    }

    @Test("A card with nothing to change comes back untouched")
    func noChange() {
        let entry = card(dishes: [(UUID(), false)])
        #expect(entry.settingSaved(dishID: UUID(), to: true) == entry)
        #expect(entry.settingSaved(dishID: entry.items[0].dishID, to: false) == entry)
    }

    @Test("An entry with no lines is never 'all saved'")
    func everySaved() {
        let dish = UUID()
        #expect(card(dishes: [(dish, true)]).isEveryDishSaved)
        #expect(card(dishes: [(dish, true), (UUID(), false)]).isEveryDishSaved == false)
        #expect(card(dishes: []).isEveryDishSaved == false)
    }
}
