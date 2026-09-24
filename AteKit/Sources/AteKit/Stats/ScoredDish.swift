import Foundation

/// **One dish you scored**, exactly as `dishes_by_score(p_user_id, p_score, p_limit)` returns it:
/// the row behind a histogram bar, and behind "Your 5.0s".
///
/// One row per *review*, not per dish — two sittings of the same pasta at 4.5 are two rows, because
/// the list is a record of what you did, and collapsing it would quietly delete a visit.
/// `entryID` is nullable: a review can outlive the entry it was written in (and the seeded rows
/// carry some that never had one), so a row is a dish first and a link to a visit second.
public struct ScoredDish: Sendable, Hashable, Codable, Identifiable {
    public let reviewID: UUID
    public let entryID: UUID?
    public let dishID: UUID
    /// A display string, never an identifier (ARCHITECTURE.md — UUID keys everywhere).
    public let dishName: String
    public let restaurantID: UUID?
    public let restaurantName: String?
    public let score: Double
    /// The sentence the sorter lifted out of the person's own words for this dish.
    public let note: String?
    public let createdAt: Date
    /// The dish's photo — what the "Your 5.0s" tile and the Ratings row draw. Absent for a dish
    /// nobody has photographed, which is a real state and not a failure: the tile is the field
    /// colour, never a broken-image mark.
    public let coverURL: String?

    /// The review, not the dish: the same dish can appear twice in one list.
    public var id: UUID { reviewID }

    public init(
        reviewID: UUID,
        entryID: UUID? = nil,
        dishID: UUID,
        dishName: String,
        restaurantID: UUID? = nil,
        restaurantName: String? = nil,
        score: Double,
        note: String? = nil,
        createdAt: Date,
        coverURL: String? = nil
    ) {
        self.reviewID = reviewID
        self.entryID = entryID
        self.dishID = dishID
        self.dishName = dishName
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.score = score
        self.note = note
        self.createdAt = createdAt
        self.coverURL = coverURL
    }

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

/// `dishes_by_score` is keyset-paged on `(created_at, id)` like every other list — the cursor is
/// the **review**'s id, which is this row's own id (ARCHITECTURE.md: every list query is paginated).
extension ScoredDish: AteRecord {
    /// Read through an RPC, never selected from directly.
    public static let table = "reviews"
    public static let columns = "*"
}

extension ScoredDish: KeysetPaginated {
    public var pageCursor: PageCursor { PageCursor(createdAt: createdAt, id: reviewID) }
}
