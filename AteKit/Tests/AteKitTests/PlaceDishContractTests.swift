import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **The place and dish pages, against the real staging rows.**
///
/// Unit tests prove the client decodes a payload we wrote down; only this proves each RPC is still
/// called by that name, still takes those parameters, and still answers with that shape. Every call
/// below is a named-argument PostgREST invocation — the kind of thing that breaks silently on the
/// client and loudly nowhere.
///
/// Read-only, opt-in (`ATE_CONTRACT_TESTS=1`), staging only, like its siblings.
@Suite("Place and dish contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct PlaceDishContractTests {
    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    /// A place that actually has a menu, found through the feed rather than hard-coded — a fixture
    /// id in a contract test is a fixture that goes stale.
    private func aPlaceWithDishes(_ client: AteAPIClient) async throws -> (PlaceSummary, [MenuDish]) {
        let places = PlacePageClient(api: client)
        let feed = try await EntryFeedClient(api: client).feedPage(after: nil, pageSize: 50, includeOwn: true)
        let candidates = feed.items.compactMap(\.place?.id).reduce(into: [UUID]()) { seen, id in
            if seen.contains(id) == false { seen.append(id) }
        }
        for id in candidates {
            let summary = try await places.placeSummary(restaurantID: id)
            let page = try await places.placeDishes(restaurantID: id, after: nil, pageSize: 200)
            if page.items.isEmpty == false { return (summary, page.items) }
        }
        Issue.record("staging needs one place with at least one dish")
        throw AteAPIError.notFound(table: "restaurants", id: UUID())
    }

    @Test("place_summary answers with the header the artboard draws")
    func placeSummaryShape() async throws {
        let client = try await client()
        let (summary, _) = try await aPlaceWithDishes(client)

        #expect(summary.name.isEmpty == false)
        #expect(summary.reviewCount >= 0)
        #expect(summary.dishCount >= 0)
        #expect(summary.myVisits >= 0)
        // Visits, not receipt lines — 0029 split the two, and a place cannot have more visits than
        // people times entries, but it can certainly have more lines than visits.
        #expect(summary.entryCount >= 0)
        #expect(summary.peopleCount >= 0 && summary.peopleCount <= summary.entryCount)
        // Never a zero standing in for "nothing here is rated" (data-model §1.3).
        if let rating = summary.avgRating { #expect(rating > 0 && rating <= 5) }
        // Every text field is null, never "" (0029) — a chip is a fact or it is nothing.
        #expect(summary.cuisine.map { $0.isEmpty } != true)
        #expect(summary.locality.map { $0.isEmpty } != true)
        #expect(summary.address.map { $0.isEmpty } != true)
    }

    @Test("place_dishes walks its four-part keyset without repeating a dish")
    func placeDishesPage() async throws {
        let client = try await client()
        let places = PlacePageClient(api: client)
        let (summary, all) = try await aPlaceWithDishes(client)

        var cursor: MenuDishCursor?
        var seen: [MenuDish] = []
        var pages = 0
        while pages < 10 {
            let page = try await places.placeDishes(
                restaurantID: summary.restaurantID, after: cursor, pageSize: 2
            )
            seen.append(contentsOf: page.items)
            pages += 1
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        #expect(Set(seen.map(\.dishID)).count == seen.count, "no dish twice across pages")
        #expect(seen.map(\.dishID) == all.map(\.dishID),
                "paging two at a time walks the same list, in the same order, as one big read")
    }

    @Test("place_dishes carries a score, both counts and a cover, in the server's own order")
    func placeDishesShape() async throws {
        let client = try await client()
        let (_, dishes) = try await aPlaceWithDishes(client)

        #expect(dishes.allSatisfy { $0.name.isEmpty == false })
        #expect(dishes.allSatisfy { $0.reviewCount >= 0 && $0.peopleCount >= 0 })
        #expect(dishes.allSatisfy { ($0.score ?? 1) > 0 }, "unrated is nil, never 0")
        #expect(Set(dishes.map(\.dishID)).count == dishes.count, "one row per dish")
        // 0030 moved the product's ranking rule into the `ORDER BY`, which is the only place a
        // paged list can hold one. This is the assertion that keeps it there: the rows come back
        // already in `DishRanking`'s order, so the page never sorts and never has to.
        #expect(DishRanking.rank(dishes).map(\.dishID) == dishes.map(\.dishID),
                "the server's order IS DishRanking's: review_count desc, score desc nulls last")
        // …and a dish nobody has written about is not on the menu at all.
        #expect(dishes.allSatisfy { $0.reviewCount > 0 }, "never-logged dishes are not returned")
    }

    @Test("get_entries_at_place walks each scope, keyset, without repeating an entry")
    func entriesAtPlacePages() async throws {
        let client = try await client()
        let places = PlacePageClient(api: client)
        let me = try await client.requireCurrentUserID()
        let (summary, _) = try await aPlaceWithDishes(client)

        for scope in PlaceEntryScope.allCases {
            var cursor: PageCursor?
            var seen: [EntryCard] = []
            var pages = 0
            while pages < 6 {
                let page = try await places.entriesAtPlace(
                    restaurantID: summary.restaurantID, scope: scope, after: cursor, pageSize: 3
                )
                seen.append(contentsOf: page.items)
                pages += 1
                guard let next = page.nextCursor else { break }
                cursor = next
            }
            #expect(Set(seen.map(\.id)).count == seen.count, "\(scope): no entry twice across pages")
            #expect(seen.allSatisfy { $0.restaurantID == summary.restaurantID })
            switch scope {
            case .mine: #expect(seen.allSatisfy { $0.authorID == me })
            case .others: #expect(seen.allSatisfy { $0.authorID != me })
            case .all: break
            }
            let ordered = zip(seen, seen.dropFirst()).allSatisfy { first, second in
                (first.createdAt, first.id.uuidString) > (second.createdAt, second.id.uuidString)
            }
            #expect(ordered, "\(scope): created_at DESC, id DESC")
        }
    }

    @Test("dish_summary carries the header, its photo stack, the save state and the last score")
    func dishSummaryShape() async throws {
        let client = try await client()
        let (place, dishes) = try await aPlaceWithDishes(client)
        let first = try #require(dishes.first)
        let summary = try await DishPageClient(api: client).dishSummary(dishID: first.dishID)

        #expect(summary.dishID == first.dishID)
        #expect(summary.name.isEmpty == false)
        #expect(summary.restaurantID == place.restaurantID)
        #expect(summary.restaurantName.isEmpty == false)
        #expect(summary.reviewCount >= summary.scoredCount)
        #expect(summary.peopleCount >= 0)
        if let score = summary.score { #expect(score > 0 && score <= 5) }
        // A half-step or nothing — `myLastScore` comes off `reviews.score`.
        if summary.myLastScore != nil { #expect(summary.myLastRating != nil) }
        // 0029: the header's own photo stack, newest first, first one == the cover.
        #expect(summary.photos.allSatisfy { $0.url.isEmpty == false })
        #expect(summary.photos.first?.url == summary.coverURLString)
        #expect(summary.restaurantLocality.map { $0.isEmpty } != true)
    }

    @Test("is_dish_saved agrees with dish_summary.saved — one answer, two ways to ask")
    func savedFlagsAgree() async throws {
        let client = try await client()
        let (_, dishes) = try await aPlaceWithDishes(client)
        let first = try #require(dishes.first)
        let dishClient = DishPageClient(api: client)

        let summary = try await dishClient.dishSummary(dishID: first.dishID)
        let flag = try await dishClient.isDishSaved(dishID: first.dishID)
        #expect(summary.isSaved == flag)
    }

    @Test("get_dish_reviews puts mine first and walks the three-part keyset cleanly")
    func dishReviewsPage() async throws {
        let client = try await client()
        let (_, dishes) = try await aPlaceWithDishes(client)
        let dishClient = DishPageClient(api: client)
        // A dish with enough reviews to cross a page boundary at size 2.
        let busiest = try #require(dishes.max { $0.reviewCount < $1.reviewCount })

        var cursor: DishReviewCursor?
        var seen: [DishReview] = []
        var pages = 0
        while pages < 8 {
            let page = try await dishClient.dishReviews(dishID: busiest.dishID, after: cursor, pageSize: 2)
            seen.append(contentsOf: page.items)
            pages += 1
            guard let next = page.nextCursor else { break }
            cursor = next
        }

        #expect(seen.isEmpty == false, "a dish on the menu has been written about")
        #expect(Set(seen.map(\.reviewID)).count == seen.count, "no review twice across pages")
        // The one rule the artboard draws: You sits above everyone else.
        #expect(seen.map(\.isMine) == seen.map(\.isMine).sorted(by: { $0 && !$1 }))
        // `entry_id` is the field the page navigates on, and it is **nullable in practice**:
        // migration 0018 keeps legacy reviews (`entry_id IS NULL`) working, and staging still
        // serves them (4 of 6 on the busiest seeded dish). The contract's Reads table does not say
        // so. Asserted here as the tolerance the client actually needs — decoding it as required
        // took the whole list down over one old row — not as an absence the data does not have.
        #expect(seen.allSatisfy { $0.entryID != $0.reviewID })
        // A review with no number decodes as nil rather than failing or arriving as zero.
        _ = seen.map(\.score)
        #expect(seen.allSatisfy { $0.author != nil }, "a reviewer's handle draws the row")
    }
}
