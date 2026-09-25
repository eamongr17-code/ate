import Foundation
import Supabase

// MARK: - Rows

/// **The dish page's header**, as `dish_summary(p_dish_id)` hands it over: the dish, where it is
/// served, what everybody has scored it, and whether the viewer has it saved — one round trip.
///
/// `score` is `nil` for a dish nobody has put a number on, and is never coalesced to zero
/// (data-model §1.3). `isSaved` is the viewer's own flag and is what draws the bookmark before any
/// broadcast has had something to say.
public struct DishSummary: Sendable, Hashable, Codable, Identifiable {
    public let dishID: UUID
    public let name: String
    public let restaurantID: UUID
    /// A display string — the page routes on ``restaurantID``.
    public let restaurantName: String
    /// The suburb under the dish's place. Never `restaurant_city` — on a live Google row that is a
    /// mangled slice of the formatted address (0029).
    public let restaurantLocality: String?
    /// The raw `restaurant_city` column. Decoded because it is in the shape; not drawn.
    public let restaurantCity: String?
    /// Mean of this dish's review scores to 1dp. An average lands anywhere (4.6), so it is a
    /// `Double` and not a ``Rating``.
    public let score: Double?
    public let reviewCount: Int
    /// Reviews that carried a number. `reviewCount - scoredCount` is how many people wrote about it
    /// without scoring it.
    public let scoredCount: Int
    /// How many different people — what the header prints beside the stars ("24 people").
    public let peopleCount: Int
    public let coverURLString: String?
    /// **The header's photo stack**, newest first — `photos[0].url` is the same as ``coverURL``.
    /// `[]` when the dish has none, and then no hero is drawn at all (0029). One round trip: never
    /// go looking for these among the reviews.
    public let photos: [DishPhoto]
    /// The viewer's own bookmark.
    public let isSaved: Bool
    /// The viewer's own most recent score, if they gave one. Held as a `Double` rather than a
    /// ``Rating`` so one out-of-range row could never take the whole header down; read it through
    /// ``myLastRating``, which is the half-step or nothing.
    public let myLastScore: Double?

    public var id: UUID { dishID }
    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }
    public var isRated: Bool { score != nil }
    public var myLastRating: Rating? { myLastScore.flatMap(Rating.init(exactly:)) }

    // The row is wide because the RPC is; a builder would only hide half of it.
    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        dishID: UUID,
        name: String,
        restaurantID: UUID,
        restaurantName: String,
        restaurantLocality: String? = nil,
        restaurantCity: String? = nil,
        score: Double? = nil,
        reviewCount: Int = 0,
        scoredCount: Int = 0,
        peopleCount: Int = 0,
        coverURLString: String? = nil,
        photos: [DishPhoto] = [],
        isSaved: Bool = false,
        myLastScore: Double? = nil
    ) {
        self.dishID = dishID
        self.name = name
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.restaurantLocality = restaurantLocality
        self.restaurantCity = restaurantCity
        self.score = score
        self.reviewCount = reviewCount
        self.scoredCount = scoredCount
        self.peopleCount = peopleCount
        self.coverURLString = coverURLString
        self.photos = photos
        self.isSaved = isSaved
        self.myLastScore = myLastScore
    }

    /// Hand-written so a project that has not taken 0029 still serves a decodable header: the two
    /// columns it appends — `restaurant_locality` and `photos` — are read with `decodeIfPresent`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.dishID = try container.decode(UUID.self, forKey: .dishID)
        self.name = try container.decode(String.self, forKey: .name)
        self.restaurantID = try container.decode(UUID.self, forKey: .restaurantID)
        self.restaurantName = try container.decode(String.self, forKey: .restaurantName)
        self.restaurantLocality = try container.decodeIfPresent(String.self, forKey: .restaurantLocality)
        self.restaurantCity = try container.decodeIfPresent(String.self, forKey: .restaurantCity)
        self.score = try container.decodeIfPresent(Double.self, forKey: .score)
        self.reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        self.scoredCount = try container.decodeIfPresent(Int.self, forKey: .scoredCount) ?? 0
        self.peopleCount = try container.decodeIfPresent(Int.self, forKey: .peopleCount) ?? 0
        self.coverURLString = try container.decodeIfPresent(String.self, forKey: .coverURLString)
        self.photos = try container.decodeIfPresent([DishPhoto].self, forKey: .photos) ?? []
        self.isSaved = try container.decodeIfPresent(Bool.self, forKey: .isSaved) ?? false
        self.myLastScore = try container.decodeIfPresent(Double.self, forKey: .myLastScore)
    }

    enum CodingKeys: String, CodingKey {
        case score, photos
        case dishID = "dish_id"
        case name = "dish_name"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case restaurantLocality = "restaurant_locality"
        case restaurantCity = "restaurant_city"
        case reviewCount = "review_count"
        case scoredCount = "scored_count"
        case peopleCount = "people_count"
        case coverURLString = "cover_url"
        case isSaved = "saved"
        case myLastScore = "my_last_score"
    }
}

