import Foundation
import Testing
@testable import AteKit

/// The Search tab's scopes and filters.
@MainActor
@Suite("Search — scopes and filters")
struct SearchFilterTests {
    private func searchStore(_ service: FakeSearchService, analytics: @escaping AnalyticsRecorder = { _ in })
        -> SearchStore {
        SearchStore(service: service, pageSize: 20, debounce: .milliseconds(5), analytics: analytics)
    }

    @Test("the scopes show once typing starts, and clearing the field goes back to Places")
    func scopesAppearWithTyping() async {
        let service = FakeSearchService()
        let store = searchStore(service)
        #expect(store.showsScopes == false)
        store.query = "r"
        #expect(store.showsScopes)
        store.select(.people)
        store.query = ""
        #expect(store.showsScopes == false)
        #expect(store.scope == .places)
    }

    @Test("filters reach the filtered reads, re-ask the scope on screen, and are counted")
    func filtersReachTheRead() async {
        let service = FakeSearchService()
        service.seed(dishes: [.fixture("Ragu", score: 4.6), .fixture("Ragu bianco", score: 3.2)])
        let log = EventLog()
        let store = searchStore(service, analytics: log.recorder)
        store.select(.dishes)
        store.query = "ragu"
        await store.settle()
        #expect(store.rows.count == 2)

        let bar = SearchFilters(minimumScore: 4.0)
        store.setFilters(bar)
        await store.settle()
        #expect(service.filtersAsked.last == bar)
        #expect(store.rows.count == 1)
        #expect(log.first(named: "search_filtered")?.parameters["min_score"] == "4.0")
    }

    /// Round 5 reverses round 4's rule (QA on #84): a pill over Nearby is a filter on Nearby.
    @Test("Nearby is narrowed by the filters too (round 5)")
    func nearbyFiltered() async {
        let service = FakeSearchService()
        service.seed(nearby: [.fixture("Tipo 00", score: nil)])
        let store = searchStore(service)
        store.setFilters(SearchFilters(minimumScore: 4.5))
        await store.setOrigin(SearchOrigin(latitude: -37.8, longitude: 144.9))
        await store.start()
        #expect(service.filtersAsked.last == SearchFilters(minimumScore: 4.5), "Nearby is asked with the filters")
        #expect(store.rows.isEmpty, "an unscored place never clears 4.5")
    }

    @Test("a filter set toggles, keeps its order canonical, and prints its pills without a dot")
    func filterValues() {
        var filters = SearchFilters.none
        #expect(filters.isEmpty)
        filters = filters.toggling(tag: .vg).toggling(tag: .gf)
        #expect(filters.tags == [.gf, .vg])
        #expect(filters.tagSummary == "GF VG")
        filters = filters.toggling(cuisine: "Italian").toggling(cuisine: "Japanese").toggling(cuisine: "italian")
        #expect(filters.cuisines == ["Japanese"])
        filters = filters.toggling(cuisine: "Thai")
        #expect(filters.cuisineSummary == "Japanese +1")
        filters.minimumScore = 3.5
        #expect(filters.scoreSummary == "3.5+")
        #expect(filters.count == 5)
        let wire = filters.parameters
        #expect(wire["p_tags"] == .array([.string("gf"), .string("vg")]))
        #expect(wire["p_min_score"] == .double(3.5))
        #expect(SearchFilters.none.parameters.isEmpty, "no filter is the unfiltered call, unchanged")
        #expect(SearchFilters.applies(to: .people) == false)
    }

    @Test("several tags: a dish carries all of them; a place needs one dish that does (backend #71)")
    func tagsMeanAll() {
        let both = SearchFilters(tags: [.gf, .v])
        #expect(both.dishMatchesTags([.gf, .v, .nf]))
        #expect(both.dishMatchesTags([.gf]) == false)
        #expect(both.placeMatchesTags(dishTags: [[.gf], [.v]]) == false, "two dishes between them is not one")
        #expect(both.placeMatchesTags(dishTags: [[.gf], [.v, .gf]]))
        #expect(SearchFilters.none.placeMatchesTags(dishTags: []))
        #expect(SearchFilters.none.dishMatchesTags([]))
    }

