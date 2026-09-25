import Foundation
import Testing

@testable import AteKit

@MainActor
@Suite("Search tab")
struct SearchStoreTests {

    /// A debounce short enough not to slow the suite down, long enough that three keystrokes land
    /// inside one window. Every assertion below waits on the store's own task rather than sleeping,
    /// so the number only has to be non-zero.
    private static let debounce = Duration.milliseconds(20)

    private func store(
        _ service: FakeSearchService,
        scope: SearchScope = .places,
        pageSize: Int = 2,
        debounce: Duration = SearchStoreTests.debounce,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) -> SearchStore {
        SearchStore(
            service: service, scope: scope, pageSize: pageSize, debounce: debounce, analytics: analytics
        )
    }

    private let melbourne = SearchOrigin(latitude: -37.8118, longitude: 144.9629)

    // MARK: - The zero state

    @Test("with nothing typed, Places shows Nearby and nothing else reads anything")
    func nearbyIsTheZeroState() async {
        let service = FakeSearchService()
        service.seed(nearby: [.fixture("Tipo 00"), .fixture("Osteria Ilaria")])
        let store = store(service)

        await store.setOrigin(melbourne)
        await store.start()

        #expect(store.rows.count == 2)
        #expect(store.isShowingNearby)
        #expect(store.phase == .ready)
        #expect(service.calls == [.init(scope: .places, query: nil, offset: 0)])
    }

    @Test("no location means no Nearby section — not an empty one, and not a word about it")
    func nearbyWithoutALocation() async {
        let service = FakeSearchService()
        service.seed(nearby: [.fixture("Tipo 00")])
        let store = store(service)

        await store.start()

        #expect(store.rows.isEmpty)
        #expect(store.isShowingNearby == false)
        // Nothing was asked of the server: an origin is what the read is made with.
        #expect(service.calls.isEmpty)
    }

    @Test("Dishes and People say nothing until something is typed")
    func typedScopesHaveNoStandingList() async {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Roast duck")], people: [.fixture("crumbsmelb")])
        let store = store(service, scope: .dishes)

        await store.start()
        #expect(store.phase == .idle)
        #expect(store.rows.isEmpty)

        store.select(.people)
        await store.settle()
        #expect(store.phase == .idle)
        #expect(service.calls.isEmpty)
    }

    @Test("one character is below the gate and costs no request")
    func minimumLength() async {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Roast duck")])
        let store = store(service, scope: .dishes)

        store.query = "d"
        await store.settle()

        #expect(service.calls.isEmpty)
        #expect(store.rows.isEmpty)
    }

    @Test("one letter on the shelf is still the whole shelf; two filter it — the server's floor")
    func savedFiltersFromTwoCharacters() async {
        let service = FakeSearchService()
        service.seed(saved: [.fixture("Roti"), .fixture("Pad see ew", savedAt: .distantPast)])
        let store = store(service, scope: .saved)

        store.query = "r"
        await store.settle()
        #expect(store.rows.count == 2)
        #expect(store.isSearching == false)

        store.query = "ro"
        await store.settle()
        #expect(store.rows.count == 1)
        #expect(service.calls.last == .init(scope: .saved, query: "ro", offset: 0))
    }

    // MARK: - Debounce

    @Test("a burst of keystrokes is one request, for the last thing typed")
    func debounceCoalesces() async {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Duck bao"), .fixture("Roast duck")])
        let store = store(service, scope: .dishes)

        store.query = "du"
        store.query = "duc"
        store.query = "duck"
        await store.settle()

        #expect(service.calls == [.init(scope: .dishes, query: "duck", offset: 0)])
        #expect(store.rows.count == 2)
    }

    @Test("the query is trimmed before it is sent, and whitespace alone is not a query")
    func normalisation() async {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Roast duck")])
        let store = store(service, scope: .dishes)

        store.query = "  duck  "
        await store.settle()
        #expect(service.calls == [.init(scope: .dishes, query: "duck", offset: 0)])

        store.query = "   "
        await store.settle()
        #expect(service.calls.count == 1)
        #expect(store.phase == .idle)
    }

    // MARK: - Scope switching

