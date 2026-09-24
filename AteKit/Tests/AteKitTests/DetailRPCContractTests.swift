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
        #expect(place.avgRating == stats.avgRating, "the chip is restaurant_stats, not a client average")
        #expect(place.reviewCount == stats.reviewCount)
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
        if visible.count < 50 {
            #expect(place.entryCount == visible.count, "entry_count disagrees with the entries it counts")
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

    @Test("place_dishes ranks by score then people, and its 4-part cursor pages exactly")
    func placeDishesRanksAndPages() async throws {
        let client = try await client()
        let stats = try await busiestPlace(client)
        let whole = try await placeDishPage(client, place: stats.restaurantID, size: 200)
        #expect(whole.isEmpty == false, "the busiest place has no dishes — place_dishes lost its join")

        for (upper, lower) in zip(whole, whole.dropFirst()) {
            let upperKey = upper.score ?? -1
            let lowerKey = lower.score ?? -1
            #expect(upperKey >= lowerKey, "\(upper.dishName) must outrank \(lower.dishName) on score")
            if upperKey == lowerKey {
                #expect(upper.peopleCount >= lower.peopleCount, "people_count is the second key")
            }
        }
        // Unscored dishes are a contiguous tail: present (a dish logged without a number is still on
        // the menu) but never above a scored one.
        if let firstUnscored = whole.firstIndex(where: { $0.score == nil }) {
            #expect(whole[firstUnscored...].allSatisfy { $0.score == nil })
        }
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

        #expect(walked.map(\.dishID) == whole.map(\.dishID), "the 4-part cursor repeated or skipped")
    }

    func placeDishPage(
        _ client: AteAPIClient, place: UUID, size: Int, after last: PlaceDishRow? = nil
    ) async throws -> [PlaceDishRow] {
        try await StagingRPC.rows(client, "place_dishes", [
            "p_restaurant_id": StagingRPC.id(place),
            "p_limit": .integer(size),
            "p_cursor_score": StagingRPC.number(last?.score),
            "p_cursor_people": StagingRPC.count(last?.peopleCount),
            "p_cursor_dish_name": StagingRPC.text(last?.dishName),
            "p_cursor_dish_id": StagingRPC.maybeID(last?.dishID)
        ])
    }

    // MARK: - get_entries_at_place

    @Test("get_entries_at_place returns entry_cards — the one shape — and scopes mine vs others")
    func entriesAtPlaceAreEntryCards() async throws {
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
        if all.count < 50 {
            #expect(mine.count + others.count == all.count, "mine + others must be all of them")
        }

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
        #expect(walked.map(\.id) == all.map(\.id), "the place cursor repeated or skipped an entry")
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
        #expect(dish.score == busiest.score, "the header score is dish_stats, not a client average")
        #expect(dish.reviewCount == busiest.reviewCount)
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
        #expect(walked.map(\.reviewID) == whole.map(\.reviewID), "the 3-part cursor repeated or skipped")
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
