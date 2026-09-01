import Foundation
import PostgREST
import Testing

@testable import AteKit

/// Decoding tests against **verbatim PostgREST payloads copied from staging** (project
/// `cvoitgoaosofkougmarn`, seeded Melbourne dataset). They run offline, so they guard the wire
/// contract on every commit; `StagingContractTests` then proves the same shapes are still live.
@Suite("Model decoding")
struct ModelDecodingTests {
    /// The exact decoder `supabase-swift` uses for PostgREST responses — same date strategy, and
    /// notably **no** snake_case key conversion, which is why every model spells its `CodingKeys`.
    static let decoder = PostgrestClient.Configuration.jsonDecoder

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Restaurant

    @Test("decodes a Places-backed restaurant, ignoring the PostGIS location blob")
    func decodesPlacesRestaurant() throws {
        // Verbatim `select=*` row — note `location` arrives as hex EWKB. Our column list excludes
        // it, but the model must not choke if something selects `*`.
        let restaurant = try Self.decode(Restaurant.self, """
        {
          "id": "a0000000-0000-4000-8000-000000000001",
          "google_place_id": "stub-chin-chin",
          "name": "Chin Chin",
          "address": "125 Flinders Ln",
          "city": "Melbourne",
          "location": "0101000020E61000001B2FDD24061F6240C6DCB5847CE842C0",
          "cuisine": "Thai",
          "cover_url": "https://images.unsplash.com/photo-1414235077428-338989a2e8c0?auto=format&fit=crop&w=800&q=70",
          "created_at": "2026-08-31T12:30:25.240956+00:00",
          "source": "places"
        }
        """)

        #expect(restaurant.id == UUID(uuidString: "a0000000-0000-4000-8000-000000000001"))
        #expect(restaurant.source == .places)
        #expect(restaurant.googlePlaceID == "stub-chin-chin")
        #expect(restaurant.isManual == false)
        #expect(restaurant.locality == "Melbourne")
        #expect(restaurant.coverURL?.host() == "images.unsplash.com")
    }

    @Test("a manual restaurant has no place id and may have no locality")
    func decodesManualRestaurant() throws {
        let restaurant = try Self.decode(Restaurant.self, """
        {
          "id": "a0000000-0000-4000-8000-0000000000ff",
          "google_place_id": null,
          "name": "Nonna's Kitchen Table",
          "address": null,
          "city": "",
          "cuisine": null,
          "cover_url": null,
          "created_at": "2026-08-31T12:30:25.240956+00:00",
          "source": "manual"
        }
        """)

        #expect(restaurant.isManual)
        #expect(restaurant.googlePlaceID == nil)
        // city is NOT NULL server-side; "" is the "no locality" sentinel, not a display value.
        #expect(restaurant.city.isEmpty)
        #expect(restaurant.locality == nil)
        #expect(restaurant.coverURL == nil)
    }

    // MARK: - Dish

    @Test("decodes a live dish")
    func decodesDish() throws {
        let dish = try Self.decode(Dish.self, """
        {
          "id": "b0000000-0000-4000-8000-000000000017",
          "name": "Twice-Baked Almond Croissant",
          "restaurant_id": "a0000000-0000-4000-8000-000000000006",
          "created_by_user_id": "e216041b-a9b4-43e9-92fa-af6dd0d3229b",
          "merged_into_dish_id": null,
          "category": "Pastry",
          "photo_url": null,
          "created_at": "2026-08-31T12:30:25.240956+00:00"
        }
        """)

        #expect(dish.name == "Twice-Baked Almond Croissant")
        #expect(dish.isTombstoned == false)
        #expect(dish.canonicalDishID == dish.id)
        #expect(dish.pageCursor.id == dish.id)
    }

    @Test("a tombstoned dish redirects to its survivor")
    func decodesMergedDish() throws {
        let dish = try Self.decode(Dish.self, """
        {
          "id": "b0000000-0000-4000-8000-0000000000aa",
          "name": "Beef Brisket",
          "restaurant_id": "a0000000-0000-4000-8000-000000000006",
          "created_by_user_id": null,
          "merged_into_dish_id": "b0000000-0000-4000-8000-0000000000bb",
          "category": null,
          "photo_url": null,
          "created_at": "2026-08-31T12:30:25.240956+00:00"
        }
        """)

        #expect(dish.isTombstoned)
        // Navigation must follow the redirect, never the raw id (data-model §4).
        #expect(dish.canonicalDishID == UUID(uuidString: "b0000000-0000-4000-8000-0000000000bb"))
        #expect(dish.createdByUserID == nil)  // author profile deleted → SET NULL
    }

    // MARK: - Review

    @Test("decodes a review, including the denormalised restaurant_id")
    func decodesReview() throws {
        let review = try Self.decode(Review.self, """
        {
          "id": "c0000000-0000-4000-8000-000000000004",
          "reviewer_id": "3e801ac3-88ab-4763-a686-aeab9b79c624",
          "dish_id": "b0000000-0000-4000-8000-000000000018",
          "restaurant_id": "a0000000-0000-4000-8000-000000000007",
          "score": 4.0,
          "note": "Clean, simple, well-blistered base. Slightly underseasoned.",
          "photo_url": null,
          "created_at": "2026-08-22T12:30:25.240956+00:00",
          "updated_at": "2026-08-31T12:30:25.240956+00:00",
          "like_count": 0,
          "comment_count": 0
        }
        """)

        #expect(review.score == Rating(rounding: 4))
        #expect(review.score.value == 4.0)
        #expect(review.restaurantID == UUID(uuidString: "a0000000-0000-4000-8000-000000000007"))
        #expect(review.hasPhoto == false)
        #expect(review.pageCursor == PageCursor(createdAt: review.createdAt, id: review.id))
    }

