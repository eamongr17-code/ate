import Foundation

/// A dish in the shared global catalogue (`public.dishes`, data-model §1.3).
///
/// Identity is the composite `(restaurant_id, lower(name))`, enforced by the **partial** unique
/// index `dishes_identity_uq … WHERE merged_into_dish_id IS NULL`. Because it is partial, PostgREST
/// `upsert`/`onConflict` cannot target it (the 0014/0016 outage) — dish creation is
/// **select-then-insert**, which is why ``AteAPIClient`` exposes no upsert helper at all.
///
/// The derived average score and review count are NOT here — they live on ``DishStats``, where the
/// unrated state stays honestly `nil`.
public struct Dish: KeysetPaginated, Hashable {
    public static let table = "dishes"
    public static let columns =
        "id,name,restaurant_id,created_by_user_id,merged_into_dish_id,category,photo_url,created_at"

    public let id: UUID
    /// Display string. Never an identifier.
    public let name: String
    public let restaurantID: UUID
    /// Attribution; nullable because the author's profile delete sets it null.
    public let createdByUserID: UUID?
    /// Dedup tombstone (data-model §4). Non-nil ⇒ this dish was merged away; reads redirect.
    public let mergedIntoDishID: UUID?
    /// Free text by design (Meats/Sides/Mains/Pastry… observed) — deliberately not an enum.
    public let category: String?
    public let photoURLString: String?
    public let createdAt: Date

    public init(
        id: UUID,
        name: String,
        restaurantID: UUID,
        createdByUserID: UUID? = nil,
        mergedIntoDishID: UUID? = nil,
        category: String? = nil,
        photoURLString: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.restaurantID = restaurantID
        self.createdByUserID = createdByUserID
        self.mergedIntoDishID = mergedIntoDishID
        self.category = category
        self.photoURLString = photoURLString
        self.createdAt = createdAt
    }

    public var photoURL: URL? { photoURLString.flatMap(URL.init(string:)) }

    /// A merged-away dish: excluded from the live catalogue, kept for redirect + history.
    public var isTombstoned: Bool { mergedIntoDishID != nil }

    /// One-hop merge resolution (data-model §4: read-time is one hop; chains are flattened by a
    /// server-side job). Use this — never raw `id` — when navigating to a dish.
    public var canonicalDishID: UUID { mergedIntoDishID ?? id }

    public var pageCursor: PageCursor { PageCursor(createdAt: createdAt, id: id) }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case restaurantID = "restaurant_id"
        case createdByUserID = "created_by_user_id"
        case mergedIntoDishID = "merged_into_dish_id"
        case category
        case photoURLString = "photo_url"
        case createdAt = "created_at"
    }
}
