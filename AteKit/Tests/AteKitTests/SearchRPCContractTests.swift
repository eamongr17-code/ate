import Foundation
import Supabase
import Testing

@testable import AteKit

/// **The Search tab's reads, against staging, through the client that makes them** —
/// `search_places`, `search_dishes`, `search_people`, `search_saved` and `nearby_places` (0031).
///
/// The backend lane's `SearchScopesContractTests` pins the RPCs' own wire. These pin what
/// ``SearchClient`` does with it — the part a wire test cannot see:
///
/// - **Every cursor field goes back.** Each scope is walked two rows at a time and must come out as
///   the same rows, in the same order, as one wide read: a cursor field the client forgot to send is
///   a page that repeats or skips.
/// - **The row the screen draws is the row the server sent** — a suburb that is never a street line,
///   an average only where there is one, the server's order untouched.
///
/// Opt-in like its siblings: `ATE_CONTRACT_TESTS=1`, staging only, never prod (rule 5). Read-only.
@Suite("Search tab — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct SearchRPCContractTests {

    func client() async throws -> SearchClient {
        SearchClient(api: try await StagingContract.Backend.shared.client())
    }

    /// Walks a scope two rows at a time, then reads it once, wide, and says whether they agree.
    private func walk<Row: Hashable & Identifiable & Sendable>(
        _ read: (SearchCursor?, Int) async throws -> SearchPage<Row>
    ) async throws -> (walked: [Row.ID], wide: [Row.ID]) {
        var walked: [Row.ID] = []
        var cursor: SearchCursor?
        var pages = 0
        repeat {
            let page = try await read(cursor, 2)
            walked += page.rows.map(\.id)
            cursor = page.next
            pages += 1
        } while cursor != nil && pages < 5
        let wide = walked.isEmpty ? [] : try await read(nil, walked.count).rows.map(\.id)
        return (walked, wide)
    }

    /// A word that is actually in the catalogue, found rather than hard-coded: a fixture string in a
    /// contract test is a test that goes green the day the data changes.
    private func aWord(in names: [String]) throws -> String {
        let word = names
            .flatMap { $0.split(separator: " ") }
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .first { $0.count >= 4 }
        return try #require(word, "staging must hold a name with a four-letter word in it")
    }

    private let melbourne = SearchOrigin(latitude: -37.8118, longitude: 144.9629)

    // MARK: - nearby_places

    @Test("nearby_places: rows we hold near the CBD, nearest first, walked without a repeat")
    func nearby() async throws {
        let search = try await client()
        let first = try await search.nearbyPlaces(origin: melbourne, after: nil, pageSize: 10)
        #expect(first.rows.isEmpty == false, "staging must hold a place within 5 km of the CBD")
        for row in first.rows {
            #expect(row.name.isEmpty == false)
            #expect(row.locality.map { $0.contains(",") } != true, "a suburb, never a street line")
            if let score = row.score { #expect(score > 0 && score <= 5) }
        }

        let (walked, wide) = try await walk {
            try await search.nearbyPlaces(origin: melbourne, after: $0, pageSize: $1)
        }
        #expect(Set(walked).count == walked.count, "the nearby cursor served a row twice")
        #expect(walked == wide, "walking the cursor must read the same list as one wide read")
    }

    // MARK: - search_places

    @Test("search_places: a catalogue word finds its place, labelled by locality, and pages")
    func places() async throws {
        let search = try await client()
        let nearby = try await search.nearbyPlaces(origin: melbourne, after: nil, pageSize: 20)
        let term = try aWord(in: nearby.rows.map(\.name))

        let first = try await search.places(query: term, after: nil, pageSize: 20)
        #expect(first.rows.isEmpty == false, "a word taken from a place's name must find it")
        for row in first.rows {
            #expect(row.locality.map { $0.isEmpty || $0.contains(",") } != true)
        }

        let (walked, wide) = try await walk { try await search.places(query: term, after: $0, pageSize: $1) }
        #expect(Set(walked).count == walked.count)
        #expect(walked == wide)
    }

    // MARK: - search_dishes

    @Test("search_dishes: one row per dish with its place, walked on the four-part cursor")
    func dishes() async throws {
        let search = try await client()
        let saved = try await search.savedDishes(matching: nil, after: nil, pageSize: 20)
        let term = try aWord(in: saved.rows.map(\.dishName))

        let first = try await search.dishes(query: term, after: nil, pageSize: 20)
        #expect(first.rows.isEmpty == false, "a word from a saved dish must find a dish")
        for row in first.rows {
            #expect(row.name.isEmpty == false)
            #expect(row.restaurantName.isEmpty == false)
            if let score = row.score { #expect(score > 0 && score <= 5) }
            #expect(row.coverURLString?.isEmpty != true, "absent is null, never an empty string")
        }

        let (walked, wide) = try await walk { try await search.dishes(query: term, after: $0, pageSize: $1) }
        #expect(Set(walked).count == walked.count)
        #expect(walked == wide)
    }

    @Test("an unaccented query finds the accented dish it names")
    func accentFolding() async throws {
        let search = try await client()
        let saved = try await search.savedDishes(matching: nil, after: nil, pageSize: 50)
        let accented = saved.rows.map(\.dishName).first { name in
            name.folding(options: .diacriticInsensitive, locale: nil) != name
        }
        guard let accented else { return }  // Nothing accented on the shelf: nothing to prove here.
        let word = try #require(accented.split(separator: " ").first { word in
            word.count >= 3 && word.folding(options: .diacriticInsensitive, locale: nil) != String(word)
        })
        let plain = word.folding(options: .diacriticInsensitive, locale: nil)

        let rows = try await search.dishes(query: plain, after: nil, pageSize: 20).rows
        #expect(rows.contains { $0.name == accented }, "\(plain) must find \(accented)")
    }

    // MARK: - search_people

    @Test("search_people: you can find yourself by your own handle, and the list pages")
    func people() async throws {
        let api = try await StagingContract.Backend.shared.client()
        let search = SearchClient(api: api)
        let handle = try #require(await SupabaseEntryService(api: api).currentHandle())
        let prefix = String(handle.prefix(3))

        let first = try await search.people(query: prefix, after: nil, pageSize: 20)
        #expect(first.rows.contains { $0.handle == handle && $0.isMe })

        let (walked, wide) = try await walk { try await search.people(query: prefix, after: $0, pageSize: $1) }
        #expect(Set(walked).count == walked.count)
        #expect(walked == wide)
    }

    // MARK: - search_saved

    @Test("search_saved: no query is the whole shelf, a word narrows it, and both page on one cursor")
    func saved() async throws {
        let search = try await client()
        let whole = try await search.savedDishes(matching: nil, after: nil, pageSize: 50)
        guard let firstDish = whole.rows.first else {
            Issue.record("staging's demo viewer must have at least one saved dish")
            return
        }
        #expect(whole.rows.map(\.savedAt) == whole.rows.map(\.savedAt).sorted(by: >), "newest save first")

        let term = String(firstDish.dishName.prefix(3)).lowercased()
        let narrowed = try await search.savedDishes(matching: term, after: nil, pageSize: 50)
        #expect(narrowed.rows.contains { $0.dishID == firstDish.dishID })
        #expect(narrowed.rows.count <= whole.rows.count)

        let (walkedAll, wideAll) = try await walk {
            try await search.savedDishes(matching: nil, after: $0, pageSize: $1)
        }
        #expect(Set(walkedAll).count == walkedAll.count, "the saved cursor served a row twice")
        #expect(walkedAll == wideAll)

        let (walked, wide) = try await walk { try await search.savedDishes(matching: term, after: $0, pageSize: $1) }
        #expect(walked == wide, "the filter must survive the cursor")
    }
}
