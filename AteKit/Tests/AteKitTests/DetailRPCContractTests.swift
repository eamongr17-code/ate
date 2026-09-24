import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **The Place and Dish page reads, against staging** — `place_summary`, `place_dishes`,
/// `get_entries_at_place`, `dish_summary`, `get_dish_reviews`, `is_dish_saved` (0022, revised 0029).
///
/// What these guard beyond "it decodes":
///
/// - **Entries vs lines.** `entry_count` counts VISITS, `review_count` counts receipt LINES; at Tipo
///   00 that is 8 and 18. A screen printing the wrong one is wrong in a way no unit test can see, so
///   the relationship is asserted against the rows themselves.
/// - **Nothing arrives as `""`.** `places-search` stores `cover_url: ''`, and an empty string reaching
///   a client as a URL is a broken image request, not an absent photo.
/// - **The cursors.** Every paged read is walked in pages of two and compared, row for row, to the
///   same read taken whole. That is the only assertion that catches a cursor which repeats or skips,
///   and it assumes nothing about Postgres' collation.
/// - **`photos[0].url == cover_url`.** The dish header's stack and its thumbnail are one derivation
///   (0029); the day they disagree, one of them is showing another dish.
///
/// Opt-in like the other suites: `ATE_CONTRACT_TESTS=1`, staging only, never prod (rule 5).
@Suite("Detail RPCs — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct DetailRPCContractTests {
    /// Small enough that every walk below crosses several page boundaries.
    static let pageSize = 2

    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    /// The busiest place we can see — most likely to have several dishes, visits and a cover, so the
    /// assertions are about real rows rather than an empty shape.
    func busiestPlace(_ client: AteAPIClient) async throws -> RestaurantStats {
        try #require(
            try await client.fetchAll(RestaurantStats.self) {
                $0.order("review_count", ascending: false).limit(1)
            }.first,
            "staging must hold a restaurant with reviews"
        )
    }

    func busiestDish(_ client: AteAPIClient, limit: Int = 1) async throws -> [DishStats] {
        try await client.fetchAll(DishStats.self) {
            $0.order("review_count", ascending: false).limit(limit)
        }
    }

    // MARK: - place_summary

    @Test("place_summary is the header the artboard prints: chips, cover, visits")
    func placeSummaryHeader() async throws {
        let client = try await client()
        let stats = try await busiestPlace(client)
        let rows: [PlaceSummaryRow] = try await StagingRPC.rows(
            client, "place_summary", ["p_restaurant_id": StagingRPC.id(stats.restaurantID)]
        )
        let place = try #require(rows.first, "place_summary returned nothing for a place with stats")

        #expect(place.restaurantID == stats.restaurantID)
        #expect(place.name.isEmpty == false)
        // Absent is NULL, never "" (0029). An empty cover string is a broken image request.
        for field in [place.address, place.city, place.cuisine, place.coverURL, place.locality] {
            #expect(field != "", "place_summary served an empty string where it means NULL")
        }
        // Visits, not lines: mine are a subset of everyone's, and a visit count implies a last visit.
        #expect(place.entryCount >= place.myVisits)
        #expect((place.myVisits > 0) == (place.myLastVisit != nil))
        #expect(place.peopleCount >= 0 && place.dishCount >= 0)

        // entry_count IS the number of entries this same viewer can page at this place.
        let visible = try await entriesAtPlace(client, stats.restaurantID, scope: "all", size: 50)
        // Everything below compares two reads, and staging does not hold still between them (see
        // KeysetWalk): another suite blocks a seeded author mid-run, which changes both the
        // aggregates and the visible entries. So each number is asserted against the reading taken
        // BEFORE or the one taken AFTER — a client-side average would match neither.
        let after = try #require(
            try await client.findRow(RestaurantStats.self) {
                $0.eq("restaurant_id", value: stats.restaurantID.uuidString)
            }
        )
        #expect(
            [stats.avgRating, after.avgRating].contains(place.avgRating),
            "the chip is restaurant_stats, not a client average"
        )
        #expect([stats.reviewCount, after.reviewCount].contains(place.reviewCount))
        if visible.count < 50 {
            let again: [PlaceSummaryRow] = try await StagingRPC.rows(
                client, "place_summary", ["p_restaurant_id": StagingRPC.id(stats.restaurantID)]
            )
            let counts = [place.entryCount, again.first?.entryCount].compactMap { $0 }
            #expect(counts.contains(visible.count), "entry_count disagrees with the entries it counts")
        }
    }

    @Test("a locality is derivable for the places we hold, and it is never the street line")
    func placeLocalityIsPrintable() async throws {
        let client = try await client()
        let places = try await client.fetchAll(RestaurantStats.self) {
            $0.order("review_count", ascending: false).limit(8)
        }
        var named = 0
        for stats in places {
            let rows: [PlaceSummaryRow] = try await StagingRPC.rows(
                client, "place_summary", ["p_restaurant_id": StagingRPC.id(stats.restaurantID)]
            )
            guard let place = rows.first, let locality = place.locality else { continue }
            named += 1
            #expect(locality.contains(",") == false, "a locality chip is one place name, not an address")
            if let address = place.address {
                #expect(address.hasPrefix(locality) == false, "\(place.name): locality is the street")
            }
        }
        #expect(named > 0, "no place in staging yields a locality — the chip would never draw")
    }

    // MARK: - place_dishes

    /// The order is the PRODUCT's, and the product's rule already exists in Swift, ported from the
    /// legacy repo with its test cases: `DishRanking`. So the oracle here is that type, applied to
    /// the rows the server itself returned — one read, nothing to race, and it fails if the server
    /// ever ranks by anything else (0022 ranked score-first: a lonely 5.0 led the menu).
    ///
    /// The one thing this cannot pin is a COLLATION disagreement on an exotic tie: `lower(name)` in
    /// Postgres versus `localizedCaseInsensitiveCompare` in Swift agree on case and on ASCII, and the
    /// `id` tiebreak (byte order == uppercase-hex order) settles everything they call equal. Two
    /// dishes at the same review count and score whose names differ only by an accent would land
    /// here, and that is the right place for it to land.
    @Test("place_dishes is DishRanking's order, drops never-logged dishes, and pages on 4 parts")
    func placeDishesRanksAndPages() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let stats = try await busiestPlace(client)
            let whole = try await placeDishPage(client, place: stats.restaurantID, size: 200)
            #expect(whole.isEmpty == false, "the busiest place has no dishes — place_dishes lost its join")

            // The ported rule, over the server's own rows: re-ranking them must change nothing.
            let ranked = DishRanking.rank(
                dishes: whole.map { row in
                    Dish(id: row.dishID, name: row.dishName, restaurantID: stats.restaurantID, createdAt: .now)
                },
                stats: whole.map { row in
                    DishStats(
                        dishID: row.dishID, restaurantID: stats.restaurantID,
                        score: row.score, reviewCount: row.reviewCount
                    )
                }
            )
            #expect(
                ranked.map(\.id) == whole.map(\.dishID),
                """
                place_dishes is not DishRanking's order — review count leads, then score (unscored last), \
                then name, then id. Server: \(whole.map { "\($0.dishName) \($0.reviewCount)×" }). \
                Rule: \(ranked.map { "\($0.name) \($0.reviewCount)×" })
                """
            )
            // Review count leads; score only breaks its ties, with the unscored last inside a tie.
            for (upper, lower) in zip(whole, whole.dropFirst()) {
                #expect(upper.reviewCount >= lower.reviewCount, "review_count is the first key")
                if upper.reviewCount == lower.reviewCount {
                    #expect((upper.score ?? -1) >= (lower.score ?? -1), "score is the second key, nulls last")
                }
            }
            // A dish nobody has logged is an abandoned "add a new dish" shell, not a menu item (0030).
            // An UNSCORED dish WITH a line is a menu item and must still be here — so the menu is
            // exactly the dishes this viewer can see a line for, no more and no less. Stated as a set
            // equality rather than "every row has a line", which staging can satisfy vacuously: it holds
            // no shell today, and this is the assertion that catches one the moment somebody seeds it
            // (and catches a real menu item being dropped, which is the costlier direction).
            let logged = try await client.fetchAll(DishStats.self) {
                $0.eq("restaurant_id", value: stats.restaurantID.uuidString)
                    .gt("review_count", value: 0)
                    .limit(200)
            }
            #expect(
                Set(whole.map(\.dishID)) == Set(logged.map(\.dishID)),
                "the menu must be exactly the dishes with a line (shells out, unscored-with-a-line in)"
            )
            #expect(whole.allSatisfy { $0.reviewCount > 0 }, "a never-logged dish is on the menu")
            #expect(whole.allSatisfy { $0.peopleCount > 0 }, "a line implies a reviewer")
            #expect(whole.allSatisfy { $0.coverURL != "" })

            var walked: [PlaceDishRow] = []
            var cursor: PlaceDishRow?
            var pages = 0
            repeat {
                let page = try await placeDishPage(
                    client, place: stats.restaurantID, size: Self.pageSize, after: cursor
                )
                walked.append(contentsOf: page)
                cursor = page.count < Self.pageSize ? nil : page.last
                pages += 1
            } while cursor != nil && pages < 120

            // The whole read again, AFTER the walk: the rows present in both snapshots are the ones that
            // existed throughout, and every one of them must be in the walk (see KeysetWalk).
            let wholeAfter = try await placeDishPage(client, place: stats.restaurantID, size: 200)
            KeysetWalk.expectMatches(
                walked.map(\.dishID), before: whole.map(\.dishID), after: wholeAfter.map(\.dishID),
                "place_dishes 4-part"
            )
        }
    }

    func placeDishPage(
        _ client: AteAPIClient, place: UUID, size: Int, after last: PlaceDishRow? = nil
    ) async throws -> [PlaceDishRow] {
        try await StagingRPC.rows(client, "place_dishes", [
            "p_restaurant_id": StagingRPC.id(place),
            "p_limit": .integer(size),
            "p_cursor_review_count": StagingRPC.count(last?.reviewCount),
            "p_cursor_score": StagingRPC.number(last?.score),
            "p_cursor_dish_name": StagingRPC.text(last?.dishName),
            "p_cursor_dish_id": StagingRPC.maybeID(last?.dishID)
        ])
    }

    // MARK: - get_entries_at_place

    @Test("get_entries_at_place returns entry_cards — the one shape — and scopes mine vs others")
    func entriesAtPlaceAreEntryCards() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let stats = try await busiestPlace(client)
            let all = try await entriesAtPlace(client, stats.restaurantID, scope: "all", size: 50)
            #expect(all.isEmpty == false, "no entries at the busiest place — the place page would be blank")
            #expect(all.allSatisfy { $0.restaurantID == stats.restaurantID })
            #expect(all.allSatisfy { $0.place?.id == stats.restaurantID }, "an entry here carries its place")
            // It is the ONE shape: the footer numbers the receipt draws arrive with the row.
            #expect(all.allSatisfy { $0.dishCount == $0.items.count })
            #expect(all.allSatisfy { $0.photoCount == $0.photos.count })

            let mine = try await entriesAtPlace(client, stats.restaurantID, scope: "mine", size: 50)
            let others = try await entriesAtPlace(client, stats.restaurantID, scope: "others", size: 50)
            #expect(mine.allSatisfy { $0.isMine })
            #expect(others.allSatisfy { $0.isMine == false })
            // The bracketing 'all' read is taken after the walk below, so one read serves both checks.

            var walked: [EntryCard] = []
            var cursor: EntryCard?
            var pages = 0
            repeat {
                let page = try await entriesAtPlace(
                    client, stats.restaurantID, scope: "all", size: Self.pageSize, after: cursor
                )
                walked.append(contentsOf: page)
                cursor = page.count < Self.pageSize ? nil : page.last
                pages += 1
            } while cursor != nil && pages < 120
            let allAfter = try await entriesAtPlace(client, stats.restaurantID, scope: "all", size: 50)
            KeysetWalk.expectMatches(
                walked.map(\.id), before: all.map(\.id), after: allAfter.map(\.id), "place entries"
            )
            // Two reads of a moving database, so the count is matched against 'all' before OR after.
            if all.count < 50 {
                #expect(
                    [all.count, allAfter.count].contains(mine.count + others.count),
                    "mine + others must be all of them"
                )
            }
        }
    }

    func entriesAtPlace(
        _ client: AteAPIClient, _ place: UUID, scope: String, size: Int, after last: EntryCard? = nil
    ) async throws -> [EntryCard] {
        try await StagingRPC.rows(client, "get_entries_at_place", [
            "p_restaurant_id": StagingRPC.id(place),
            "p_scope": .string(scope),
            "p_cursor_created_at": StagingRPC.maybeAt(last?.createdAt),
            "p_cursor_id": StagingRPC.maybeID(last?.id),
            "p_page_size": .integer(size)
        ])
    }

    // MARK: - dish_summary + is_dish_saved

    @Test("dish_summary's stack and thumbnail are one derivation, and saved is the save state")
    func dishSummaryHeader() async throws {
        let client = try await client()
        let busiest = try #require(try await busiestDish(client).first, "staging needs a reviewed dish")
        let rows: [DishSummaryRow] = try await StagingRPC.rows(
            client, "dish_summary", ["p_dish_id": StagingRPC.id(busiest.dishID)]
        )
        let dish = try #require(rows.first)

        #expect(dish.dishID == busiest.dishID)
        #expect(dish.dishName.isEmpty == false)
        #expect(dish.restaurantID == busiest.restaurantID)
        #expect(dish.restaurantName.isEmpty == false)
        // The aggregate is the view's, read before OR after this call — never a number of its own
        // (a concurrent block in another suite moves both readings; see KeysetWalk).
        let now = try #require(
            try await client.findRow(DishStats.self) { $0.eq("dish_id", value: busiest.dishID.uuidString) }
        )
        #expect(
            [busiest.score, now.score].contains(dish.score),
            "the header score is dish_stats, not a client average"
        )
        #expect([busiest.reviewCount, now.reviewCount].contains(dish.reviewCount))
        #expect(dish.scoredCount <= dish.reviewCount)
        #expect((dish.score == nil) == (dish.scoredCount == 0), "a score nobody gave is an inferred one")
        #expect(dish.peopleCount <= dish.reviewCount, "people are distinct reviewers; lines are not")
        #expect(dish.restaurantCity != "" && dish.restaurantLocality != "")

        // The stack IS the cover, ranked (0029): photos[0] is the thumbnail, no cover means no stack.
        #expect(dish.photos.first?.url == dish.coverURL)
        #expect(dish.coverURL != nil || dish.photos.isEmpty)
        #expect(dish.photos.allSatisfy { $0.url.isEmpty == false })

        // Two calls, one answer.
        let saved = try await StagingRPC.raw(
            client, "is_dish_saved", ["p_dish_id": StagingRPC.id(busiest.dishID)]
        )
        #expect(saved == "true" || saved == "false", "is_dish_saved must be a bare boolean")
        #expect(dish.saved == (saved == "true"), "dish_summary.saved and is_dish_saved disagree")
    }

    // MARK: - get_dish_reviews

    @Test("get_dish_reviews puts mine first, newest within, and pages on all three parts")
    func dishReviewsMineFirstAndPage() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let busiest = try #require(try await busiestDish(client).first)
            let whole = try await dishReviewPage(client, dish: busiest.dishID, size: 50)
            #expect(whole.isEmpty == false)
            #expect(whole.allSatisfy { $0.author.username.isEmpty == false }, "a line needs a handle")

            // design/v1/Dish puts "You" above the others.
            if let lastMine = whole.lastIndex(where: { $0.isMine }) {
                #expect(whole.prefix(lastMine + 1).allSatisfy { $0.isMine }, "a stranger's line sits above mine")
            }
            for (newer, older) in zip(whole, whole.dropFirst()) where newer.isMine == older.isMine {
                #expect(newer.createdAt >= older.createdAt, "newest-first broke inside a group")
            }

            var walked: [DishReviewRow] = []
            var cursor: DishReviewRow?
            var pages = 0
            repeat {
                let page = try await dishReviewPage(
                    client, dish: busiest.dishID, size: Self.pageSize, after: cursor
                )
                walked.append(contentsOf: page)
                cursor = page.count < Self.pageSize ? nil : page.last
                pages += 1
            } while cursor != nil && pages < 120
            let wholeAfter = try await dishReviewPage(client, dish: busiest.dishID, size: 50)
            KeysetWalk.expectMatches(
                walked.map(\.reviewID), before: whole.map(\.reviewID), after: wholeAfter.map(\.reviewID),
                "dish reviews 3-part"
            )
        }
    }

    /// A nullable `entry_id` is not a staging quirk: it is every review written before entries
    /// existed, and prod holds real ones. A client decoding it non-optional throws on them.
    @Test("a pre-entries line decodes: entry_id, score and note are all nullable")
    func dishReviewsTolerateNulls() async throws {
        let client = try await client()
        var lines: [DishReviewRow] = []
        for dish in try await busiestDish(client, limit: 6) {
            lines += try await dishReviewPage(client, dish: dish.dishID, size: 50)
        }
        #expect(lines.isEmpty == false)
        withKnownIssue(
            "staging holds no pre-entries line for these dishes; the optional decode is the contract",
            isIntermittent: true
        ) {
            #expect(lines.contains { $0.entryID == nil }, "entry_id must be decoded optional")
        }
        // photos[] belongs to the ENTRY, so a line with no entry cannot carry one.
        #expect(lines.allSatisfy { $0.entryID != nil || $0.photos.isEmpty })
    }

    func dishReviewPage(
        _ client: AteAPIClient, dish: UUID, size: Int, after last: DishReviewRow? = nil
    ) async throws -> [DishReviewRow] {
        try await StagingRPC.rows(client, "get_dish_reviews", [
            "p_dish_id": StagingRPC.id(dish),
            "p_cursor_mine": last.map { AnyJSON.bool($0.isMine) } ?? .null,
            "p_cursor_created_at": StagingRPC.maybeAt(last?.createdAt),
            "p_cursor_id": StagingRPC.maybeID(last?.reviewID),
            "p_page_size": .integer(size)
        ])
    }
}
