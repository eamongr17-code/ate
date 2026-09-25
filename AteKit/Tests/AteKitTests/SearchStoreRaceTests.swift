import Foundation
import Testing

@testable import AteKit

/// **The three defects QA found in 05fd883, each replayed in QA's own sequence.** Every one of them
/// is about a request that is still in the air when the person does something else — so each test
/// holds a read open with the fake's latency and acts while it is.
@MainActor
@Suite("Search tab — in-flight requests and the location that isn't there yet")
struct SearchStoreRaceTests {

    private static let debounce = Duration.milliseconds(20)
    private let melbourne = SearchOrigin(latitude: -37.8118, longitude: 144.9629)

    private func store(_ service: FakeSearchService, scope: SearchScope, pageSize: Int = 10) -> SearchStore {
        SearchStore(service: service, scope: scope, pageSize: pageSize, debounce: Self.debounce)
    }

    private func names(_ rows: SearchRows) -> [String] {
        switch rows {
        case .places(let rows): rows.map(\.name)
        case .dishes(let rows): rows.map(\.name)
        case .people(let rows): rows.map(\.handle)
        case .saved(let rows): rows.map(\.dishName)
        }
    }

    // MARK: - 1. Stale results on scope return

    @Test("'pi', then 'pizza', off to Dishes mid-flight and back: Places re-asks 'pizza' and shows its rows")
    func staleRowsOnReturn() async {
        let service = FakeSearchService()
        service.seed(
            places: [.fixture("Pizza Religion"), .fixture("Pie Face")],
            dishes: [.fixture("Pizza bianca")]
        )
        let store = store(service, scope: .places)

        store.query = "pi"
        await store.settle()
        #expect(names(store.rows) == ["Pizza Religion", "Pie Face"])

        // "pizza" goes out for Places and is still in the air when Dishes is tapped. Leaving cancels
        // it — and the cancel surfaces the way URLSession surfaces one.
        service.setLatency(.milliseconds(300), for: .places)
        store.query = "pizza"
        await service.waitForCall { $0.scope == .places && $0.query == "pizza" }
        store.select(.dishes)
        await store.settle()
        #expect(names(store.rows) == ["Pizza bianca"])

        service.setLatency(nil, for: .places)
        store.select(.places)
        await store.settle()

        #expect(names(store.rows) == ["Pizza Religion"], "never 'pi's rows under 'pizza'")
        #expect(store.phase == .ready, "a cancel is not 'Couldn't search.'")
        #expect(service.calls(for: .places).filter { $0.query == "pizza" }.count == 2, "it was asked again")
    }

    @Test("a cancelled first load is not a failure: coming back loads it, with no error in between")
    func cancelIsNotAnError() async {
        let service = FakeSearchService()
        service.seed(places: [.fixture("Pizza Religion")])
        service.setLatency(.milliseconds(300), for: .places)
        let store = store(service, scope: .places)

        store.query = "pizza"
        await service.waitForCall { $0.scope == .places }
        store.select(.dishes)
        await store.settle()

        // URLSession's cancel is read as a cancel, not a refusal.
        #expect(SearchStore.isCancellation(URLError(.cancelled)))
        service.setLatency(nil, for: .places)
        store.select(.places)
        #expect(store.phase != .failed(message: "Couldn't\nsearch."))
        await store.settle()
        #expect(names(store.rows) == ["Pizza Religion"])
        #expect(store.phase == .ready)
    }

    // MARK: - 2. A page landing in the wrong scope

    @Test("a Places page in the air when Dishes is tapped never lands in Dishes")
    func pageLandsInItsOwnScope() async {
        let service = FakeSearchService()
        service.seed(
            places: [.fixture("Tipo 00"), .fixture("Tipo Due"), .fixture("Tipo Tre")],
            dishes: [.fixture("Tipo toast"), .fixture("Tipo tart")]
        )
        let store = store(service, scope: .places, pageSize: 2)

        store.query = "tipo"
        await store.settle()
        store.select(.dishes)
        await store.settle()
        store.select(.places)
        await store.settle()
        #expect(store.rows.count == 2)

        // Page two of Places goes out; Dishes — already loaded, so nothing new is asked — is tapped.
        service.setLatency(.milliseconds(150), for: .places)
        let paging = Task { await store.loadMore() }
        await service.waitForCall { $0.scope == .places && $0.offset == 2 }
        store.select(.dishes)
        await paging.value

        #expect(store.rows.scope == .dishes)
        #expect(names(store.rows) == ["Tipo toast", "Tipo tart"], "no Places row in the Dishes list")

        // Places kept its own first page and its cursor: scrolling it again asks for page two again.
        service.setLatency(nil, for: .places)
        store.select(.places)
        await store.settle()
        #expect(names(store.rows) == ["Tipo 00", "Tipo Due"])
        await store.loadMore()
        #expect(names(store.rows) == ["Tipo 00", "Tipo Due", "Tipo Tre"])
    }

    // MARK: - 3. No location is not "nothing found"

    @Test("while the location is undecided, Places shows nothing — not 'Nothing found', not a request")
    func undecidedLocation() async {
        let service = FakeSearchService()
        service.seed(nearby: [.fixture("Tipo 00")])
        let store = store(service, scope: .places)

        await store.start()

        #expect(store.phase == .idle, "the permission prompt is up; nothing has been found or not found")
        #expect(store.rows.isEmpty)
        #expect(store.isShowingNearby == false)
        #expect(service.calls.isEmpty)
    }

    @Test("a refused location leaves just the field and the pills")
    func refusedLocation() async {
        let service = FakeSearchService()
        service.seed(nearby: [.fixture("Tipo 00")])
        let store = store(service, scope: .places)

        await store.start()
        await store.setOrigin(nil)

        #expect(store.phase == .idle)
        #expect(store.rows.isEmpty)
        #expect(service.calls.isEmpty)
    }

    @Test("a location that arrives while another scope is up is used when Places comes back")
    func lateLocationWhileAway() async {
        let service = FakeSearchService()
        service.seed(nearby: [.fixture("Tipo 00")])
        let store = store(service, scope: .places)

        await store.start()
        store.select(.saved)
        await store.settle()
        await store.setOrigin(melbourne)
        store.select(.places)
        await store.settle()

        #expect(names(store.rows) == ["Tipo 00"])
        #expect(store.isShowingNearby)
    }
}