    @Test("a reader that cannot filter answers nothing rather than an unfiltered list")
    func honestDefault() async throws {
        struct Plain: SearchReading, TestFake {
            func places(query: String, after cursor: SearchCursor?, pageSize: Int) async throws
                -> SearchPage<PlaceResult> { SearchPage(rows: [.fixture("Tipo 00")], next: nil) }
        }
        let plain = Plain()
        #expect(try await plain.places(query: "tipo", filters: .none, after: nil, pageSize: 5).rows.count == 1)
        let narrowed = try await plain.places(
            query: "tipo", filters: SearchFilters(tags: [.v]), after: nil, pageSize: 5
        )
        #expect(narrowed.rows.isEmpty)
    }

    @Test("the in-memory search applies the contract: cuisine, any-dish tag, and a scored bar")
    func inMemoryFilters() async throws {
        let social = InMemorySocialService.seededWithSaves()
        let italian = try await social.places(
            query: "i", filters: SearchFilters(cuisines: ["italian"]), after: nil, pageSize: 20
        )
        #expect(italian.rows.map(\.name) == ["Tipo 00"])
        let vegetarian = try await social.dishes(
            query: "a", filters: SearchFilters(tags: [.v]), after: nil, pageSize: 20
        )
        #expect(vegetarian.rows.map(\.name).contains("Raspberry cake"))
        #expect(vegetarian.rows.allSatisfy { $0.tags.contains(.v) })
        let glutenFreeDairyFree = try await social.places(
            query: "i", filters: SearchFilters(tags: [.gf, .df]), after: nil, pageSize: 20
        )
        #expect(glutenFreeDairyFree.rows.map(\.name) == ["Kisume"], "the salmon roll carries both")
        let cuisines = try await social.cuisines()
        #expect(cuisines.map(\.cuisine).contains("Japanese"))
    }

    @Test("search filters become pills — each cuisine, each tag, the score — and each removes itself")
    func searchPills() {
        let filters = SearchFilters(cuisines: ["Italian", "Thai"], tags: [.v, .gf], minimumScore: 4)
        #expect(filters.pills.map(\.title) == ["Italian", "Thai", "GF", "V", "4.0+"])
        #expect(Set(filters.pills.map(\.id)).count == 5)
        let noThai = filters.removing(filters.pills[1])
        #expect(noThai.cuisines == ["Italian"] && noThai.tags == [.gf, .v] && noThai.minimumScore == 4)
        let noGF = filters.removing(filters.pills[2])
        #expect(noGF.tags == [.v])
        let noScore = filters.removing(filters.pills[4])
        #expect(noScore.minimumScore == nil && noScore.count == 4)
        #expect(SearchFilters.none.pills.isEmpty)
    }

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
}

/// QA on #84: filters on the lists shown before anything is typed.
@MainActor
@Suite("Search — filters with nothing typed")
struct SearchUntypedFilterTests {
    @Test("a filter narrows Nearby with nothing typed — the pill never sits over unfiltered rows")
    func nearbyFiltered() async {
        let service = FakeSearchService()
        service.seed(nearby: [.fixture("Tipo 00", score: 4.6), .fixture("Etta", score: 3.9)])
        let store = SearchStore(service: service, scope: .places, pageSize: 10, debounce: .milliseconds(20))
        await store.setOrigin(SearchOrigin(latitude: -37.81, longitude: 144.96))
        #expect(store.rows.count == 2 && store.isShowingNearby)
        let filters = SearchFilters(minimumScore: 4.5)
        store.setFilters(filters)
        await store.settle()
        #expect(service.filtersAsked.last == filters, "Nearby was read again, with the filter")
        #expect(store.rows.count == 1, "and only what clears it is left")
    }

    @Test("a filter narrows the Saved shelf with nothing typed")
    func savedFiltered() async {
        let service = FakeSearchService()
        service.seed(saved: [.fixture("Ragù", score: 4.6), .fixture("Toast", score: 3.5)])
        let store = SearchStore(service: service, scope: .saved, pageSize: 10, debounce: .milliseconds(20))
        await store.start()
        #expect(store.rows.count == 2)
        let filters = SearchFilters(minimumScore: 4.5)
        store.setFilters(filters)
        await store.settle()
        #expect(service.filtersAsked.last == filters, "the shelf was read again, with the filter")
        #expect(store.rows.count == 1, "and only what clears it is left")
    }
}
