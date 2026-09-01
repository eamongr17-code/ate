import Foundation

/// One row of the global feed: a ``Review`` plus the three display strings a row needs — the dish
/// it is about, where that dish is, and who wrote it.
///
/// **Why one record instead of four requests.** A review carries only UUIDs; the feed row shows
/// names. Rather than page the reviews and then batch-hydrate dishes/restaurants/profiles (four
/// round trips, four failure modes, a visible pop-in as names arrive), the display strings are
/// *embedded* in the same PostgREST select through the existing foreign keys. One request, one
/// decode, and a row that is complete the instant it exists.
///
/// The embeds are FK-hinted (`dishes!reviews_dish_id_fkey`) rather than bare table names. That is
/// not decoration: `profiles` is reachable from `reviews` three ways (`reviewer_id`, plus the
/// `review_likes` and `review_tags` join tables), so a bare `profiles(…)` embed is ambiguous and
/// PostgREST answers **300 Multiple Choices**. Naming the constraint pins the join.
///
/// Column lists stay explicit here as everywhere (``AteRecord``) — and note what is *not* selected:
/// `restaurants.location` is PostGIS EWKB, useless to the client and pure payload weight.
public struct FeedEntry: KeysetPaginated, Hashable {
    public static let table = Review.table

    /// The review's own columns, plus the three embeds. Built from ``Review/columns`` so a change
    /// to the review shape can't drift out of the feed.
    public static let columns = [
        Review.columns,
        "dish:dishes!reviews_dish_id_fkey(id,name,merged_into_dish_id)",
        "restaurant:restaurants!reviews_restaurant_id_fkey(id,name,city)",
        "author:profiles!reviews_reviewer_id_fkey(id,username,name,avatar_url)"
    ].joined(separator: ",")

    /// The review itself — the atom. Everything else on this type is display sugar around it.
    public let review: Review
    public let dish: DishSummary
    public let restaurant: RestaurantSummary
    /// Optional purely defensively: the FK is NOT NULL and `profiles_select_all` makes every
    /// profile readable to an authenticated viewer, so this is non-nil in practice. Decoding it as
    /// optional means one unexpected invisible author costs one anonymous row, not the whole page.
    public let author: AuthorSummary?

    public init(
        review: Review,
        dish: DishSummary,
        restaurant: RestaurantSummary,
        author: AuthorSummary? = nil
    ) {
        self.review = review
        self.dish = dish
        self.restaurant = restaurant
        self.author = author
    }

    public var id: UUID { review.id }
    public var pageCursor: PageCursor { review.pageCursor }

    /// Where tapping this row goes. Uses the dish's *canonical* id so a merged-away dish opens the
    /// survivor (data-model §4), never a tombstone.
    public var dishRoute: DishRoute { DishRoute(dishID: dish.canonicalID) }

    // MARK: - Embedded projections

    /// Just enough dish to render and route. The full ``Dish`` (category, photo, attribution)
    /// belongs to dish detail, not to a feed row.
    public struct DishSummary: Sendable, Hashable, Codable, Identifiable {
        public let id: UUID
        /// Display string. Never an identifier.
        public let name: String
        /// Merge tombstone; non-nil means reads of this dish redirect (data-model §4).
        public let mergedIntoDishID: UUID?

        public init(id: UUID, name: String, mergedIntoDishID: UUID? = nil) {
            self.id = id
            self.name = name
            self.mergedIntoDishID = mergedIntoDishID
        }

        /// One-hop merge resolution, mirroring ``Dish/canonicalDishID``.
        public var canonicalID: UUID { mergedIntoDishID ?? id }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case mergedIntoDishID = "merged_into_dish_id"
        }
    }

    /// Name and locality — the second line of a feed row.
    public struct RestaurantSummary: Sendable, Hashable, Codable, Identifiable {
        public let id: UUID
        public let name: String
        /// NOT NULL server-side; `""` is the "no locality" sentinel for manual rows.
        public let city: String

        public init(id: UUID, name: String, city: String) {
            self.id = id
            self.name = name
            self.city = city
        }

        /// `nil` rather than an empty string, so a row can simply omit the suburb.
        public var locality: String? { city.isEmpty ? nil : city }
    }

    /// The author's public identity, mirroring the display half of ``User``.
    public struct AuthorSummary: Sendable, Hashable, Codable, Identifiable {
        public let id: UUID
        public let username: String
        public let name: String
        public let avatarURLString: String?

        public init(id: UUID, username: String, name: String, avatarURLString: String? = nil) {
            self.id = id
            self.username = username
            self.name = name
            self.avatarURLString = avatarURLString
        }

        /// `@handle`, for display only.
        public var handle: String { "@\(username)" }
        /// Parsed at the edge, not at decode time — a malformed stored URL must not fail the row.
        public var avatarURL: URL? { avatarURLString.flatMap(URL.init(string:)) }

        private enum CodingKeys: String, CodingKey {
            case id
            case username
            case name
            case avatarURLString = "avatar_url"
        }
    }

    // MARK: - Decoding

    /// The review's fields sit at the *top level* of the same object as the embeds, so ``Review``
    /// decodes from this very decoder (it reads its own keys and ignores the embedded ones) rather
    /// than being restated field by field here.
    public init(from decoder: any Decoder) throws {
        self.review = try Review(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.dish = try container.decode(DishSummary.self, forKey: .dish)
        self.restaurant = try container.decode(RestaurantSummary.self, forKey: .restaurant)
        self.author = try container.decodeIfPresent(AuthorSummary.self, forKey: .author)
    }

    private enum CodingKeys: String, CodingKey {
        case dish
        case restaurant
        case author
    }
}
