import Foundation
import PostgREST
import Testing

@testable import AteKit

/// Decoding for the embedded feed row, against a **verbatim payload copied from staging** (the
/// exact `select` in ``FeedEntry/columns``, run against project `cvoitgoaosofkougmarn`).
@Suite("Feed entry decoding")
struct FeedEntryDecodingTests {
    static let decoder = PostgrestClient.Configuration.jsonDecoder

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test("decodes a review with its dish, restaurant and author embedded")
    func decodesEntry() throws {
        let entry = try Self.decode(FeedEntry.self, """
        {
          "id": "c0000000-0000-4000-8000-000000000030",
          "reviewer_id": "faa932ff-0f06-4826-8701-8a162be30749",
          "dish_id": "b0000000-0000-4000-8000-000000000009",
          "restaurant_id": "a0000000-0000-4000-8000-000000000003",
          "score": 5.0,
          "note": "Emulsified properly. No clumps, no oil slick. Rare.",
          "photo_url": "https://images.unsplash.com/photo-1551782450-a2132b4ba21d?auto=format&fit=crop&w=800&q=70",
          "created_at": "2026-08-30T12:30:25.240956+00:00",
          "updated_at": "2026-08-31T12:30:25.240956+00:00",
          "like_count": 2,
          "comment_count": 1,
          "dish": {
            "id": "b0000000-0000-4000-8000-000000000009",
            "name": "Cacio e Pepe",
            "merged_into_dish_id": null
          },
          "restaurant": {
            "id": "a0000000-0000-4000-8000-000000000003",
            "city": "Melbourne",
            "name": "Tipo 00"
          },
          "author": {
            "id": "faa932ff-0f06-4826-8701-8a162be30749",
            "name": "Marco Bellini",
            "username": "pastaindex",
            "avatar_url": "https://i.pravatar.cc/300?img=59"
          }
        }
        """)

        // The review decodes from the same top-level object, embeds and all.
        #expect(entry.id == UUID(uuidString: "c0000000-0000-4000-8000-000000000030"))
        #expect(entry.review.score == Rating(exactly: 5.0))
        #expect(entry.review.hasPhoto)
        #expect(entry.review.reviewerID == entry.author?.id)

        #expect(entry.dish.name == "Cacio e Pepe")
        #expect(entry.restaurant.name == "Tipo 00")
        #expect(entry.restaurant.locality == "Melbourne")
        #expect(entry.author?.handle == "@pastaindex")
        #expect(entry.author?.avatarURL?.host() == "i.pravatar.cc")

        // The cursor is the review's — the feed pages on `reviews`, not on the embeds.
        #expect(entry.pageCursor == entry.review.pageCursor)
    }

    @Test("a merged-away dish routes to its survivor, not to the tombstone")
    func routesThroughTheMerge() throws {
        let entry = try Self.decode(FeedEntry.self, """
        {
          "id": "c0000000-0000-4000-8000-000000000030",
          "reviewer_id": "faa932ff-0f06-4826-8701-8a162be30749",
          "dish_id": "b0000000-0000-4000-8000-000000000009",
          "restaurant_id": "a0000000-0000-4000-8000-000000000003",
          "score": 3.5,
          "note": null,
          "photo_url": null,
          "created_at": "2026-08-30T12:30:25.240956+00:00",
          "updated_at": "2026-08-30T12:30:25.240956+00:00",
          "like_count": 0,
          "comment_count": 0,
          "dish": {
            "id": "b0000000-0000-4000-8000-000000000009",
            "name": "Beef Brisket",
            "merged_into_dish_id": "b0000000-0000-4000-8000-000000000002"
          },
          "restaurant": { "id": "a0000000-0000-4000-8000-000000000003", "city": "", "name": "Nonna's" },
          "author": null
        }
        """)

        #expect(entry.dishRoute.dishID == UUID(uuidString: "b0000000-0000-4000-8000-000000000002"))
        #expect(entry.dish.canonicalID != entry.dish.id)
        // `city: ""` is the manual-restaurant "no locality" sentinel — a row omits the suburb.
        #expect(entry.restaurant.locality == nil)
        // An unreadable author costs the byline, not the row.
        #expect(entry.author == nil)
        #expect(entry.review.note == nil)
        #expect(entry.review.hasPhoto == false)
    }

    @Test("the select list disambiguates every embed and never asks for the PostGIS blob")
    func columnListIsExplicitAndDisambiguated() {
        let columns = FeedEntry.columns
        #expect(FeedEntry.table == "reviews")
        #expect(columns.contains("*") == false)
        // `profiles` is reachable from `reviews` three ways (reviewer_id, review_likes,
        // review_tags); a bare embed is a PostgREST 300 Multiple Choices.
        #expect(columns.contains("author:profiles!reviews_reviewer_id_fkey"))
        #expect(columns.contains("dish:dishes!reviews_dish_id_fkey"))
        #expect(columns.contains("restaurant:restaurants!reviews_restaurant_id_fkey"))
        // restaurants.location is hex EWKB — never fetched.
        #expect(columns.contains("location") == false)
        // Built from Review.columns, so the review shape can't drift out of the feed.
        #expect(columns.hasPrefix(Review.columns))
    }
}