    @Test("switching scope re-asks the same query in the new scope, with no debounce")
    func scopeSwitchRunsTheQuery() async {
        let service = FakeSearchService()
        service.seed(
            places: [.fixture("Duck Duck Goose")],
            dishes: [.fixture("Roast duck")],
            people: [.fixture("duckhunter")]
        )
        let store = store(service, scope: .dishes)

        store.query = "duck"
        await store.settle()
        #expect(store.rows.count == 1)

        store.select(.people)
        await store.settle()
        #expect(store.scope == .people)
        #expect(store.rows.count == 1)
        #expect(service.calls.last == .init(scope: .people, query: "duck", offset: 0))
    }

    @Test("switching back shows what was already there and reads nothing")
    func scopeSwitchKeepsItsPage() async {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Roast duck")], people: [.fixture("duckhunter")])
        let store = store(service, scope: .dishes)

        store.query = "duck"
        await store.settle()
        store.select(.people)
        await store.settle()
        let callsAfterPeople = service.callCount

        store.select(.dishes)
        await store.settle()

        #expect(store.rows.count == 1)
        #expect(store.phase == .ready)
        #expect(service.callCount == callsAfterPeople)
    }

    @Test("a new query invalidates every scope, not just the one on screen")
    func newQueryInvalidatesTheOthers() async {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Roast duck")], people: [.fixture("duckhunter")])
        let store = store(service, scope: .dishes)

        store.query = "duck"
        await store.settle()
        store.select(.people)
        await store.settle()
        store.select(.dishes)
        await store.settle()

        store.query = "roast"
        await store.settle()
        store.select(.people)
        await store.settle()

        #expect(service.calls.last == .init(scope: .people, query: "roast", offset: 0))
    }

    // MARK: - Paging

    @Test("dishes page forward, and a page never repeats a row")
    func dishesPage() async {
        let service = FakeSearchService()
        service.seed(dishes: (1...5).map { .fixture("Duck \($0)") })
        let store = store(service, scope: .dishes, pageSize: 2)

        store.query = "duck"
        await store.settle()
        #expect(store.rows.count == 2)
        #expect(store.hasReachedEnd == false)

        await store.loadMore()
        #expect(store.rows.count == 4)
        await store.loadMore()
        #expect(store.rows.count == 5)
        #expect(store.hasReachedEnd)

        // The last page was short, so nothing more is asked for however hard the list is scrolled.
        await store.loadMore()
        #expect(service.calls(for: .dishes).map(\.offset) == [0, 2, 4])
        if case .dishes(let rows) = store.rows {
            #expect(Set(rows.map(\.dishID)).count == rows.count)
        } else {
            Issue.record("expected dish rows")
        }
    }

    @Test("the shelf pages on its keyset cursor, carrying the filter with it")
    func savedPages() async {
        let service = FakeSearchService()
        let base = Date(timeIntervalSince1970: 1_789_776_000)
        service.seed(saved: (1...5).map { .fixture("Roti \($0)", savedAt: base.addingTimeInterval(Double(-$0))) })
        let store = store(service, scope: .saved, pageSize: 2)

        store.query = "roti"
        await store.settle()
        #expect(store.rows.count == 2)

        await store.loadMore()
        #expect(store.rows.count == 4)
        #expect(service.calls(for: .saved).map(\.query) == ["roti", "roti"])
    }

    @Test("prefetch only fires near the end of what is on screen")
    func prefetchDistance() async {
        let service = FakeSearchService()
        service.seed(dishes: (1...30).map { .fixture("Duck \($0)") })
        let store = store(service, scope: .dishes, pageSize: 12)

        store.query = "duck"
        await store.settle()
        let afterFirstPage = service.callCount

        await store.loadMoreIfNeeded(index: 0)
        #expect(service.callCount == afterFirstPage)

        await store.loadMoreIfNeeded(index: 11)
        #expect(service.callCount == afterFirstPage + 1)
    }

    @Test("places page too, on the last row's key, and stop at a short page")
    func placesPage() async {
        let service = FakeSearchService()
        service.seed(places: [.fixture("Tipo 00"), .fixture("Tipo Due"), .fixture("Tipo Tre")])
        let store = store(service, scope: .places, pageSize: 2)

        store.query = "tipo"
        await store.settle()
        await store.loadMore()

        #expect(store.rows.count == 3)
        #expect(store.hasReachedEnd)
        #expect(service.calls(for: .places).map(\.offset) == [0, 2])
    }

