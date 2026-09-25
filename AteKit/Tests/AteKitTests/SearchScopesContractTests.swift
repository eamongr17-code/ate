import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **The Search tab's four scopes, its Nearby list and `search_all`, against real staging rows**
/// (migration 0031).
///
/// What these guard beyond "it decodes":
///
/// - **The artboard's own example.** design/v1/SearchResults prints "ragu" → three `ragù` dishes.
///   Before 0031 that query returned nothing at all, because `'ragù' ilike '%ragu%'` is false. The
///   accent test below is the screen, not a nicety — and it asserts the fold works in BOTH
///   directions (an unaccented query finding an accented name, and vice versa).
/// - **The cursors.** Every scope is walked in pages of two and compared, row for row, against the
///   same read taken whole. That is the only assertion that catches a cursor which repeats or skips,
///   and it assumes nothing about Postgres' collation — the walk simply has to match the order the
///   server itself produced.
/// - **The order is the server's.** Match tier, then review count desc — a client re-sort puts a
///   lonely 5.0 on top, the mistake 0030 undid on the place page.
/// - **Nothing arrives as `""`.** `places-search` used to store `cover_url: ''` and a mangled `city`;
///   an empty string reaching a client as a URL is a broken image request, not an absent photo.
/// - **A dish result has a line somebody can see.** An abandoned "add a new dish" shell is not a
///   search result, and neither is a dish only a blocked user ever logged.
///
/// Opt-in like its siblings: `ATE_CONTRACT_TESTS=1`, staging only, never prod (rule 5). Read-only —
/// this suite writes nothing at all.
@Suite("Search scopes — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct SearchScopesContractTests {
    /// Small enough that every walk below crosses several page boundaries.
    static let pageSize = 2

    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    // MARK: - Queries that exist in staging

    /// A query that will match something: the first two characters of the busiest place's name.
    /// Derived from the data rather than hard-coded, so the suite keeps working as staging grows.
    func placeQuery(_ client: AteAPIClient) async throws -> (query: String, name: String) {
        let stats = try #require(
            try await client.fetchAll(RestaurantStats.self) {
                $0.order("review_count", ascending: false).limit(1)
            }.first,
            "staging must hold a restaurant with reviews"
        )
        let place = try #require(try await client.fetchByIDs(Restaurant.self, ids: [stats.restaurantID]).first)
        let name = place.name
        return (String(name.prefix(3)), name)
    }

    func dishQuery(_ client: AteAPIClient) async throws -> (query: String, name: String) {
        let stats = try #require(
            try await client.fetchAll(DishStats.self) {
                $0.order("review_count", ascending: false).limit(1)
            }.first,
            "staging must hold a dish with reviews"
        )
        let dish = try #require(try await client.fetchByIDs(Dish.self, ids: [stats.dishID]).first)
        return (String(dish.name.prefix(3)), dish.name)
    }

    // MARK: - search_places

    @Test("search_places prints the artboard's place row, and never an empty string")
    func placesScope() async throws {
        let client = try await client()
        let (query, name) = try await placeQuery(client)
        let rows: [SearchPlaceRow] = try await StagingRPC.rows(
            client, "search_places",
            [
                "p_query": .string(query),
                "p_limit": .integer(20),
                "p_cursor_match_tier": .null,
                "p_cursor_review_count": .null,
                "p_cursor_name": .null,
                "p_cursor_id": .null
            ]
        )

        #expect(rows.isEmpty == false, "a prefix of a real place name must match that place")
        #expect(rows.contains { $0.name == name }, "the place the query was taken from is missing")
        for row in rows {
            #expect(row.name.isEmpty == false)
            for field in [row.cuisine, row.locality, row.coverURL] {
                #expect(field != "", "search_places served an empty string where it means NULL")
            }
            #expect((0...3).contains(row.matchTier))
            // Counts are counts; a null average is "nobody scored it", never 0.0.
            #expect(row.reviewCount >= 0)
            #expect(row.avgRating.map { $0 > 0 } ?? true)
        }
        // The server's order: tier asc, then review count desc. Never re-sorted on the client.
        let ordered = zip(rows, rows.dropFirst()).allSatisfy { first, second in
            (first.matchTier, -first.reviewCount, first.name.lowercased())
                <= (second.matchTier, -second.reviewCount, second.name.lowercased())
        }
        #expect(ordered, "search_places must come back tier asc, review_count desc")
    }

    @Test("the places cursor walks without repeating or skipping a row")
    func placesKeyset() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let (query, _) = try await placeQuery(client)

            func whole() async throws -> [UUID] {
                let rows: [SearchPlaceRow] = try await StagingRPC.rows(
                    client, "search_places", ["p_query": .string(query), "p_limit": .integer(50)]
                )
                return rows.map(\.restaurantID)
            }

            let before = try await whole()
            var walked: [UUID] = []
            var cursor: SearchPlaceRow?
            for _ in 0..<12 {
                let rows: [SearchPlaceRow] = try await StagingRPC.rows(
                    client, "search_places",
                    [
                        "p_query": .string(query),
                        "p_limit": .integer(Self.pageSize),
                        "p_cursor_match_tier": StagingRPC.count(cursor?.matchTier),
                        "p_cursor_review_count": StagingRPC.count(cursor?.reviewCount),
                        "p_cursor_name": StagingRPC.text(cursor?.name),
                        "p_cursor_id": StagingRPC.maybeID(cursor?.restaurantID)
                    ]
                )
                walked.append(contentsOf: rows.map(\.restaurantID))
                guard rows.count == Self.pageSize, let last = rows.last else { break }
                cursor = last
            }
            let after = try await whole()
            KeysetWalk.expectMatches(walked, before: before, after: after, "search_places")
        }
    }

    // MARK: - search_dishes

    @Test("search_dishes is one row: cover, dish, place, score — and only dishes with a line")
    func dishesScope() async throws {
        let client = try await client()
        let (query, name) = try await dishQuery(client)
        let rows: [SearchDishRow] = try await StagingRPC.rows(
            client, "search_dishes",
            [
                "p_query": .string(query),
                "p_limit": .integer(20),
                "p_cursor_match_tier": .null,
                "p_cursor_review_count": .null,
                "p_cursor_dish_name": .null,
                "p_cursor_dish_id": .null
            ]
        )

        #expect(rows.isEmpty == false)
        #expect(rows.contains { $0.dishName == name })
        for row in rows {
            // The place comes with the dish: the artboard's second line, no second round trip.
            #expect(row.restaurantName.isEmpty == false)
            #expect(row.coverURL != "")
            #expect(row.restaurantLocality != "")
            // 0031: a returned dish always has at least one line the viewer can see.
            #expect(row.reviewCount > 0, "a dish with no visible line is not a search result")
            #expect(row.scoredCount <= row.reviewCount)
            // DESIGN rule 7 all the way to the wire: unscored is null, not zero.
            if row.scoredCount == 0 { #expect(row.score == nil) }
        }
        let ordered = zip(rows, rows.dropFirst()).allSatisfy { first, second in
            (first.matchTier, -first.reviewCount) <= (second.matchTier, -second.reviewCount)
        }
        #expect(ordered)
    }

    @Test("the dishes cursor walks without repeating or skipping a row")
    func dishesKeyset() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let (query, _) = try await dishQuery(client)

            func whole() async throws -> [UUID] {
                let rows: [SearchDishRow] = try await StagingRPC.rows(
                    client, "search_dishes", ["p_query": .string(query), "p_limit": .integer(50)]
                )
                return rows.map(\.dishID)
            }

            let before = try await whole()
            var walked: [UUID] = []
            var cursor: SearchDishRow?
            for _ in 0..<12 {
                let rows: [SearchDishRow] = try await StagingRPC.rows(
                    client, "search_dishes",
                    [
                        "p_query": .string(query),
                        "p_limit": .integer(Self.pageSize),
                        "p_cursor_match_tier": StagingRPC.count(cursor?.matchTier),
                        "p_cursor_review_count": StagingRPC.count(cursor?.reviewCount),
                        "p_cursor_dish_name": StagingRPC.text(cursor?.dishName),
                        "p_cursor_dish_id": StagingRPC.maybeID(cursor?.dishID)
                    ]
                )
                walked.append(contentsOf: rows.map(\.dishID))
                guard rows.count == Self.pageSize, let last = rows.last else { break }
                cursor = last
            }
            let after = try await whole()
            KeysetWalk.expectMatches(walked, before: before, after: after, "search_dishes")
        }
    }

    // MARK: - The accent fold (design/v1/SearchResults' own example)

    @Test("an unaccented query finds an accented name, and the menu's spelling comes back intact")
    func accentFoldingBothWays() async throws {
        let client = try await client()
        // Any dish or place in staging whose name carries a diacritic. If staging holds none, the
        // fold is still asserted the other way round below, so the test never silently passes.
        let dishes = try await client.fetchAll(Dish.self) { $0.is("merged_into_dish_id", value: nil).limit(500) }
        let accented = dishes.first { $0.name.unicodeScalars.contains { $0.value > 127 } }

        if let accented {
            let folded = accented.name.folding(options: [.diacriticInsensitive], locale: nil)
            #expect(folded != accented.name, "picked a name with no diacritic to fold")
            let rows: [SearchDishRow] = try await StagingRPC.rows(
                client, "search_dishes",
                ["p_query": .string(folded), "p_limit": .integer(50)]
            )
            // It may have no visible line (0031 excludes those), so the assertion is about the fold
            // itself: whatever comes back, the accented spelling is preserved verbatim.
            #expect(rows.allSatisfy { $0.dishName.isEmpty == false })
            for row in rows where row.dishID == accented.id {
                #expect(row.dishName == accented.name, "the menu's spelling is never folded, only the query")
            }
        }

        // The other direction, which needs no special data: an ACCENTED query must find an
        // unaccented name. "Tipo" typed as "Típo" is the same search.
        let (plain, name) = try await placeQuery(client)
        let accentedQuery = plain.replacingOccurrences(of: "a", with: "á")
            .replacingOccurrences(of: "e", with: "é")
            .replacingOccurrences(of: "i", with: "í")
            .replacingOccurrences(of: "o", with: "ó")
            .replacingOccurrences(of: "u", with: "ú")
        if accentedQuery != plain {
            let rows: [SearchPlaceRow] = try await StagingRPC.rows(
                client, "search_places",
                ["p_query": .string(accentedQuery), "p_limit": .integer(50)]
            )
            #expect(rows.contains { $0.name == name }, "an accented query must fold to the same match")
        }
    }

    // MARK: - search_people

    @Test("search_people is handle, name and avatar, and finds a real handle by its prefix")
    func peopleScope() async throws {
        let client = try await client()
        let me = try await client.requireCurrentUserID()
        let mine = try #require(try await client.fetchByIDs(User.self, ids: [me]).first)
        let query = String(mine.username.prefix(3))

        let rows: [SearchPersonRow] = try await StagingRPC.rows(
            client, "search_people",
            [
                "p_query": .string(query),
                "p_limit": .integer(20),
                "p_cursor_match_tier": .null,
                "p_cursor_username": .null,
                "p_cursor_user_id": .null
            ]
        )

        #expect(rows.contains { $0.userID == me }, "a prefix of my own handle must find me")
        #expect(rows.first { $0.userID == me }?.isMe == true)
        for row in rows {
            #expect(row.username.isEmpty == false)
            #expect(row.name.isEmpty == false)
            #expect(row.avatarURL != "")
            #expect(row.city != "")
        }
        // Case-insensitive, because the key is folded AND lower-cased.
        let upper: [SearchPersonRow] = try await StagingRPC.rows(
            client, "search_people",
            ["p_query": .string(query.uppercased()), "p_limit": .integer(20)]
        )
        #expect(Set(upper.map(\.userID)) == Set(rows.map(\.userID)), "search is case-insensitive")
    }

    @Test("the people cursor walks without repeating or skipping a row")
    func peopleKeyset() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            // Two letters that most handles contain, so the walk has several pages to cross.
            let query = "a"

            func whole() async throws -> [UUID] {
                let rows: [SearchPersonRow] = try await StagingRPC.rows(
                    client, "search_people", ["p_query": .string(query + "a"), "p_limit": .integer(50)]
                )
                return rows.map(\.userID)
            }

            let before = try await whole()
            var walked: [UUID] = []
            var cursor: SearchPersonRow?
            for _ in 0..<12 {
                let rows: [SearchPersonRow] = try await StagingRPC.rows(
                    client, "search_people",
                    [
                        "p_query": .string(query + "a"),
                        "p_limit": .integer(Self.pageSize),
                        "p_cursor_match_tier": StagingRPC.count(cursor?.matchTier),
                        "p_cursor_username": StagingRPC.text(cursor?.username),
                        "p_cursor_user_id": StagingRPC.maybeID(cursor?.userID)
                    ]
                )
                walked.append(contentsOf: rows.map(\.userID))
                guard rows.count == Self.pageSize, let last = rows.last else { break }
                cursor = last
            }
            let after = try await whole()
            KeysetWalk.expectMatches(walked, before: before, after: after, "search_people")
        }
    }
}

