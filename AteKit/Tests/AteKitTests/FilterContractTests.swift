import Foundation
import Testing

@testable import AteKit

/// **The one filter sheet's reads, against staging** — the app's own clients, not hand-built calls:
/// `JournalQueryClient` over `my_entries` / `my_entry_places` (0043) and the filtered search
/// (`p_cuisines`, `p_tags`, `p_min_score`, 0042). Read-only.
@Suite("Journal and Search filters — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct FilterContractTests {

    /// The demo viewer is `eamon@ate.test` — the account every Debug build and sim drive signs in as,
    /// so a real entry can land (or go) mid-walk (run 36316337368: order #42 arrived during the
    /// newest walk). Compare against what existed THROUGHOUT (`KeysetWalk`), never one snapshot.
    @Test("my_entries through the client: newest is the journal, every sort pages without repeats")
    func journalSortsAndPages() async throws {
        let api = try await StagingContract.Backend.shared.client()
        let client = JournalQueryClient(api: api)
        let entries = SupabaseEntryService(api: api)
        try await StagingExclusive.shared.run {
            for sort in JournalSort.allCases {
                let before = try await entries.journal(after: nil, pageSize: 100).items
                var seen: [UUID] = []
                var cursor: JournalCursor?
                repeat {
                    let page = try await client.myEntries(JournalQuery(sort: sort), after: cursor, pageSize: 3)
                    seen += page.items.map(\.id)
                    cursor = page.nextCursor
                } while cursor != nil && seen.count < 300
                let after = try await entries.journal(after: nil, pageSize: 100).items
                #expect(Set(seen).count == seen.count, "\(sort): no entry twice")
                let stable = Set(before.map(\.id)).intersection(after.map(\.id))
                #expect(stable.isSubset(of: Set(seen)), "\(sort): every journal entry that stayed was walked")
                #expect(Set(seen).isSubset(of: Set(before.map(\.id) + after.map(\.id))),
                        "\(sort): nothing that was never in the journal")
                if sort == .newest {
                    KeysetWalk.expectMatches(seen, before: before.map(\.id), after: after.map(\.id), "newest")
                }
                if sort == .top {
                    let cards = before + after
                    let scores = seen.compactMap { id in cards.first { $0.id == id } }.map { $0.bestScore ?? -1 }
                    #expect(scores == scores.sorted(by: >), "top runs best score down, unscored last")
                }
            }
        }
    }

    @Test("my_entries filters by place, minimum score and tag, and my_entry_places offers the places")
    func journalFilters() async throws {
        let api = try await StagingContract.Backend.shared.client()
        let client = JournalQueryClient(api: api)
        let places = try await client.myEntryPlaces()
        #expect(places.isEmpty == false, "the demo account has written somewhere")
        if let place = places.first {
            let query = JournalQuery(place: place)
            let page = try await client.myEntries(query, after: nil, pageSize: 100)
            #expect(page.items.count == place.entryCount, "\(place.name): as many as my_entry_places counts")
            #expect(page.items.allSatisfy { $0.restaurantID == place.restaurantID })
        }
        let scored = try await client.myEntries(JournalQuery(minScore: 4), after: nil, pageSize: 100)
        #expect(scored.items.allSatisfy { ($0.bestScore ?? 0) >= 4 }, "a minimum never lets the unscored in")
        for tag in DietTag.allCases {
            let tagged = try await client.myEntries(JournalQuery(tag: tag), after: nil, pageSize: 100)
            #expect(tagged.items.allSatisfy { $0.items.contains { $0.tags.contains(tag) } }, "\(tag)")
        }
        let month = JournalPeriod.month(of: Date())
        let dated = try await client.myEntries(JournalQuery(period: month), after: nil, pageSize: 100)
        #expect(dated.items.allSatisfy { month.contains($0.createdAt) }, "a month holds only that month")
    }

    @Test("search filters: cuisines offered, tags are AND, a minimum score drops the unscored")
    func searchFilters() async throws {
        let api = try await StagingContract.Backend.shared.client()
        let search = SearchClient(api: api)
        let cuisines = try await search.cuisines()
        #expect(cuisines.allSatisfy { $0.placeCount > 0 })
        let both = SearchFilters(tags: [.gf, .v])
        let dishes = try await search.dishes(query: "an", filters: both, after: nil, pageSize: 50).rows
        #expect(dishes.allSatisfy { Set([DietTag.gf, .v]).isSubset(of: $0.tags) }, "every picked tag, not any")
        let bar = SearchFilters(minimumScore: 4)
        let high = try await search.dishes(query: "an", filters: bar, after: nil, pageSize: 50).rows
        #expect(high.allSatisfy { ($0.score ?? 0) >= 4 }, "the unscored never clear a bar")
        if let cuisine = cuisines.first {
            let places = try await search.places(
                query: "a", filters: SearchFilters(cuisines: [cuisine.cuisine]), after: nil, pageSize: 50
            ).rows
            #expect(places.count <= cuisine.placeCount)
        }
    }
}
