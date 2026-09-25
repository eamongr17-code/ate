import Foundation

/// **One place in the Search tab's results** — a `Nearby` row or a typed hit, drawn identically:
/// pin · the place · its suburb · score token.
///
/// The second value is the **suburb**, not the cuisine the 2026-09-22 artboard printed there: the
/// place line was redrawn on the card's own foot line (pin, place 600, suburb muted) and the Search
/// row follows it, so a place is written the same way on every screen it appears.
///
/// Every place here is one we hold (`search_places`, `nearby_places`): a row opens its page by UUID,
/// for free. Finding somewhere we have never heard of is the composer's job (`search_all` +
/// `places-search`), not the tab's.
public struct PlaceResult: Identifiable, Sendable, Hashable {
    public let restaurantID: UUID
    public let name: String
    /// `locality` off the wire — derived on read by the server, never the raw `city` (which can be a
    /// street line). `nil` draws nothing (design rule 1).
    public let locality: String?
    /// `avg_rating` — an average, printed as sent, one decimal. `nil` is nobody's score yet: an
    /// empty star, never a zero (design rule 7).
    public let score: Double?

    public var id: UUID { restaurantID }

    public init(restaurantID: UUID, name: String, locality: String?, score: Double?) {
        self.restaurantID = restaurantID
        self.name = name
        self.locality = locality
        self.score = score
    }

    init(_ row: SearchPlaceRow) {
        self.init(restaurantID: row.restaurantID, name: row.name, locality: row.locality, score: row.avgRating)
    }

    init(_ row: NearbyPlaceRow) {
        self.init(restaurantID: row.restaurantID, name: row.name, locality: row.locality, score: row.avgRating)
    }
}

/// **One dish in the results** (`SearchResults.dc.html`): cover · name · the place it is served ·
/// the score token. The dish is the item everywhere, and this is that row.
public struct DishResult: Identifiable, Sendable, Hashable {
    public let dishID: UUID
    public let name: String
    public let restaurantID: UUID
    public let restaurantName: String
    public let restaurantLocality: String?
    /// The community aggregate. `nil` is unrated, and prints as an empty star.
    public let score: Double?
    public let coverURLString: String?
    public let peopleCount: Int

    public var id: UUID { dishID }

    public init(
        dishID: UUID,
        name: String,
        restaurantID: UUID,
        restaurantName: String,
        restaurantLocality: String? = nil,
        score: Double?,
        coverURLString: String? = nil,
        peopleCount: Int = 0
    ) {
        self.dishID = dishID
        self.name = name
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.restaurantLocality = restaurantLocality
        self.score = score
        self.coverURLString = coverURLString
        self.peopleCount = peopleCount
    }

    init(_ row: SearchDishRow) {
        self.init(
            dishID: row.dishID,
            name: row.dishName,
            restaurantID: row.restaurantID,
            restaurantName: row.restaurantName,
            restaurantLocality: row.restaurantLocality,
            score: row.score,
            coverURLString: row.coverURL,
            peopleCount: row.peopleCount
        )
    }

    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }
}

/// **One person in the results.** A handle, a name, an avatar, and nothing else: there is no score
/// on a person (a score is only ever the user's own, about a dish) and no follower count in V1.
public struct PersonResult: Identifiable, Sendable, Hashable {
    public let userID: UUID
    public let handle: String
    public let name: String?
    public let avatarURLString: String?
    /// You can find yourself — searching your own handle and not finding it reads as a bug.
    public let isMe: Bool

    public var id: UUID { userID }

    public init(userID: UUID, handle: String, name: String?, avatarURLString: String? = nil, isMe: Bool = false) {
        self.userID = userID
        self.handle = handle
        self.name = name
        self.avatarURLString = avatarURLString
        self.isMe = isMe
    }

    init(_ row: SearchPersonRow) {
        self.init(
            userID: row.userID,
            handle: row.username,
            name: row.name.isEmpty ? nil : row.name,
            avatarURLString: row.avatarURL,
            isMe: row.isMe
        )
    }
}

