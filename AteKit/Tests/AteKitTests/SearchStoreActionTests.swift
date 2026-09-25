import Foundation
import Testing

@testable import AteKit

/// The Saved segment's bookmark — the shelf's own unsave, seen from Search — and the saves made
/// everywhere else that this list has to agree with.
@MainActor
@Suite("Search tab — the shelf from here")
struct SearchStoreActionTests {

    private static let debounce = Duration.milliseconds(20)

    private func store(_ service: FakeSearchService, scope: SearchScope = .saved, pageSize: Int = 10) -> SearchStore {
        SearchStore(service: service, scope: scope, pageSize: pageSize, debounce: Self.debounce)
    }

    // MARK: - The shelf, from here

    @Test("unsaving from Saved takes the row away at the tap, and keeps it away when it lands")
    func unsaveLands() async {
        let service = FakeSearchService()
        let roti = SavedDish.fixture("Roti")
        service.seed(saved: [roti, .fixture("Rotisserie chicken")])
        let store = store(service, scope: .saved, pageSize: 10)
        await store.start()
        #expect(store.rows.count == 2)

        var countDuringCall = -1
        await store.unsave(roti) {
            countDuringCall = store.rows.count
            return true
        }

        #expect(countDuringCall == 1, "the row leaves before the round trip, like it does on the shelf")
        #expect(store.rows.count == 1)
    }

    @Test("a refused unsave puts the row back where it was")
    func unsaveRefused() async {
        let service = FakeSearchService()
        let first = SavedDish.fixture("Roti", savedAt: Date(timeIntervalSince1970: 2_000))
        let second = SavedDish.fixture("Rotisserie chicken", savedAt: Date(timeIntervalSince1970: 1_000))
        service.seed(saved: [first, second])
        let store = store(service, scope: .saved, pageSize: 10)
        await store.start()

        await store.unsave(first) { false }

        guard case .saved(let rows) = store.rows else {
            Issue.record("the Saved scope must still be showing saved rows")
            return
        }
        #expect(rows.map(\.dishID) == [first.dishID, second.dishID])
        #expect(store.phase == .ready)
    }

    @Test("the last row going leaves the empty state, not an empty list")
    func unsaveLastRow() async {
        let service = FakeSearchService()
        let only = SavedDish.fixture("Roti")
        service.seed(saved: [only])
        let store = store(service, scope: .saved, pageSize: 10)
        await store.start()

        await store.unsave(only) { true }

        #expect(store.phase == .empty)
    }

    @Test("an unsave made anywhere else takes the dish off this list too")
    func broadcastUnsave() async {
        let service = FakeSearchService()
        let roti = SavedDish.fixture("Roti")
        service.seed(saved: [roti])
        let broadcast = SavedDishBroadcast()
        let store = SearchStore(
            service: service, scope: .saved, pageSize: 10, debounce: Self.debounce, savedDishes: broadcast
        )
        await store.start()

        broadcast.send(dishID: roti.dishID, isSaved: false)

        #expect(store.rows.isEmpty)
    }

    @Test("a save made anywhere else makes the shelf stale, and it is read again when next shown")
    func broadcastSave() async {
        let service = FakeSearchService()
        service.seed(saved: [.fixture("Roti")])
        let broadcast = SavedDishBroadcast()
        let store = SearchStore(
            service: service, scope: .saved, pageSize: 10, debounce: Self.debounce, savedDishes: broadcast
        )
        await store.start()
        #expect(service.calls(for: .saved).count == 1)

        broadcast.send(dishID: UUID(), isSaved: true)
        await store.start()

        #expect(service.calls(for: .saved).count == 2)
    }

    @Test("an empty shelf is not a search — so it is not 'nothing found'")
    func emptyShelfIsNotASearch() async {
        let service = FakeSearchService()
        let store = store(service, scope: .saved, pageSize: 10)
        await store.start()

        #expect(store.phase == .empty)
        #expect(store.isSearching == false)

        store.query = "ro"
        #expect(store.isSearching)
    }
}
