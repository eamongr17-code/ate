import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **Signed-out browse** (migration 0034): "See what everyone's eating" on design/v1 Welcome.
///
/// Every call here goes out with the publishable key and NO session — the `anon` role. What it
/// guards:
///
/// - **The nine browse reads answer anon with rows.** Feed, a place (header, menu, entries), a dish
///   (header, reviews, saved state) and someone's profile (header, entries), each chained off the
///   previous read, so the suite needs no fixture ids.
/// - **"No viewer" is FALSE, never null.** `is_mine`, `is_me`, `saved`, `items[].saved` decode as
///   `Bool`; the `x = auth.uid()` they are computed from is NULL for anon, and a null would fail the
///   decode on the device. `my_visits` is 0, and the 'mine' scope is empty.
/// - **Anon still has nothing raw and can write nothing.** A raw `restaurants` read stays `[]` (the
///   CI curl gate), `entries` and the `entry_cards` view are refused, and an insert, a save and a
///   search are all refused.
///
/// Opt-in like its siblings: `ATE_CONTRACT_TESTS=1`, staging only, never prod (rule 5). Read-only:
/// every write attempted here is one the server must refuse.
@Suite("Signed-out browse — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct BrowseContractTests {
    /// No sign-in: the publishable key alone.
    func anon() -> AteAPIClient {
        let client = AteAPIClient(supabase: StagingContract.makeClient())
        #expect(client.isSignedIn == false)
        return client
    }

    func feed(_ client: AteAPIClient) async throws -> [EntryCard] {
        try await StagingRPC.rows(client, "get_entry_feed", [
            "p_cursor_created_at": .null,
            "p_cursor_id": .null,
            "p_page_size": .integer(50),
            "p_include_own": .bool(false)
        ])
    }

    @Test("the feed answers anon with public entries and no viewer-relative truth")
    func feedForAnon() async throws {
        let cards = try await feed(anon())
        #expect(cards.isEmpty == false, "a signed-out browser must see the feed")
        #expect(cards.allSatisfy { $0.visibility == .public })
        #expect(cards.allSatisfy { $0.isMine == false })
        #expect(cards.allSatisfy { $0.items.allSatisfy { $0.saved == false } }, "nobody is looking: nothing is saved")
        #expect(cards.allSatisfy { $0.author?.username.isEmpty == false }, "a slip needs a byline")
        let ordered = zip(cards, cards.dropFirst()).allSatisfy { first, second in
            (first.createdAt, first.id.uuidString) > (second.createdAt, second.id.uuidString)
        }
        #expect(ordered, "created_at DESC, id DESC — the same keyset as signed in")
    }

    @Test("a place page reads for anon: header, menu, entries — and no 'you' rows")
    func placeForAnon() async throws {
        let client = anon()
        let placeID = try #require(
            try await feed(client).first { $0.place != nil && $0.items.isEmpty == false }?.place?.id,
            "the feed holds an entry at a place with a receipt"
        )

        let summary = try #require(
            try await StagingRPC.rows(client, "place_summary", ["p_restaurant_id": StagingRPC.id(placeID)],
                                      as: PlaceSummary.self).first
        )
        #expect(summary.myVisits == 0)
        #expect(summary.myLastVisit == nil)

        let menu: [MenuDish] = try await StagingRPC.rows(client, "place_dishes", [
            "p_restaurant_id": StagingRPC.id(placeID), "p_limit": .integer(50)
        ])
        #expect(menu.isEmpty == false, "a place with a receipt has a menu")

        func entries(_ scope: String) async throws -> [EntryCard] {
            try await StagingRPC.rows(client, "get_entries_at_place", [
                "p_restaurant_id": StagingRPC.id(placeID), "p_scope": .string(scope),
                "p_cursor_created_at": .null, "p_cursor_id": .null, "p_page_size": .integer(20)
            ])
        }
        let all = try await entries("all")
        #expect(all.isEmpty == false)
        #expect(all.allSatisfy { $0.isMine == false && $0.restaurantID == placeID })
        #expect(try await entries("mine").isEmpty, "a signed-out browser has no visits")
        #expect(try await entries("others").map(\.id) == all.map(\.id), "with no viewer, others is everyone")
    }

    @Test("a dish page reads for anon: header, reviews, and it is not saved")
    func dishForAnon() async throws {
        let client = anon()
        let dishID = try #require(try await feed(client).lazy.flatMap(\.items).first?.dishID)

        let summary = try #require(
            try await StagingRPC.rows(client, "dish_summary", ["p_dish_id": StagingRPC.id(dishID)],
                                      as: DishSummary.self).first
        )
        #expect(summary.dishID == dishID)
        #expect(summary.myLastScore == nil)

        let reviews: [DishReview] = try await StagingRPC.rows(client, "get_dish_reviews", [
            "p_dish_id": StagingRPC.id(dishID), "p_cursor_mine": .null,
            "p_cursor_created_at": .null, "p_cursor_id": .null, "p_page_size": .integer(20)
        ])
        #expect(reviews.isEmpty == false, "the dish came off a receipt, so it has a line")
        #expect(reviews.allSatisfy { $0.isMine == false })

        #expect(try await StagingRPC.raw(client, "is_dish_saved", ["p_dish_id": StagingRPC.id(dishID)]) == "false")
    }

    @Test("someone's profile reads for anon: header and entries, and it is never 'me'")
    func profileForAnon() async throws {
        let client = anon()
        let authorID = try #require(try await feed(client).first?.authorID)

        let summary = try #require(
            try await StagingRPC.rows(client, "profile_summary", ["p_user_id": StagingRPC.id(authorID)],
                                      as: ProfileSummary.self).first
        )
        #expect(summary.userID == authorID)
        #expect(summary.isMe == false)
        #expect(summary.username.isEmpty == false)

        let theirs: [EntryCard] = try await StagingRPC.rows(client, "get_entries_by_author", [
            "p_author_id": StagingRPC.id(authorID),
            "p_cursor_created_at": .null, "p_cursor_id": .null, "p_page_size": .integer(20)
        ])
        #expect(theirs.isEmpty == false)
        #expect(theirs.allSatisfy { $0.authorID == authorID && $0.isMine == false })
    }

    @Test("anon still reads nothing raw, and every write and search is refused")
    func anonIsStillLockedOut() async throws {
        let client = anon()
        let someEntry = try #require(try await feed(client).first { $0.items.isEmpty == false })
        let dishID = try #require(someEntry.items.first?.dishID)

        // Raw tables and the view: `[]` (RLS, no anon policy) or refused (no grant) — never rows.
        let restaurants = try await client.fetchAll(Restaurant.self) { $0.limit(1) }
        #expect(restaurants.isEmpty, "the CI RLS gate: anon selects no restaurant rows")
        for table in ["entries", "profiles", "reviews", EntryCard.table] {
            let rows = try? await client.supabase.from(table).select("id").limit(1).execute().data
            let count = rows.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }?.count ?? 0
            #expect(count == 0, "anon must not read `\(table)` directly")
        }

        // Writes: refused, whatever the path.
        await #expect(throws: (any Error).self, "anon cannot insert an entry") {
            _ = try await client.supabase.from("entries").insert([
                "id": UUID().uuidString.lowercased(),
                "author_id": someEntry.authorID.uuidString.lowercased(),
                "body": "browse contract: this insert must be refused"
            ]).execute()
        }
        await #expect(throws: (any Error).self, "anon cannot save") {
            try await client.callRPC("save_dish", parameters: [
                "p_dish_id": StagingRPC.id(dishID), "p_source_entry_id": StagingRPC.id(someEntry.id)
            ])
        }
        await #expect(throws: (any Error).self, "anon cannot delete an account") {
            try await client.callRPC("delete_account")
        }
        // Search is signed-in only.
        await #expect(throws: (any Error).self, "anon cannot search") {
            let _: [SearchPlaceRow] = try await StagingRPC.rows(client, "search_places", ["p_query": .string("pizza")])
        }
    }
}