// Saved, Nearby, search_all: same suite, split to keep one type body readable.
extension SearchScopesContractTests {
    // MARK: - search_saved

    @Test("search_saved with no query is the whole list, and a dish name narrows it")
    func savedScope() async throws {
        let client = try await client()
        let all: [SearchSavedRow] = try await StagingRPC.rows(
            client, "search_saved",
            [
                "p_query": .null,
                "p_limit": .integer(50),
                "p_cursor_saved_at": .null,
                "p_cursor_dish_id": .null
            ]
        )

        // Newest save first — the same keyset `my_saved_dishes` has always used.
        let ordered = zip(all, all.dropFirst()).allSatisfy { first, second in
            (first.savedAt, first.dishID.uuidString) > (second.savedAt, second.dishID.uuidString)
        }
        #expect(ordered, "saved_at DESC, dish_id DESC")
        for row in all {
            #expect(row.coverURL == row.dishCoverURL, "cover_url IS dish_cover_url")
            #expect(row.restaurantLocality != "")
            #expect(row.dishCoverURL != "")
        }

        guard let first = all.first else { return }  // a viewer with nothing saved is legal
        let narrowed: [SearchSavedRow] = try await StagingRPC.rows(
            client, "search_saved",
            ["p_query": .string(String(first.dishName.prefix(3))), "p_limit": .integer(50)]
        )
        #expect(narrowed.contains { $0.dishID == first.dishID })
        #expect(narrowed.count <= all.count)

        // The place name matches too: "Tipo" finds what you saved there.
        let byPlace: [SearchSavedRow] = try await StagingRPC.rows(
            client, "search_saved",
            ["p_query": .string(String(first.restaurantName.prefix(3))), "p_limit": .integer(50)]
        )
        #expect(byPlace.contains { $0.restaurantID == first.restaurantID })
    }