    @Test("Nearby pages from where the phone is, and stays Nearby as it does")
    func nearbyPages() async {
        let service = FakeSearchService()
        service.seed(nearby: (1...3).map { .fixture("Place \($0)") })
        let store = store(service, scope: .places, pageSize: 2)

        await store.setOrigin(melbourne)
        await store.start()
        await store.loadMore()

        #expect(store.rows.count == 3)
        #expect(store.isShowingNearby)
        #expect(service.calls.map(\.query) == [nil, nil], "a second Nearby page is not a search")
    }

    // MARK: - Empty, failed, stale

    @Test("a query that finds nothing is empty, not failed")
    func emptyResults() async {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Roast duck")])
        let store = store(service, scope: .dishes)

        store.query = "tiramisu"
        await store.settle()

        #expect(store.phase == .empty)
        #expect(store.rows.isEmpty)
    }

    @Test("a refused read fails with a line, and leaves no half-list behind")
    func failure() async {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Roast duck")])
        service.fail(.init(message: "offline"))
        let store = store(service, scope: .dishes)

        store.query = "duck"
        await store.settle()

        #expect(store.rows.isEmpty)
        #expect(store.phase == .failed(message: "Couldn't\nsearch."))
    }

    @Test("signed out says so rather than blaming the network")
    func signedOut() async {
        #expect(SearchStore.failureMessage(AteAPIError.notAuthenticated) == "Nobody's\nsigned in.")
    }

    @Test("an origin that arrives after the screen did loads Nearby by itself")
    func lateOrigin() async {
        let service = FakeSearchService()
        service.seed(nearby: [.fixture("Tipo 00")])
        let store = store(service)

        await store.start()
        #expect(store.rows.isEmpty)

        await store.setOrigin(melbourne)
        #expect(store.rows.count == 1)
        #expect(store.isShowingNearby)
    }

    @Test("a location arriving while a query is on screen does not replace the results with Nearby")
    func lateOriginDoesNotClobberAQuery() async {
        let service = FakeSearchService()
        service.seed(places: [.fixture("Tipo 00")], nearby: [.fixture("Osteria Ilaria")])
        let store = store(service)

        store.query = "tipo"
        await store.settle()
        await store.setOrigin(melbourne)

        #expect(store.isShowingNearby == false)
        #expect(service.calls.contains(.init(scope: .places, query: nil, offset: 0)) == false)
    }

    // MARK: - Telemetry

    @Test("a completed query reports its scope, length and count — once")
    func searchPerformed() async {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Duck bao"), .fixture("Roast duck")])
        let log = EventLog()
        let store = store(service, scope: .dishes, analytics: log.recorder)

        store.query = "du"
        store.query = "duck"
        await store.settle()

        let events = log.events(named: "search_performed")
        #expect(events.count == 1)
        #expect(events.first?.parameters["scope"] == "dishes")
        #expect(events.first?.parameters["query_length"] == "4")
        #expect(events.first?.parameters["result_count"] == "2")
    }

    @Test("the standing lists are not searches and are not counted")
    func nearbyIsNotASearch() async {
        let service = FakeSearchService()
        service.seed(nearby: [.fixture("Tipo 00")])
        let log = EventLog()
        let store = store(service, analytics: log.recorder)

        await store.setOrigin(melbourne)
        await store.start()

        #expect(log.names.contains("search_performed") == false)
    }

    @Test("a second page does not count as a second search")
    func pagingIsNotASearch() async {
        let service = FakeSearchService()
        service.seed(dishes: (1...5).map { .fixture("Duck \($0)") })
        let log = EventLog()
        let store = store(service, scope: .dishes, pageSize: 2, analytics: log.recorder)

        store.query = "duck"
        await store.settle()
        await store.loadMore()

        #expect(log.events(named: "search_performed").count == 1)
    }

    @Test("opening a row reports the scope it was opened from")
    func resultOpened() async {
        let service = FakeSearchService()
        let log = EventLog()
        let store = store(service, scope: .people, analytics: log.recorder)

        store.reportOpened()

        #expect(log.all.last?.name == "search_result_opened")
        #expect(log.all.last?.parameters["scope"] == "people")
    }
}
