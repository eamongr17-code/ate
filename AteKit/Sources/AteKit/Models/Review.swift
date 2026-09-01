import Foundation

/// The atomic unit of Ate: one person's rating of one dish (`public.reviews`, data-model §1.4).
///
/// Note `restaurantID` is **denormalised** from the dish — the server trigger
/// `trg_review_set_restaurant` keeps it equal to `dishes.restaurant_id`, so "reviews at this
/// restaurant" never needs a dish join. Treat it as read-only derived truth on the client: set it
/// from the dish on write, never edit it independently.
///
/// Viewer-relative state (`liked`, `saved`) is deliberately absent — it is resolved per request
/// from the edge tables, not carried on the row.
public struct Review: KeysetPaginated, Hashable {
    public static let table = "reviews"
    public static let columns =
        "id,reviewer_id,dish_id,restaurant_id,score,note,photo_url,created_at,updated_at,like_count,comment_count"

    public let id: UUID
    /// The author. The column is `reviewer_id` — `author_id` in integration-design.md §Schema is
    /// stale prose; the migration is the contract.
    public let reviewerID: UUID
    public let dishID: UUID
    /// Denormalised from the dish, trigger-maintained. Always equals the dish's restaurant.
    public let restaurantID: UUID
    public let score: Rating
    public let note: String?
    public let photoURLString: String?
    public let createdAt: Date
    public let updatedAt: Date
    /// Denormalised counter caches (trigger-maintained, rebuildable from the edge tables).
    public let likeCount: Int
    public let commentCount: Int

    public init(
        id: UUID,
        reviewerID: UUID,
        dishID: UUID,
        restaurantID: UUID,
        score: Rating,
        note: String? = nil,
        photoURLString: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        likeCount: Int = 0,
        commentCount: Int = 0
    ) {
        self.id = id
        self.reviewerID = reviewerID
        self.dishID = dishID
        self.restaurantID = restaurantID
        self.score = score
        self.note = note
        self.photoURLString = photoURLString
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.likeCount = likeCount
        self.commentCount = commentCount
    }

    public var photoURL: URL? { photoURLString.flatMap(URL.init(string:)) }
    public var hasPhoto: Bool { photoURLString != nil }
    // Deliberately no `wasEdited` convenience: the staging seed backdates `created_at` but stamps
    // `updated_at = now()`, so `updatedAt > createdAt` is not a trustworthy "edited" signal.

    public var pageCursor: PageCursor { PageCursor(createdAt: createdAt, id: id) }

    private enum CodingKeys: String, CodingKey {
        case id
        case reviewerID = "reviewer_id"
        case dishID = "dish_id"
        case restaurantID = "restaurant_id"
        case score
        case note
        case photoURLString = "photo_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case likeCount = "like_count"
        case commentCount = "comment_count"
    }
}