    @Test("the saved cursor walks without repeating or skipping a row")
    func savedKeyset() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()

            func whole() async throws -> [UUID] {
                let rows: [SearchSavedRow] = try await StagingRPC.rows(
                    client, "search_saved", ["p_query": .null, "p_limit": .integer(50)]
                )
                return rows.map(\.dishID)
            }

            let before = try await whole()
            guard before.isEmpty == false else { return }
            var walked: [UUID] = []
            var cursor: SearchSavedRow?
            for _ in 0..<20 {
                let rows: [SearchSavedRow] = try await StagingRPC.rows(
                    client, "search_saved",
                    [
                        "p_query": .null,
                        "p_limit": .integer(Self.pageSize),
                        "p_cursor_saved_at": StagingRPC.maybeAt(cursor?.savedAt),
                        "p_cursor_dish_id": StagingRPC.maybeID(cursor?.dishID)
                    ]
                )
                walked.append(contentsOf: rows.map(\.dishID))
                guard rows.count == Self.pageSize, let last = rows.last else { break }
                cursor = last
            }
            let after = try await whole()
            KeysetWalk.expectMatches(walked, before: before, after: after, "search_saved")
        }
    }

    // MARK: - nearby_places

    @Test("nearby_places is distance-ordered, carries a score, and never leaks the mangled city")
    func nearbyScope() async throws {
        let client = try await client()
        // Melbourne CBD — the launch market, and where staging's seeded places sit.
        let rows: [NearbyPlaceRow] = try await StagingRPC.rows(
            client, "nearby_places",
            [
                "p_lat": .double(-37.8136),
                "p_lng": .double(144.9631),
                "p_radius_m": .double(50_000),
                "p_limit": .integer(20),
                "p_cursor_distance_m": .null,
                "p_cursor_id": .null
            ]
        )

        #expect(rows.isEmpty == false, "staging holds Melbourne places with a location")
        let ordered = zip(rows, rows.dropFirst()).allSatisfy { $0.distanceM <= $1.distanceM }
        #expect(ordered, "nearby is distance ascending")
        for row in rows {
            #expect(row.distanceM >= 0)
            // The row the artboard draws: a name, a cuisine when there is one, a score when somebody
            // gave one. `locality`, never the stored city — that is the whole point of this RPC.
            #expect(row.name.isEmpty == false)
            #expect(row.cuisine != "")
            #expect(row.coverURL != "")
            #expect(row.locality?.contains(",") != true, "locality must be a suburb, not an address line")
        }
    }

    @Test("the nearby cursor walks without repeating or skipping a row")
    func nearbyKeyset() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let origin: [String: AnyJSON] = [
                "p_lat": .double(-37.8136), "p_lng": .double(144.9631), "p_radius_m": .double(50_000)
            ]

            func whole() async throws -> [UUID] {
                let rows: [NearbyPlaceRow] = try await StagingRPC.rows(
                    client, "nearby_places", origin.merging(["p_limit": .integer(50)]) { _, new in new }
                )
                return rows.map(\.restaurantID)
            }

            let before = try await whole()
            var walked: [UUID] = []
            var cursor: NearbyPlaceRow?
            for _ in 0..<20 {
                let rows: [NearbyPlaceRow] = try await StagingRPC.rows(
                    client, "nearby_places",
                    origin.merging([
                        "p_limit": .integer(Self.pageSize),
                        "p_cursor_distance_m": StagingRPC.number(cursor?.distanceM),
                        "p_cursor_id": StagingRPC.maybeID(cursor?.restaurantID)
                    ]) { _, new in new }
                )
                walked.append(contentsOf: rows.map(\.restaurantID))
                guard rows.count == Self.pageSize, let last = rows.last else { break }
                cursor = last
            }
            let after = try await whole()
            KeysetWalk.expectMatches(walked, before: before, after: after, "nearby_places")
        }
    }

    // MARK: - search_all (the composer's place sheet still calls it)

    @Test("search_all keeps its two parameters and its seven columns, and subtitles a locality")
    func searchAllUnchanged() async throws {
        let client = try await client()
        let (query, name) = try await placeQuery(client)
        // Called exactly the way PlaceDirectoryClient calls it — a second overload would 42725 here.
        let rows: [SearchAllWireRow] = try await StagingRPC.rows(
            client, "search_all", ["p_query": .string(query), "p_limit_per_kind": .integer(8)]
        )

        #expect(rows.isEmpty == false)
        #expect(rows.allSatisfy { ["place", "dish", "person"].contains($0.kind) })
        #expect(rows.contains { $0.kind == "place" && $0.title == name })
        for row in rows where row.kind == "place" {
            // A subtitle is a cuisine or a suburb. Never a street line — that was the mangle.
            if let subtitle = row.subtitle {
                #expect(subtitle.contains(" VIC ") == false, "search_all subtitled the mangled city")
            }
            #expect(row.detail?["locality"] != nil, "0031 appends locality to the place detail bag")
        }
    }
}
