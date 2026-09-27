import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **Round 4 backend** (migrations 0041–0043 + `sort-entry` six_tokens), against staging.
///
/// The contract the iOS lanes build to:
/// - **Secret 6:** scores run 0.5–5.0, plus a 6 that exists ONLY where the composer marked it —
///   `six_tokens: [{offset, length}]` (Unicode scalars) on the sort and on `preview`. A typed "6" is
///   not a score. `score_histogram` gains a 6.0 bucket (11 rows). An author PATCH may set 6; 5.5 is 23514.
/// - **Search filters:** `search_places` / `search_dishes` / `nearby_places` take optional
///   `p_cuisines`, `p_tags`, `p_min_score`; `search_cuisines()` lists the choices. Keysets unchanged.
/// - **Journal:** `my_entries(p_sort, filters…, p_limit, cursor…)` → the caller's entry ids in order;
///   `my_entry_places()` → the places they're at.
///
/// Writes are staging-only synthetic rows under the seeded DEMO account `jess`, every body starts with
/// the `Contract round4 probe` marker, and the suite deletes exactly what it made. Needs 0041–0043
/// applied to staging AND this PR's `sort-entry` deployed there.
@Suite("Round 4 — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct Round4ContractTests {
    static let marker = "Contract round4 probe"
    static let author = (email: "jess@ate.test", password: "atedemo123")

    // MARK: - Staging plumbing

    static func span(_ text: String, in context: String, of body: String) throws -> Span {
        let outer = try #require(body.range(of: context), "\(context) is not in the body")
        let inner = try #require(body.range(of: text, range: outer), "\(text) is not in \(context)")
        let scalars = body.unicodeScalars
        return Span(offset: scalars.distance(from: scalars.startIndex, to: inner.lowerBound),
                    length: text.unicodeScalars.count)
    }

    func signIn() async throws -> AteAPIClient {
        let supabase = StagingContract.makeClient()
        try await supabase.auth.signIn(email: Self.author.email, password: Self.author.password)
        return AteAPIClient(supabase: supabase)
    }

    func somePlace(_ client: AteAPIClient) async throws -> UUID {
        struct Row: Decodable { let id: UUID }
        let rows: [Row] = try await client.supabase.from("restaurants").select("id").order("id").limit(1)
            .execute().value
        return try #require(rows.first?.id, "staging holds no restaurant")
    }

    func card(_ client: AteAPIClient, _ entry: UUID) async throws -> Card {
        let rows: [Card] = try await client.supabase.from("entry_cards")
            .select("id,restaurant_id,items")
            .eq("id", value: entry.uuidString.lowercased()).execute().value
        return try #require(rows.first, "entry \(entry) is not readable")
    }

    func sweep(_ client: AteAPIClient) async throws {
        let me = try await client.requireCurrentUserID()
        try await client.supabase.from("entries").delete()
            .eq("author_id", value: me.uuidString.lowercased())
            .like("body", pattern: "\(Self.marker)%")
            .execute()
    }

    func refused(_ what: String, code: String? = nil, _ call: () async throws -> Void) async {
        do {
            try await call()
            Issue.record("\(what) was not refused")
        } catch {
            if let code {
                #expect((error as? PostgrestError)?.code == code, "\(what): \(error)")
            }
        }
    }

    // MARK: - 1. The secret 6

    @Test("a marked 6 is a score, a typed 6 is not — sort and preview; PATCH 6 ok, 5.5 refused; histogram has 6.0")
    func secretSix() async throws {
        try await StagingExclusive.shared.run {
            let jess = try await signIn()
            try await sweep(jess)
            do {
                try await driveSix(jess)
            } catch {
                try? await sweep(jess)
                throw error
            }
            try await sweep(jess)
        }
    }

    func driveSix(_ jess: AteAPIClient) async throws {
        let place = try await somePlace(jess)
        let body = "\(Self.marker). Tiramisu 6, gnocchi 6 and we were 6."
        let mark = try Self.span("6", in: "Tiramisu 6", of: body)

        // Preview first: the same gate, and it writes nothing.
        let unmarked: PlanReply = try await jess.supabase.functions.invoke("sort-entry", options: FunctionInvokeOptions(
            method: .post,
            body: PreviewRequest(body: body, restaurantID: place.uuidString.lowercased(), sixTokens: [])
        ))
        #expect((unmarked.items ?? []).allSatisfy { $0.score != 6 }, "a typed 6 scored in preview: \(unmarked)")
        let marked: PlanReply = try await jess.supabase.functions.invoke("sort-entry", options: FunctionInvokeOptions(
            method: .post,
            body: PreviewRequest(body: body, restaurantID: place.uuidString.lowercased(), sixTokens: [mark])
        ))
        let previewSixes = (marked.items ?? []).filter { $0.score == 6 }
        #expect(previewSixes.map { $0.dishName.lowercased() } == ["tiramisu"], "preview: \(marked)")

        // The real sort.
        let entry = UUID()
        let me = try await jess.requireCurrentUserID()
        try await jess.supabase.from("entries").insert(
            NewEntry(id: entry, authorID: me, body: body, restaurantID: place, createdAt: Date()),
            returning: .minimal
        ).execute()
        let reply: PlanReply = try await jess.supabase.functions.invoke("sort-entry", options: FunctionInvokeOptions(
            method: .post, body: SortRequest(entryID: entry.uuidString.lowercased(), sixTokens: [mark])
        ))
        #expect(reply.ok == true)

        let lines = try await card(jess, entry).items
        let sixes = lines.filter { $0.score == 6 }
        #expect(sixes.map { $0.dishName.lowercased() } == ["tiramisu"], "only the marked six scores: \(lines)")
        let tiramisu = try #require(sixes.first)

        // 0044: a forced re-sort WITHOUT six_tokens ("Print it again", a tag edit, the retry) keeps it.
        let again: PlanReply = try await jess.supabase.functions.invoke("sort-entry", options: FunctionInvokeOptions(
            method: .post, body: SortRequest(entryID: entry.uuidString.lowercased(), force: true, sixTokens: [])
        ))
        #expect(again.ok == true)
        let resorted = try await card(jess, entry).items.filter { $0.score == 6 }
        #expect(resorted.map { $0.dishName.lowercased() } == ["tiramisu"], "a re-sort wiped the marked 6")

        // It reads back as a 6 on the dish page and in the histogram (11 buckets, 6.0 last).
        let header: [DishHeader] = try await StagingRPC.rows(
            jess, "dish_summary", ["p_dish_id": StagingRPC.id(tiramisu.dishID)]
        )
        #expect(header.first?.myLastScore == 6)
        let buckets: [Bucket] = try await StagingRPC.rows(
            jess, "score_histogram", ["p_user_id": StagingRPC.id(me)]
        )
        #expect(buckets.map(\.score) == [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 6])
        #expect((buckets.last?.reviewCount ?? 0) >= 1)

        // The author's PATCH: 6 is legal, 5.5 is not. The forced re-sort above REPLACED the sorter's
        // lines (new review ids), so patch the line as it is now — a PATCH on a gone id touches zero
        // rows and PostgREST calls that success, which is why the row count is asserted too.
        let line = try #require(resorted.first).reviewID.uuidString.lowercased()
        struct Patched: Decodable { let id: UUID }
        let patched: [Patched] = try await jess.supabase.from("reviews")
            .update(["score": 6.0], returning: .representation).eq("id", value: line).select("id").execute().value
        #expect(patched.count == 1, "the author's PATCH must reach their own line")
        await refused("PATCH 5.5", code: "23514") {
            try await jess.supabase.from("reviews").update(["score": 5.5], returning: .minimal)
                .eq("id", value: line).execute()
        }
    }

    // MARK: - 2. Search filters (read-only)

    @Test("search_cuisines lists the choices; each filter keeps only matching rows; paging is unchanged")
    func searchFilters() async throws {
        let client = try await StagingContract.Backend.shared.client()
        let cuisines: [Cuisine] = try await StagingRPC.rows(client, "search_cuisines")
        #expect(cuisines.map(\.placeCount) == cuisines.map(\.placeCount).sorted(by: >), "busiest first")
        let cuisine = try #require(cuisines.first, "staging holds no place with a cuisine")

        // A query that finds a place of that cuisine: the first two letters of one's name.
        struct Named: Decodable { let name: String; let cuisine: String? }
        let named: [Named] = try await client.supabase.from("restaurants").select("name,cuisine")
            .not("cuisine", operator: .is, value: "null").limit(1000).execute().value
        let key = { (text: String?) in text?.trimmingCharacters(in: .whitespaces).lowercased() }
        let sample = try #require(named.first { key($0.cuisine) == key(cuisine.cuisine) })
        let query = String(sample.name.prefix(2))

        let filter: [String: AnyJSON] = [
            "p_query": .string(query),
            "p_limit": .integer(50),
            "p_cuisines": .array([.string(cuisine.cuisine.uppercased())])
        ]
        let places: [PlaceRow] = try await StagingRPC.rows(client, "search_places", filter)
        #expect(places.isEmpty == false, "\(cuisine.cuisine) + \"\(query)\" found nothing")
        #expect(places.allSatisfy { key($0.cuisine) == key(cuisine.cuisine) }, "\(places)")

        // Paged with the filter: pages of two walk the filtered set.
        var walked: [UUID] = []
        var last: PlaceRow?
        for _ in 0..<30 {
            var params = filter
            params["p_limit"] = .integer(2)
            params["p_cursor_match_tier"] = StagingRPC.count(last?.matchTier)
            params["p_cursor_review_count"] = StagingRPC.count(last?.reviewCount)
            params["p_cursor_name"] = StagingRPC.text(last?.name)
            params["p_cursor_id"] = StagingRPC.maybeID(last?.restaurantID)
            let page: [PlaceRow] = try await StagingRPC.rows(client, "search_places", params)
            walked += page.map(\.restaurantID)
            guard page.count == 2 else { break }
            last = page.last
        }
        let after: [PlaceRow] = try await StagingRPC.rows(client, "search_places", filter)
        KeysetWalk.expectMatches(
            walked, before: places.map(\.restaurantID), after: after.map(\.restaurantID), "filtered search_places"
        )

        // min score and an unknown tag.
        let good: [PlaceRow] = try await StagingRPC.rows(client, "search_places", [
            "p_query": .string(query), "p_min_score": .double(4)
        ])
        #expect(good.allSatisfy { ($0.avgRating ?? 0) >= 4 }, "\(good)")
        let none: [DishRow] = try await StagingRPC.rows(client, "search_dishes", [
            "p_query": .string(query), "p_tags": .array([.string("xx")])
        ])
        #expect(none.isEmpty, "an unknown dietary code matches nothing")

        // Dishes filtered by a tag carry that chip.
        let gf: [DishRow] = try await StagingRPC.rows(client, "search_dishes", [
            "p_query": .string(query), "p_tags": .array([.string("gf")]), "p_min_score": .double(0.5)
        ])
        for dish in gf.prefix(5) {
            let header: [DishHeader] = try await StagingRPC.rows(
                client, "dish_summary", ["p_dish_id": StagingRPC.id(dish.dishID)]
            )
            #expect(header.first?.tags.contains("gf") == true, "\(dish.dishName) has no GF chip")
            #expect((dish.score ?? 0) >= 0.5)
        }

        // Nearby, around the CBD, filtered to the cuisine.
        let near: [PlaceRow] = try await StagingRPC.rows(client, "nearby_places", [
            "p_lat": .double(-37.8136), "p_lng": .double(144.9631), "p_radius_m": .double(50000),
            "p_cuisines": .array([.string(cuisine.cuisine)])
        ])
        #expect(near.allSatisfy { key($0.cuisine) == key(cuisine.cuisine) }, "\(near)")
        #expect(near.map { $0.distanceM ?? 0 } == near.map { $0.distanceM ?? 0 }.sorted(), "nearest first")

        let anon = AteAPIClient(supabase: StagingContract.makeClient())
        await refused("anon search_cuisines") {
            let _: [Cuisine] = try await StagingRPC.rows(anon, "search_cuisines")
        }
    }

    // MARK: - 2b. Dish chips on place_dishes + search_dishes (read-only)

    @Test("place_dishes and search_dishes rows carry the dish's chips — dish_summary.tags — signed in and out")
    func dishRowTags() async throws {
        let client = try await StagingContract.Backend.shared.client()
        let anon = AteAPIClient(supabase: StagingContract.makeClient())

        // A place with a tagged dish, if staging has one; else the busiest place.
        struct Tagged: Decodable { let restaurantID: UUID
            enum CodingKeys: String, CodingKey { case restaurantID = "restaurant_id" } }
        let tagged: [Tagged] = try await client.supabase.from("reviews").select("restaurant_id")
            .neq("tags", value: "{}").limit(1).execute().value
        var place = try await somePlace(client)
        if let withChips = tagged.first?.restaurantID { place = withChips }

        for viewer in [client, anon] {
            let rows: [DishRow] = try await StagingRPC.rows(viewer, "place_dishes", [
                "p_restaurant_id": StagingRPC.id(place), "p_limit": .integer(10)
            ])
            for row in rows.prefix(5) {
                let header: [DishHeader] = try await StagingRPC.rows(
                    viewer, "dish_summary", ["p_dish_id": StagingRPC.id(row.dishID)]
                )
                #expect(header.first?.tags == row.tags, "\(row.dishName): place_dishes \(row.tags) vs summary")
            }
        }

        let name: [Named] = try await client.supabase.from("dishes").select("name").limit(1).execute().value
        let query = String(try #require(name.first?.name).prefix(2))
        let hits: [DishRow] = try await StagingRPC.rows(client, "search_dishes", ["p_query": .string(query)])
        for row in hits.prefix(5) {
            let header: [DishHeader] = try await StagingRPC.rows(
                client, "dish_summary", ["p_dish_id": StagingRPC.id(row.dishID)]
            )
            #expect(header.first?.tags == row.tags, "\(row.dishName): search_dishes \(row.tags) vs summary")
        }
    }

    struct Named: Decodable { let name: String }

    // MARK: - 3. Journal filter + sort (read-only)

    @Test("my_entries: newest is the journal, top by best score (unscored last), every sort pages; places")
    func journal() async throws {
        try await StagingExclusive.shared.run {
            let jess = try await signIn()
            try await driveJournal(jess)
        }
    }

    func mine(_ client: AteAPIClient, _ params: [String: AnyJSON]) async throws -> [JournalRow] {
        try await StagingRPC.rows(client, "my_entries", params)
    }

    func driveJournal(_ jess: AteAPIClient) async throws {
        let me = try await jess.requireCurrentUserID()
        let newest = try await mine(jess, ["p_limit": .integer(100)])
        try #require(newest.count >= 3, "jess needs a few seeded entries")

        struct Ided: Decodable { let id: UUID }
        let journal: [Ided] = try await StagingRPC.rows(jess, "get_entries_by_author", [
            "p_author_id": StagingRPC.id(me), "p_page_size": .integer(50)
        ])
        #expect(Array(newest.prefix(journal.count)).map(\.id) == journal.map(\.id), "newest is the journal's order")

        let oldest = try await mine(jess, ["p_sort": .string("oldest"), "p_limit": .integer(100)])
        if newest.count < 100 { #expect(oldest.map(\.id) == newest.map(\.id).reversed()) }

        let top = try await mine(jess, ["p_sort": .string("top"), "p_limit": .integer(100)])
        let scored = top.prefix { $0.bestScore != nil }
        #expect(top.dropFirst(scored.count).allSatisfy { $0.bestScore == nil }, "unscored last")
        #expect(scored.map { $0.bestScore ?? 0 } == scored.map { $0.bestScore ?? 0 }.sorted(by: >), "best score first")

        for sort in ["newest", "oldest", "top"] {
            let before = try await mine(jess, ["p_sort": .string(sort), "p_limit": .integer(100)])
            var walked: [UUID] = []
            var last: JournalRow?
            for _ in 0..<60 {
                let page = try await mine(jess, [
                    "p_sort": .string(sort), "p_limit": .integer(3),
                    "p_cursor_created_at": StagingRPC.maybeAt(last?.createdAt),
                    "p_cursor_id": StagingRPC.maybeID(last?.id),
                    "p_cursor_best_score": StagingRPC.number(last?.bestScore)
                ])
                walked += page.map(\.id)
                guard page.count == 3 else { break }
                last = page.last
            }
            let after = try await mine(jess, ["p_sort": .string(sort), "p_limit": .integer(100)])
            KeysetWalk.expectMatches(walked, before: before.map(\.id), after: after.map(\.id), "my_entries \(sort)")
        }

        // Filters.
        let places: [JournalPlace] = try await StagingRPC.rows(jess, "my_entry_places")
        #expect(places.map(\.entryCount) == places.map(\.entryCount).sorted(by: >), "busiest first")
        let busiest = try #require(places.first)
        let there = try await mine(jess, [
            "p_restaurant_id": StagingRPC.id(busiest.restaurantID), "p_limit": .integer(100)
        ])
        #expect(there.count == min(busiest.entryCount, 100))
        for row in there.prefix(5) {
            #expect(try await card(jess, row.id).restaurantID == busiest.restaurantID)
        }
        let fours = try await mine(jess, ["p_min_score": .double(4), "p_limit": .integer(100)])
        #expect(fours.allSatisfy { ($0.bestScore ?? 0) >= 4 })
        let gf = try await mine(jess, ["p_tag": .string("GF"), "p_limit": .integer(10)])
        for row in gf {
            #expect(try await card(jess, row.id).items.contains { $0.tags.contains("gf") })
        }
        let first = try #require(newest.first)
        var melbourne = Calendar(identifier: .gregorian)
        melbourne.timeZone = try #require(TimeZone(identifier: "Australia/Melbourne"))
        let day = melbourne.dateComponents([.year, .month, .day], from: first.createdAt)
        let iso = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let thatDay = try await mine(jess, ["p_from": .string(iso), "p_to": .string(iso)])
        #expect(thatDay.contains { $0.id == first.id }, "the newest entry is on its own Melbourne date")

        await refused("p_sort best", code: "22023") {
            _ = try await mine(jess, ["p_sort": .string("best")])
        }
        let anon = AteAPIClient(supabase: StagingContract.makeClient())
        await refused("anon my_entries") {
            _ = try await mine(anon, [:])
        }
    }
}
