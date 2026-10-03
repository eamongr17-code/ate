import Foundation
import Testing

@testable import AteKit

/// What the rebuilt Search tab asks of ``SearchStore`` beyond the current tab: a switch that stays
/// where it was put, and the filter sheet's live count.
@MainActor
@Suite("Search — the rebuilt tab")
struct SearchStoreRebuildTests {
    private func searchStore(_ service: FakeSearchService) -> SearchStore {
        SearchStore(service: service, scope: .dishes, pageSize: 20, debounce: .milliseconds(5), clearsTo: nil)
    }

    @Test("clearing the field keeps the scope that was chosen")
    func clearingKeepsTheScope() async {
        let store = searchStore(FakeSearchService())
        store.select(.people)
        store.query = "je"
        store.query = ""
        #expect(store.scope == .people)
    }

    @Test("the current tab still goes back to Places")
    func currentTabStillClearsToPlaces() async {
        let store = SearchStore(service: FakeSearchService(), debounce: .milliseconds(5))
        store.select(.people)
        store.query = "je"
        store.query = ""
        #expect(store.scope == .places)
    }

    @Test("the count is what the draft would leave, capped, for the words in the field")
    func countFollowsTheDraft() async throws {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Ragu", score: 4.6), .fixture("Ragu bianco", score: 3.2)])
        let store = searchStore(service)
        store.query = "ragu"
        await store.settle()

        #expect(try await store.count(with: .none, cap: 50) == 2)
        #expect(try await store.count(with: SearchFilters(minimumScore: 4.0), cap: 50) == 1)
        #expect(try await store.count(with: .none, cap: 1) == 1)
        // A count never changes what is on screen.
        #expect(store.rows.count == 2)
        #expect(store.filters == .none)
    }

    @Test("nothing to count: People, or Dishes with nothing typed")
    func nothingToCount() async throws {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Ragu", score: 4.6)])
        let store = searchStore(service)
        #expect(try await store.count(with: .none, cap: 50) == nil)
        store.select(.people)
        store.query = "ragu"
        #expect(try await store.count(with: .none, cap: 50) == nil)
    }
}
