import Foundation

// The wire rows `Round4ContractTests` decodes (split out to keep the suite under the file-length rule).
// MARK: - Wire rows

extension Round4ContractTests {
    struct Span: Encodable, Sendable {
        let offset: Int
        let length: Int
    }

    struct SortRequest: Encodable, Sendable {
        let entryID: String
        var force = false
        let sixTokens: [Span]
        enum CodingKeys: String, CodingKey {
            case force
            case entryID = "entry_id"
            case sixTokens = "six_tokens"
        }
    }

    struct PreviewRequest: Encodable, Sendable {
        let preview = true
        let body: String
        let restaurantID: String
        let sixTokens: [Span]
        enum CodingKeys: String, CodingKey {
            case preview, body
            case restaurantID = "restaurant_id"
            case sixTokens = "six_tokens"
        }
    }

    struct PlanItem: Decodable, Sendable {
        let dishName: String
        let score: Double?
        enum CodingKeys: String, CodingKey {
            case score
            case dishName = "dish_name"
        }
    }

    struct PlanReply: Decodable, Sendable {
        let ok: Bool?
        let items: [PlanItem]?
    }

    struct Line: Decodable, Sendable {
        let reviewID: UUID
        let dishID: UUID
        let dishName: String
        let score: Double?
        let tags: [String]
        enum CodingKeys: String, CodingKey {
            case score, tags
            case reviewID = "review_id"
            case dishID = "dish_id"
            case dishName = "dish_name"
        }
    }

    struct Card: Decodable, Sendable {
        let id: UUID
        let restaurantID: UUID?
        let items: [Line]
        enum CodingKeys: String, CodingKey {
            case id, items
            case restaurantID = "restaurant_id"
        }
    }

    struct Bucket: Decodable, Sendable {
        let score: Double
        let dishCount: Int
        let reviewCount: Int
        enum CodingKeys: String, CodingKey {
            case score
            case dishCount = "dish_count"
            case reviewCount = "review_count"
        }
    }

    struct DishHeader: Decodable, Sendable {
        let myLastScore: Double?
        let tags: [String]
        enum CodingKeys: String, CodingKey {
            case tags
            case myLastScore = "my_last_score"
        }
    }

    struct Cuisine: Decodable, Sendable {
        let cuisine: String
        let placeCount: Int
        enum CodingKeys: String, CodingKey {
            case cuisine
            case placeCount = "place_count"
        }
    }

    struct PlaceRow: Decodable, Sendable {
        let restaurantID: UUID
        let name: String
        let cuisine: String?
        let avgRating: Double?
        let reviewCount: Int
        let matchTier: Int?
        let distanceM: Double?
        enum CodingKeys: String, CodingKey {
            case name, cuisine
            case restaurantID = "restaurant_id"
            case avgRating = "avg_rating"
            case reviewCount = "review_count"
            case matchTier = "match_tier"
            case distanceM = "distance_m"
        }
    }

    struct DishRow: Decodable, Sendable {
        let dishID: UUID
        let dishName: String
        let score: Double?
        let tags: [String]
        enum CodingKeys: String, CodingKey {
            case score, tags
            case dishID = "dish_id"
            case dishName = "dish_name"
        }
    }

    struct JournalRow: Decodable, Sendable, Hashable {
        let id: UUID
        let createdAt: Date
        let bestScore: Double?
        enum CodingKeys: String, CodingKey {
            case id
            case createdAt = "created_at"
            case bestScore = "best_score"
        }
    }

    struct JournalPlace: Decodable, Sendable {
        let restaurantID: UUID
        let name: String
        let locality: String?
        let entryCount: Int
        enum CodingKeys: String, CodingKey {
            case name, locality
            case restaurantID = "restaurant_id"
            case entryCount = "entry_count"
        }
    }
}