    @Test("a half-step score decodes; an off-grid one is rejected rather than silently rounded")
    func rejectsOffGridScore() throws {
        func reviewJSON(score: String) -> String {
            """
            {
              "id": "c0000000-0000-4000-8000-000000000004",
              "reviewer_id": "3e801ac3-88ab-4763-a686-aeab9b79c624",
              "dish_id": "b0000000-0000-4000-8000-000000000018",
              "restaurant_id": "a0000000-0000-4000-8000-000000000007",
              "score": \(score),
              "note": null, "photo_url": null,
              "created_at": "2026-08-22T12:30:25.240956+00:00",
              "updated_at": "2026-08-22T12:30:25.240956+00:00",
              "like_count": 0, "comment_count": 0
            }
            """
        }

        #expect(try Self.decode(Review.self, reviewJSON(score: "4.5")).score.value == 4.5)
        // The DB CHECK makes this impossible; if it ever arrives, we want a loud failure, not a
        // score the rating gesture can't represent.
        #expect(throws: (any Error).self) { try Self.decode(Review.self, reviewJSON(score: "4.3")) }
    }

    // MARK: - User

    @Test("decodes a profile row")
    func decodesUser() throws {
        let user = try Self.decode(User.self, """
        {
          "id": "e216041b-a9b4-43e9-92fa-af6dd0d3229b",
          "username": "crumbsmelb",
          "name": "Jess Okafor",
          "avatar_url": "https://i.pravatar.cc/300?img=26",
          "bio": "Croissant-first decision making.",
          "created_at": "2026-08-31T12:21:43.141378+00:00",
          "deleted_at": null,
          "follower_count": 3,
          "following_count": 3,
          "review_count": 8
        }
        """)

        #expect(user.handle == "@crumbsmelb")
        #expect(user.isDeactivated == false)
        #expect(user.reviewCount == 8)
    }

    @Test("a soft-deleted account still decodes")
    func decodesDeactivatedUser() throws {
        let user = try Self.decode(User.self, """
        {
          "id": "e216041b-a9b4-43e9-92fa-af6dd0d3229c",
          "username": "gone",
          "name": "Deleted account",
          "avatar_url": null,
          "bio": null,
          "created_at": "2026-08-31T12:21:43.141378+00:00",
          "deleted_at": "2026-08-31T13:00:00+00:00",
          "follower_count": 0,
          "following_count": 0,
          "review_count": 4
        }
        """)

        #expect(user.isDeactivated)
        // Their reviews survive — that's the point of the tombstone.
        #expect(user.reviewCount == 4)
    }

    // MARK: - Stats views (the NULL trap)

    @Test("dish_stats: a rated dish")
    func decodesDishStats() throws {
        let stats = try Self.decode(DishStats.self, """
        {
          "dish_id": "b0000000-0000-4000-8000-000000000001",
          "restaurant_id": "a0000000-0000-4000-8000-000000000001",
          "score": 4.5,
          "review_count": 3,
          "cover_url": "https://images.unsplash.com/photo-1414235077428-338989a2e8c0?auto=format&fit=crop&w=800&q=70"
        }
        """)

        #expect(stats.isRated)
        #expect(stats.score == 4.5)
        #expect(stats.id == stats.dishID)
    }

    @Test("dish_stats: an unreviewed dish scores nil — never 0")
    func decodesUnratedDishStats() throws {
        let stats = try Self.decode(DishStats.self, """
        {
          "dish_id": "b0000000-0000-4000-8000-000000000008",
          "restaurant_id": "a0000000-0000-4000-8000-000000000003",
          "score": null,
          "review_count": 0,
          "cover_url": null
        }
        """)

        #expect(stats.score == nil)
        #expect(stats.isRated == false)
        #expect(stats.reviewCount == 0)
        // The whole point: "?/5", not "0/5".
        #expect(stats.score ?? -1 != 0)
    }

    @Test("restaurant_stats: rating is the mean of per-dish averages, nil when nothing is rated")
    func decodesRestaurantStats() throws {
        let rated = try Self.decode(RestaurantStats.self, """
        {
          "restaurant_id": "a0000000-0000-4000-8000-000000000001",
          "avg_rating": 4.4,
          "review_count": 5,
          "cover_url": "https://images.unsplash.com/photo-1414235077428-338989a2e8c0?auto=format&fit=crop&w=800&q=70"
        }
        """)
        #expect(rated.avgRating == 4.4)
        #expect(rated.reviewCount == 5)

        let unrated = try Self.decode(RestaurantStats.self, """
        {
          "restaurant_id": "a0000000-0000-4000-8000-000000000009",
          "avg_rating": null,
          "review_count": 0,
          "cover_url": null
        }
        """)
        #expect(unrated.avgRating == nil)
        #expect(unrated.isRated == false)
    }

    // MARK: - Column lists

    @Test("no model selects '*' — every read names its columns")
    func columnListsAreExplicit() {
        let lists = [
            Restaurant.columns, Dish.columns, Review.columns,
            User.columns, DishStats.columns, RestaurantStats.columns
        ]
        for list in lists {
            #expect(list.contains("*") == false)
            #expect(list.contains(" ") == false)
        }
        // The PostGIS blob is never requested.
        #expect(Restaurant.columns.contains("location") == false)
    }
}
