import Foundation

@testable import AteKit

// The wire shapes of the Search tab's four scopes, its Nearby list, and the account/blocks reads —
// exactly as `docs/backend/integration-design.md` writes them (migrations 0031, 0032).
//
// They live in the test target for the same reason `DetailWireRows` does: the Search screen is being
// built in the lane next door, and a contract test should pin the WIRE, not wait for a type. Nothing
// here has a forgiving decoder, so a renamed or dropped column fails in CI against real staging rows
// instead of leaving a blank row on somebody's phone.
//
// The two standing rules:
//   * an AGGREGATE is a `Double` (4.3 is a legal average and an illegal score); a USER'S score would
//     be a `Rating`, and none of these rows carries one.
//   * anything the server can legitimately not know is Optional — a cuisine nobody set, a locality we
//     cannot name, a dish nobody scored. Absent is never `""` and never `0`.

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

// MARK: - search_all (unchanged shape, the composer's place sheet reads it)

struct SearchAllWireRow: Decodable, Sendable {
    let kind: String
    let id: UUID
    let title: String
    let subtitle: String?
    let score: Double?
    let matchRank: Double?
    let detail: [String: AnyCodableValue]?

    enum CodingKeys: String, CodingKey {
        case kind, id, title, subtitle, score, detail
        case matchRank = "match_rank"
    }
}

/// Just enough to assert a `detail` key exists and is (or is not) null — the jsonb bag is documented
/// per kind and deliberately not modelled.
enum AnyCodableValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case other

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        self = .other
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }
    var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
}

// MARK: - Account + blocks (0032)

/// `my_blocks` — design/v1/Settings' blocked list. The profile fields come through a DEFINER read
/// because the `profiles` policy hides exactly these people from exactly this viewer.
struct MyBlockRow: Decodable, Sendable {
    let blockedID: UUID
    let username: String?
    let name: String?
    let avatarURL: String?
    let city: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case username, name, city
        case blockedID = "blocked_id"
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
    }
}

/// `delete_account` — `{ok, auth_user_deleted}`. `auth_user_deleted == false` means the data is gone
/// but the auth row survived and the account can still be signed into: report it, do not ignore it.
struct DeleteAccountResult: Decodable, Sendable {
    let ok: Bool
    let authUserDeleted: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case authUserDeleted = "auth_user_deleted"
    }
}
