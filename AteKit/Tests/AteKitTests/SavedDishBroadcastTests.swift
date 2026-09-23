import Foundation
import Testing
@testable import AteKit

@MainActor
private final class Listener: SavedDishObserving {
    private(set) var heard: [(UUID, Bool)] = []

    func savedDishChanged(dishID: UUID, isSaved: Bool) {
        heard.append((dishID, isSaved))
    }
}

@MainActor
@Suite("Saved dish broadcast")
struct SavedDishBroadcastTests {

    @Test("Everything listening hears the same answer about the same dish")
    func broadcasts() {
        let broadcast = SavedDishBroadcast()
        let first = Listener()
        let second = Listener()
        broadcast.add(first)
        broadcast.add(second)

        let dish = UUID()
        broadcast.send(dishID: dish, isSaved: true)
        #expect(first.heard.count == 1)
        #expect(second.heard.count == 1)
        #expect(first.heard[0].0 == dish)
        #expect(first.heard[0].1)
    }

    @Test("Registering twice does not double up")
    func idempotentRegistration() {
        let broadcast = SavedDishBroadcast()
        let listener = Listener()
        broadcast.add(listener)
        broadcast.add(listener)
        broadcast.send(dishID: UUID(), isSaved: true)
        #expect(listener.heard.count == 1)
        #expect(broadcast.observerCount == 1)
    }

    /// A profile popped off the stack unregisters by being deallocated — the only deregistration
    /// that cannot be forgotten.
    @Test("A listener that has gone away stops listening, and is pruned")
    func weakness() {
        let broadcast = SavedDishBroadcast()
        let kept = Listener()
        broadcast.add(kept)
        do {
            let temporary = Listener()
            broadcast.add(temporary)
            #expect(broadcast.observerCount == 2)
        }
        broadcast.send(dishID: UUID(), isSaved: false)
        #expect(broadcast.observerCount == 1)
        #expect(kept.heard.count == 1)
    }

    /// The bug QA found: feed → byline → profile → their entry → toggle → Back showed a stale
    /// bookmark, because the propagation was a hand-maintained list of stores and the profile was
    /// not on it. Now every list that draws a bookmark is told, whoever made the change.
    @Test("A list opened from another list agrees about a dish toggled on a third screen")
    func everyListAgrees() async {
        let broadcast = SavedDishBroadcast()
        let dish = UUID()
        let feedRows = [card(dish: dish), card(dish: UUID())]
        let feed = EntryListStore(
            pageSize: 10, fallbackMessage: "…", savedDishes: broadcast
        ) { _, size in Page(items: feedRows, requestedLimit: size) }
        let profile = EntryListStore(
            pageSize: 10, fallbackMessage: "…", savedDishes: broadcast
        ) { _, size in Page(items: [feedRows[0]], requestedLimit: size) }
        await feed.loadIfNeeded()
        await profile.loadIfNeeded()

        broadcast.send(dishID: dish, isSaved: true)
        #expect(feed.entries[0].items.allSatisfy { $0.saved })
        #expect(profile.entries[0].items.allSatisfy { $0.saved })
        #expect(feed.entries[1].items.contains { $0.saved } == false, "only that dish moved")

        broadcast.send(dishID: dish, isSaved: false)
        #expect(feed.entries[0].items.contains { $0.saved } == false)
        #expect(profile.entries[0].items.contains { $0.saved } == false)
    }

    private func card(dish: UUID) -> EntryCard {
        EntryCard(
            id: UUID(),
            authorID: UUID(),
            body: "Tipo 00 was good.",
            orderNumber: 1,
            sortStatus: .sorted,
            createdAt: Date(timeIntervalSince1970: 1_789_776_000),
            isMine: false,
            items: [EntryCard.Item(reviewID: UUID(), dishID: dish, dishName: "Prawn spaghetti",
                                   score: Rating(rounding: 5), position: 1)]
        )
    }
}
