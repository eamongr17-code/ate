import Foundation

@testable import AteKit

// The wire shapes of the Place / Dish / You / Ratings / Recap RPCs, exactly as
// `docs/backend/integration-design.md` writes them.
//
// They live in the test target on purpose: the screens that render them are being built in
// parallel, and a contract test should pin the WIRE, not wait for a type. Every field is named and
// nothing has a forgiving decoder, so a renamed or dropped column fails here — loudly, in CI,
// against real staging rows — instead of leaving a blank space on somebody's phone.
//
// Two rules repeat through these types:
//   * an AGGREGATE is a `Double` (4.3 is a legal average and an illegal score); a USER'S score is a
//     `Rating`, which validates the half-step on decode.
//   * anything the server can legitimately not know is Optional — `entry_id` on a pre-entries line,
//     a note nobody wrote, a locality we cannot name. Absent is never `""` and never `0`.

struct PlaceSummaryRow: Decodable, Sendable {
    let restaurantID: UUID
    let name: String
    let address: String?
    let city: String?
    let cuisine: String?
    let coverURL: String?
    let avgRating: Double?
    /// Receipt LINES at this place.
    let reviewCount: Int
    let peopleCount: Int
    let dishCount: Int
    let myVisits: Int
    let myLastVisit: Date?
    /// The second chip. `city` is unreliable on live Google rows; this is derived (0029).
    let locality: String?
    /// VISITS at this place — not the same number as `reviewCount`.
    let entryCount: Int

    enum CodingKeys: String, CodingKey {
        case name, city, cuisine, address, locality
        case restaurantID = "restaurant_id"
        case coverURL = "cover_url"
        case avgRating = "avg_rating"
        case reviewCount = "review_count"
        case peopleCount = "people_count"
        case dishCount = "dish_count"
        case myVisits = "my_visits"
        case myLastVisit = "my_last_visit"
        case entryCount = "entry_count"
    }
}

struct PlaceDishRow: Decodable, Sendable {
    let dishID: UUID
    let dishName: String
    let score: Double?
    let peopleCount: Int
    let reviewCount: Int
    let coverURL: String?

    enum CodingKeys: String, CodingKey {
        case score
        case dishID = "dish_id"
        case dishName = "dish_name"
        case peopleCount = "people_count"
        case reviewCount = "review_count"
        case coverURL = "cover_url"
    }
}

struct DishSummaryRow: Decodable, Sendable {
    let dishID: UUID
    let dishName: String
    let restaurantID: UUID
    let restaurantName: String
    let restaurantCity: String?
    let score: Double?
    let reviewCount: Int
    let scoredCount: Int
    let peopleCount: Int
    let coverURL: String?
    let saved: Bool
    let myLastScore: Rating?
    /// The header stack, newest first. `photos[0].url == coverURL`, by construction (0029).
    let photos: [DishPhotoRow]
    let restaurantLocality: String?

    enum CodingKeys: String, CodingKey {
        case score, saved, photos
        case dishID = "dish_id"
        case dishName = "dish_name"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case restaurantCity = "restaurant_city"
        case reviewCount = "review_count"
        case scoredCount = "scored_count"
        case peopleCount = "people_count"
        case coverURL = "cover_url"
        case myLastScore = "my_last_score"
        case restaurantLocality = "restaurant_locality"
    }
}

struct DishPhotoRow: Decodable, Sendable {
    let url: String
    let entryID: UUID?

    enum CodingKeys: String, CodingKey {
        case url
        case entryID = "entry_id"
    }
}

struct DishReviewRow: Decodable, Sendable {
    let reviewID: UUID
    /// **Nullable.** A line written before entries existed has no entry to open.
    let entryID: UUID?
    let author: EntryCard.Author
    let score: Rating?
    let note: String?
    let createdAt: Date
    let isMine: Bool
    /// The review's ENTRY's photos — so it can hold another dish from the same visit.
    let photos: [EntryCard.Photo]

    enum CodingKeys: String, CodingKey {
        case author, score, note, photos
        case reviewID = "review_id"
        case entryID = "entry_id"
        case createdAt = "created_at"
        case isMine = "is_mine"
    }
}

struct HistogramRow: Decodable, Sendable {
    /// A bucket is a half-step, so ``Rating`` is the assertion.
    let score: Rating
    /// Distinct dishes at this score — the "36 dishes" label.
    let dishCount: Int
    /// Times they gave it.
    let reviewCount: Int

    enum CodingKeys: String, CodingKey {
        case score
        case dishCount = "dish_count"
        case reviewCount = "review_count"
    }
}

struct ScoredDishRow: Decodable, Sendable {
    let reviewID: UUID
    let entryID: UUID?
    let dishID: UUID
    let dishName: String
    let restaurantID: UUID
    let restaurantName: String
    let score: Rating
    let note: String?
    /// The VISIT's date — a sorter-written line inherits its entry's `created_at`.
    let createdAt: Date
    /// The tile's photo: the DISH's cover (0029).
    let coverURL: String?

    enum CodingKeys: String, CodingKey {
        case score, note
        case reviewID = "review_id"
        case entryID = "entry_id"
        case dishID = "dish_id"
        case dishName = "dish_name"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case createdAt = "created_at"
        case coverURL = "cover_url"
    }
}

/// `month` stays a STRING: it is a `date` on the wire (`2026-09-01`), it is the cursor, and it is
/// what `monthly_statement(p_month)` wants back. Parsing and reformatting it can only lose.
struct StatementMonthRow: Decodable, Sendable {
    let month: String
    let orders: Int
}

struct MonthlyStatementRow: Decodable, Sendable {
    let month: String
    /// The handle the receipt prints under the month (0029).
    let username: String?
    let orders: Int
    let places: Int
    let newPlaces: Int
    let dishes: Int
    let stars: Double
    let average: Double?
    let topDishes: [TopDish]
    /// NULL below a count of 2 — once is not a habit (0029).
    let mostOrdered: MostOrdered?
    let mostVisited: MostVisited?

    enum CodingKeys: String, CodingKey {
        case month, username, orders, places, dishes, stars, average
        case newPlaces = "new_places"
        case topDishes = "top_dishes"
        case mostOrdered = "most_ordered"
        case mostVisited = "most_visited"
    }

    struct TopDish: Decodable, Sendable {
        let dishID: UUID
        let dishName: String
        let restaurantName: String
        let score: Rating

        enum CodingKeys: String, CodingKey {
            case score
            case dishID = "dish_id"
            case dishName = "dish_name"
            case restaurantName = "restaurant_name"
        }
    }

    struct MostOrdered: Decodable, Sendable {
        let dishName: String
        let count: Int

        enum CodingKeys: String, CodingKey {
            case count
            case dishName = "dish_name"
        }
    }

    struct MostVisited: Decodable, Sendable {
        let restaurantID: UUID
        let restaurantName: String
        let count: Int

        enum CodingKeys: String, CodingKey {
            case count
            case restaurantID = "restaurant_id"
            case restaurantName = "restaurant_name"
        }
    }
}
