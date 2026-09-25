import Foundation

// **The Search tab's wire rows** — `search_places`, `nearby_places`, `search_dishes`, `search_people`
// and `search_saved` (migration 0031), exactly as `docs/backend/integration-design.md` writes them.
//
// Promoted verbatim from the backend lane's test support (`Support/SearchWireRows.swift`, which
// pinned the wire before this client existed), so the contract tests and ``SearchClient`` decode one
// set of types. Nothing here has a forgiving decoder: a renamed or dropped column fails in CI
// against real staging rows instead of leaving a blank row on somebody's phone.
//
// The two standing rules:
//   * an AGGREGATE is a `Double` (4.3 is a legal average and an illegal score); a USER'S score would
//     be a `Rating`, and none of these rows carries one.
//   * anything the server can legitimately not know is Optional — a cuisine nobody set, a locality we
//     cannot name, a dish nobody scored. Absent is never `""` and never `0`.
//
// Internal on purpose: the app draws ``PlaceResult``/``DishResult``/``PersonResult``/``SavedDish``;
// these are the shapes on the wire and nothing else.

// MARK: - Places scope + Nearby

/// `search_places` — design/v1/SearchResults' place row: name · cuisine · score.
struct SearchPlaceRow: Decodable, Sendable {
    let restaurantID: UUID
    let name: String
    let cuisine: String?
    /// The suburb chip, derived on read (`place_locality`). Never the raw `city`.
    let locality: String?
    /// Mean of per-dish averages — an average, not a score. Print as sent.
    let avgRating: Double?
    let reviewCount: Int
    let peopleCount: Int
    let dishCount: Int
    let coverURL: String?
    /// 0 exact · 1 prefix · 2 word-start · 3 contains. The leading sort key, and cursor part 1.
    let matchTier: Int

    enum CodingKeys: String, CodingKey {
        case name, cuisine, locality
        case restaurantID = "restaurant_id"
        case avgRating = "avg_rating"
        case reviewCount = "review_count"
        case peopleCount = "people_count"
        case dishCount = "dish_count"
        case coverURL = "cover_url"
        case matchTier = "match_tier"
    }
}

/// `nearby_places` — design/v1/Search's pre-typing list. Same row as a place hit, keyed on distance.
struct NearbyPlaceRow: Decodable, Sendable {
    let restaurantID: UUID
    let name: String
    let cuisine: String?
    let locality: String?
    let avgRating: Double?
    let reviewCount: Int
    let peopleCount: Int
    let dishCount: Int
    let coverURL: String?
    /// Metres from the query origin. The artboard does not print it; the cursor rides on it.
    let distanceM: Double

    enum CodingKeys: String, CodingKey {
        case name, cuisine, locality
        case restaurantID = "restaurant_id"
        case avgRating = "avg_rating"
        case reviewCount = "review_count"
        case peopleCount = "people_count"
        case dishCount = "dish_count"
        case coverURL = "cover_url"
        case distanceM = "distance_m"
    }
}

// MARK: - Dishes scope

/// `search_dishes` — the artboard's dish row in ONE call: cover · dish · place · score.
struct SearchDishRow: Decodable, Sendable {
    let dishID: UUID
    let dishName: String
    let restaurantID: UUID
    let restaurantName: String
    let restaurantLocality: String?
    /// Nobody scored it → null. An unscored dish with a line is still a result (DESIGN rule 7).
    let score: Double?
    let reviewCount: Int
    let scoredCount: Int
    let peopleCount: Int
    let coverURL: String?
    let matchTier: Int

    enum CodingKeys: String, CodingKey {
        case score
        case dishID = "dish_id"
        case dishName = "dish_name"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case restaurantLocality = "restaurant_locality"
        case reviewCount = "review_count"
        case scoredCount = "scored_count"
        case peopleCount = "people_count"
        case coverURL = "cover_url"
        case matchTier = "match_tier"
    }
}

// MARK: - People scope

/// `search_people` — handle · name · avatar, and nothing else is drawn.
struct SearchPersonRow: Decodable, Sendable {
    let userID: UUID
    let username: String
    let name: String
    let avatarURL: String?
    let city: String?
    /// The caller is included in their own results; the client decides whether to draw them.
    let isMe: Bool
    let matchTier: Int

    enum CodingKeys: String, CodingKey {
        case username, name, city
        case userID = "user_id"
        case avatarURL = "avatar_url"
        case isMe = "is_me"
        case matchTier = "match_tier"
    }
}

// MARK: - Saved scope

/// `search_saved` — `my_saved_dishes`' own columns (+ `restaurant_locality`), filtered.
struct SearchSavedRow: Decodable, Sendable {
    let dishID: UUID
    let dishName: String
    let restaurantID: UUID
    let restaurantName: String
    let restaurantCity: String?
    let restaurantLocality: String?
    let dishScore: Double?
    let dishCoverURL: String?
    let sourceEntryID: UUID?
    let sourceUserID: UUID?
    let sourceUsername: String?
    let savedAt: Date
    /// The same value as `dishCoverURL`; the newer name.
    let coverURL: String?

    enum CodingKeys: String, CodingKey {
        case dishID = "dish_id"
        case dishName = "dish_name"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case restaurantCity = "restaurant_city"
        case restaurantLocality = "restaurant_locality"
        case dishScore = "dish_score"
        case dishCoverURL = "dish_cover_url"
        case sourceEntryID = "source_entry_id"
        case sourceUserID = "source_user_id"
        case sourceUsername = "source_username"
        case savedAt = "saved_at"
        case coverURL = "cover_url"
    }
}
