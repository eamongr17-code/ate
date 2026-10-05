import Foundation
import Testing
@testable import AteKit

/// The search filters — the values, the tag rule, and the reads that take them.
@MainActor
@Suite("Search — filters")
struct SearchFilterTests {
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
}
private extension PlaceResult {
    static func fixture(_ name: String, score: Double? = 4.3, id: UUID = UUID()) -> PlaceResult {
        PlaceResult(restaurantID: id, name: name, locality: "Carlton", score: score)
    }
}
