import Foundation
import Testing

@testable import AteKit

/// Round 4, the detail and search lane: dish tags on every dish surface, the secret 6 in the chart,
/// staged loading, and the Search tab's scopes and filters.
@MainActor
@Suite("Round 4 — detail and search")
struct DetailRound4Tests {

    // MARK: - Dietary tags

    @Test("a dish's tags are the codes at least half of its lines carry, in canonical order")
    func consensus() {
        #expect(DishTagConsensus.tags(lines: []) == [])
        #expect(DishTagConsensus.tags(lines: [[]]) == [])
        #expect(DishTagConsensus.tags(lines: [[.v], []]) == [.v])
        #expect(DishTagConsensus.tags(lines: [[.v], [], []]) == [])
        #expect(DishTagConsensus.tags(lines: [[.vg, .gf], [.gf]]) == [.gf, .vg])
    }

    @Test("dish_summary's tags decode; an older header without them has none")
    func dishSummaryTags() throws {
        let id = UUID()
        let place = UUID()
        let base = #"{"dish_id":"\#(id)","dish_name":"Tiramisu","restaurant_id":"\#(place)","#
            + #""restaurant_name":"Tipo 00""#
        let tagged = try PostgRESTDate.decoder.decode(
            DishSummary.self, from: Data((base + #","tags":["v","xx","gf"]}"#).utf8)
        )
        #expect(tagged.tags == [.v, .gf])
        let untagged = try PostgRESTDate.decoder.decode(DishSummary.self, from: Data((base + "}").utf8))
        #expect(untagged.tags.isEmpty)
    }

    @Test("a menu line decodes with or without tags — place_dishes does not carry them yet")
    func menuTags() throws {
        let row = #"{"dish_id":"\#(UUID())","dish_name":"Tiramisu","score":4.2,"#
            + #""people_count":3,"review_count":4,"cover_url":null"#
        let without = try JSONDecoder().decode(MenuDish.self, from: Data((row + "}").utf8))
        #expect(without.tags.isEmpty)
        #expect(without.score == 4.2)
        let with = try JSONDecoder().decode(MenuDish.self, from: Data((row + #","tags":["vg"]}"#).utf8))
        #expect(with.tags == [.vg])
    }

    @Test("the in-memory pages derive consensus tags from the seeded lines")
    func inMemoryTags() async throws {
        let social = InMemorySocialService.seededWithSaves()
        let tipo = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!
        let menu = try await social.placeDishes(restaurantID: tipo, after: nil, pageSize: 50)
        let prawn = try #require(menu.items.first { $0.name == "Prawn spaghetti" })
        #expect(prawn.tags == [.gf])
        let summary = try await social.dishSummary(dishID: prawn.dishID)
        #expect(summary.tags == [.gf])
    }

    // MARK: - Secret 6

    @Test("the histogram carries a 6 bucket, and draws its bar only once a 6 exists")
    func sixBucket() {
        let none = ScoreHistogram([ScoreBucket(score: 4.5, dishCount: 3, reviewCount: 3)])
        #expect(none.buckets.count == 11)
        #expect(none.buckets.last?.score == 6.0)
        #expect(none.drawnScores.count == 10)
        #expect(none.drawnScores.last == 5.0)

        let six = ScoreHistogram([
            ScoreBucket(score: 4.5, dishCount: 3, reviewCount: 3),
            ScoreBucket(score: 6.0, dishCount: 1, reviewCount: 2),
            // Off the grid: there is no 5.5.
            ScoreBucket(score: 5.5, dishCount: 9, reviewCount: 9)
        ])
        #expect(six.dishCount(at: 6.0) == 1)
        #expect(six.dishCount(at: 5.5) == 0)
        #expect(six.drawnScores.last == 6.0)
        #expect(six.highestScore == 6.0)
        #expect(six.total == 4)
    }

    @Test("a 6 snaps to itself; nothing lands on a 5.5")
    func sixSnaps() {
        #expect(ScoreHistogram.snapped(6.0) == 6.0)
        #expect(ScoreHistogram.snapped(7.0) == 6.0)
        #expect(ScoreHistogram.snapped(5.0) == 5.0)
        #expect(ScoreHistogram.snapped(5.4) == 5.0)
        #expect(ScoreFormat.halfStep(6.0) == "6.0")
        #expect(ScoreFormat.average(6.0) == "6.0")
    }

    @Test("Ratings opens on the 6 group first, and settles once")
    func ratingsSix() async {
        let store = RatingsStore(score: 6.0, stats: InMemoryStatsService())
        #expect(store.isSettled == false)
        await store.loadIfNeeded()
        #expect(store.isSettled)
        #expect(store.groups.first?.score == 6.0)
    }

    // MARK: - Staged loading

    @Test("a dish page settles only once its header and first reviews are both in")
    func dishSettles() async throws {
        let social = InMemorySocialService.seededWithSaves()
        let tipo = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!
        let dishID = try #require(try await social.placeDishes(restaurantID: tipo, after: nil, pageSize: 5).items.first)
            .dishID
        let store = DishPageStore(dishID: dishID, source: .unknown, dishes: social)
        #expect(store.isSettled == false)
        await store.load()
        #expect(store.isSettled)
    }

    @Test("a place page settles once header, menu and both visit lists are in")
    func placeSettles() async {
        let social = InMemorySocialService.seededWithSaves()
        let tipo = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!
        let store = PlacePageStore(restaurantID: tipo, source: .unknown, places: social)
        #expect(store.isSettled == false)
        await store.load()
        #expect(store.isSettled)
    }

    /// A place and a dish with nothing written about them, whose lists answer slowly once told to —
    /// so a refresh can be caught with its empty list back in `.loading`.
    final class EmptyDetail: PlacePageReading, DishPageReading, TestFake, @unchecked Sendable {
        let placeID = UUID()
        let dishID = UUID()
        private let lock = NSLock()
        private var slowFlag = false
        var slow: Bool {
            get { lock.withLock { slowFlag } }
            set { lock.withLock { slowFlag = newValue } }
        }

        private func pause() async {
            if slow { try? await Task.sleep(for: .milliseconds(300)) }
        }

        func placeSummary(restaurantID: UUID) async throws -> PlaceSummary {
            PlaceSummary(restaurantID: placeID, name: "Nowhere")
        }
        func placeDishes(restaurantID: UUID, after cursor: MenuDishCursor?, pageSize: Int) async throws
            -> MenuDishPage { MenuDishPage(items: [], nextCursor: nil) }
        func entriesAtPlace(
            restaurantID: UUID, scope: PlaceEntryScope, after cursor: PageCursor?, pageSize: Int
        ) async throws -> Page<EntryCard> {
            await pause()
            return Page(items: [], requestedLimit: pageSize)
        }
        func dishSummary(dishID: UUID) async throws -> DishSummary {
            DishSummary(dishID: dishID, name: "Nothing", restaurantID: placeID, restaurantName: "Nowhere")
        }
        func dishReviews(dishID: UUID, after cursor: DishReviewCursor?, pageSize: Int) async throws
            -> DishReviewPage {
            await pause()
            return DishReviewPage(items: [], nextCursor: nil)
        }
    }

    @Test("a place with no visits stays settled through a pull to refresh — never back to the skeleton")
    func placeRefreshKeepsSettled() async throws {
        let reader = EmptyDetail()
        let store = PlacePageStore(restaurantID: reader.placeID, places: reader)
        await store.load()
        #expect(store.isSettled)
        reader.slow = true
        let refresh = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.entries.phase == .loading, "the empty list is back in the air")
        #expect(store.isSettled)
        await refresh.value
        #expect(store.isSettled)
    }

    @Test("a dish with no reviews stays settled through a pull to refresh")
    func dishRefreshKeepsSettled() async throws {
        let reader = EmptyDetail()
        let store = DishPageStore(dishID: reader.dishID, dishes: reader)
        await store.load()
        #expect(store.isSettled)
        reader.slow = true
        let refresh = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.phase == .loading, "the empty list is back in the air")
        #expect(store.isSettled)
        await refresh.value
        #expect(store.isSettled)
    }

    // MARK: - Search: scopes and filters

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
}