extension SavedDish {
    /// A `search_saved` row is `my_saved_dishes`' own columns plus `restaurant_locality`, so it is the
    /// shelf's own value. The printable suburb rides in `restaurantCity`'s slot: the view's `city` can
    /// be a street line, and a place's label is its locality, never its city.
    init(_ row: SearchSavedRow) {
        self.init(
            dishID: row.dishID,
            dishName: row.dishName,
            restaurantID: row.restaurantID,
            restaurantName: row.restaurantName,
            restaurantCity: row.restaurantLocality,
            dishScore: row.dishScore,
            dishCoverURL: row.coverURL ?? row.dishCoverURL,
            sourceEntryID: row.sourceEntryID,
            sourceUserID: row.sourceUserID,
            sourceUsername: row.sourceUsername,
            savedAt: row.savedAt
        )
    }
}

/// What the current scope is showing. One value, so a view switches on the rows it has rather than
/// on the scope it asked for — the two can disagree for exactly one frame, and that frame is where a
/// dish row drawn as a person comes from.
public enum SearchRows: Sendable, Hashable {
    case places([PlaceResult])
    case dishes([DishResult])
    case people([PersonResult])
    case saved([SavedDish])

    public static func empty(for scope: SearchScope) -> SearchRows {
        switch scope {
        case .places: .places([])
        case .dishes: .dishes([])
        case .people: .people([])
        case .saved: .saved([])
        }
    }

    public var count: Int {
        switch self {
        case .places(let rows): rows.count
        case .dishes(let rows): rows.count
        case .people(let rows): rows.count
        case .saved(let rows): rows.count
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .places(let rows): rows.isEmpty
        case .dishes(let rows): rows.isEmpty
        case .people(let rows): rows.isEmpty
        case .saved(let rows): rows.isEmpty
        }
    }

    public var scope: SearchScope {
        switch self {
        case .places: .places
        case .dishes: .dishes
        case .people: .people
        case .saved: .saved
        }
    }
}

/// **Where the next page of a search starts** — the LAST row's key, every field of it
/// (integration-design.md: "pass every cursor field from the last row"). One case per ordering,
/// because the five RPCs order five ways and a cursor from one is meaningless to another.
public enum SearchCursor: Sendable, Hashable {
    /// `search_places`: `(match_tier, review_count desc, name, restaurant_id)`.
    case place(matchTier: Int, reviewCount: Int, name: String, id: UUID)
    /// `nearby_places`: `(distance_m, restaurant_id)`.
    case nearby(distanceMeters: Double, id: UUID)
    /// `search_dishes`: `(match_tier, review_count desc, dish_name, dish_id)`.
    case dish(matchTier: Int, reviewCount: Int, name: String, id: UUID)
    /// `search_people`: `(match_tier, username, user_id)`.
    case person(matchTier: Int, username: String, id: UUID)
    /// `search_saved`: `(saved_at desc, dish_id desc)` — the shelf's own cursor.
    case saved(savedAt: Date, dishID: UUID)

    init(_ row: SearchPlaceRow) {
        self = .place(matchTier: row.matchTier, reviewCount: row.reviewCount, name: row.name, id: row.restaurantID)
    }

    init(_ row: NearbyPlaceRow) {
        self = .nearby(distanceMeters: row.distanceM, id: row.restaurantID)
    }

    init(_ row: SearchDishRow) {
        self = .dish(matchTier: row.matchTier, reviewCount: row.reviewCount, name: row.dishName, id: row.dishID)
    }

    init(_ row: SearchPersonRow) {
        self = .person(matchTier: row.matchTier, username: row.username, id: row.userID)
    }

    init(_ row: SearchSavedRow) {
        self = .saved(savedAt: row.savedAt, dishID: row.dishID)
    }
}

/// One page of results, and where the next one starts. `nil` means there is no next one.
public struct SearchPage<Row: Sendable & Hashable>: Sendable, Hashable {
    public let rows: [Row]
    public let next: SearchCursor?

    public init(rows: [Row], next: SearchCursor?) {
        self.rows = rows
        self.next = next
    }

    public var isLastPage: Bool { next == nil }

    /// A page off the wire. A short read is the end — the price is one extra empty request when the
    /// total is an exact multiple of the page size, which is cheaper than a `count=exact` every time.
    static func of<Wire>(
        _ wire: [Wire],
        limit: Int,
        row: (Wire) -> Row,
        cursor: (Wire) -> SearchCursor
    ) -> SearchPage<Row> {
        let next = wire.count < limit ? nil : wire.last.map(cursor)
        return SearchPage(rows: wire.map(row), next: next)
    }
}