/// One photo on the dish header's stack, and the visit it came out of.
public struct DishPhoto: Sendable, Hashable, Codable {
    public let url: String
    /// Which entry it was taken on. Optional for the same reason ``DishReview/entryID`` is.
    public let entryID: UUID?

    public init(url: String, entryID: UUID? = nil) {
        self.url = url
        self.entryID = entryID
    }

    enum CodingKeys: String, CodingKey {
        case url
        case entryID = "entry_id"
    }
}

/// One review of a dish — `get_dish_reviews`. Usually a door back to the visit it came out of.
public struct DishReview: Sendable, Hashable, Codable, Identifiable {
    public let reviewID: UUID
    /// The entry this line was printed on. Tapping the review opens it.
    ///
    /// **Optional, against the contract's own shape.** `reviews.entry_id` is nullable by design —
    /// migration 0018 keeps legacy reviews (`entry_id IS NULL`) working untouched — and staging
    /// serves them today, so decoding it as required takes the whole list down over one old row.
    /// A review with no entry still says what somebody thought; it simply has no visit to open, and
    /// the row is not a button. (Reported as a server gap: either backfill or document the null.)
    public let entryID: UUID?
    /// `nil` when the author is blocked or gone — the review still stands, it just loses its name.
    public let author: EntryCard.Author?
    /// `nil` = they gave no number. Design rule 7: an empty star, never a zero, never dimmed.
    public let score: Rating?
    /// A verbatim clause of their own words, or nothing.
    public let note: String?
    public let createdAt: Date
    /// The server's answer, not a comparison of ids on the client.
    public let isMine: Bool
    public let photos: [EntryCard.Photo]

    public var id: UUID { reviewID }

    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        reviewID: UUID,
        entryID: UUID?,
        author: EntryCard.Author? = nil,
        score: Rating? = nil,
        note: String? = nil,
        createdAt: Date,
        isMine: Bool = false,
        photos: [EntryCard.Photo] = []
    ) {
        self.reviewID = reviewID
        self.entryID = entryID
        self.author = author
        self.score = score
        self.note = note
        self.createdAt = createdAt
        self.isMine = isMine
        self.photos = photos
    }

    enum CodingKeys: String, CodingKey {
        case author, score, note, photos
        case reviewID = "review_id"
        case entryID = "entry_id"
        case createdAt = "created_at"
        case isMine = "is_mine"
    }

    /// Where this row sits in the stream, for the next page's request.
    public var pageCursor: DishReviewCursor {
        DishReviewCursor(isMine: isMine, createdAt: createdAt, id: reviewID)
    }
}

/// **A three-part keyset**, because `get_dish_reviews` orders `(is_mine, created_at, id) DESC` —
/// the viewer's own review sits above everyone else's (design/v1/Dish), so "mine" is part of the
/// sort key and a two-part `(created_at, id)` cursor would step straight past the boundary between
/// the two groups.
public struct DishReviewCursor: Sendable, Hashable, Codable {
    public let isMine: Bool
    public let createdAt: Date
    public let id: UUID

    public init(isMine: Bool, createdAt: Date, id: UUID) {
        self.isMine = isMine
        self.createdAt = createdAt
        self.id = id
    }
}

/// One page of a dish's reviews. Its own type rather than ``Page`` for the one reason above: the
/// cursor has three parts.
public struct DishReviewPage: Sendable, Equatable {
    public let items: [DishReview]
    public let nextCursor: DishReviewCursor?

    public init(items: [DishReview], nextCursor: DishReviewCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    /// "Last page" is a short read, exactly as ``Page`` infers it — no `count=exact` on every query.
    public init(items: [DishReview], requestedLimit: Int) {
        self.items = items
        self.nextCursor = items.count < requestedLimit ? nil : items.last?.pageCursor
    }

    public var isEmpty: Bool { items.isEmpty }
    public var isLastPage: Bool { nextCursor == nil }
}

/// **"You" first, then everybody else, newest first.**
///
/// The server already orders it that way; this is the client saying the same thing out loud, so the
/// one rule the artboard actually draws is covered by a test rather than by trust in a `select`. A
/// *stable* partition, so within each group the server's `(created_at, id) DESC` survives untouched
/// and a re-sort of an accumulated list is a no-op whenever the server has behaved.
public enum DishReviewOrder {
    public static func youFirst(_ reviews: [DishReview]) -> [DishReview] {
        reviews.filter(\.isMine) + reviews.filter { $0.isMine == false }
    }
}

// MARK: - The seam

/// Everything the dish page reads.
public protocol DishPageReading: Sendable {
    func dishSummary(dishID: UUID) async throws -> DishSummary
    func dishReviews(dishID: UUID, after cursor: DishReviewCursor?, pageSize: Int) async throws -> DishReviewPage
    /// `is_dish_saved(p_dish_id)`. ``DishSummary/isSaved`` is the same answer in the header's own
    /// round trip, so this exists as the cross-check the contract test makes, not as a second read
    /// the screen performs.
    func isDishSaved(dishID: UUID) async throws -> Bool
}

/// The live dish reads: `dish_summary`, `get_dish_reviews`, `is_dish_saved`.
public struct DishPageClient: DishPageReading {
    /// `get_dish_reviews` clamps `p_page_size` at 50.
    public static let maximumPageSize = 50

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func dishSummary(dishID: UUID) async throws -> DishSummary {
        let data = try await api.supabase
            .rpc("dish_summary", params: ["p_dish_id": AnyJSON.string(dishID.uuidString.lowercased())])
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([DishSummary].self, from: data)
        guard let row = rows.first else { throw AteAPIError.notFound(table: "dishes", id: dishID) }
        return row
    }

    public func dishReviews(
        dishID: UUID,
        after cursor: DishReviewCursor?,
        pageSize: Int
    ) async throws -> DishReviewPage {
        // No session required: a signed-out browser reads this as `anon` (0034), and the server
        // answers every viewer-relative field as a stranger's — nothing saved, nothing "mine".
        let limit = min(Self.maximumPageSize, max(1, pageSize))
        var parameters: [String: AnyJSON] = [
            "p_dish_id": .string(dishID.uuidString.lowercased()),
            "p_page_size": .integer(limit)
        ]
        // All three parts, or none: the server compares them as one row value.
        parameters["p_cursor_mine"] = cursor.map { .bool($0.isMine) } ?? .null
        parameters["p_cursor_created_at"] = cursor
            .map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null
        parameters["p_cursor_id"] = cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null

        let data = try await api.supabase
            .rpc("get_dish_reviews", params: parameters)
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([DishReview].self, from: data)
        return DishReviewPage(items: rows, requestedLimit: limit)
    }

    public func isDishSaved(dishID: UUID) async throws -> Bool {
        // Nobody signed in has saved anything — and `is_dish_saved` is not an `anon` read.
        guard api.isSignedIn else { return false }
        return try await api.rpc(
            "is_dish_saved",
            parameters: ["p_dish_id": .string(dishID.uuidString.lowercased())],
            decoding: Bool.self
        )
    }
}
