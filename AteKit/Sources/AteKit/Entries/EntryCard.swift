import Foundation

/// Per entry, never per account (PRODUCT.md decision 1).
public enum EntryVisibility: String, Sendable, Codable, CaseIterable {
    case `public`
    case `private`

    public var isPublic: Bool { self == .public }
}

/// Where the sorter has got to. `pending` is a designed state, not a loading spinner: the words are
/// already saved and already readable, and the receipt is what is still coming.
public enum EntrySortStatus: String, Sendable, Codable, CaseIterable {
    case pending
    case sorted
    case failed

    /// An entry whose receipt cannot arrive without another attempt.
    public var needsRetry: Bool { self == .failed }
}

/// **The one row shape.** Journal slip, feed slip, the entry page and the share receipt are the same
/// data at four densities (`integration-design.md`), so there is one type and it is decoded once.
///
/// Decoded with ``PostgRESTDate/decoder`` rather than whatever decoder happens to be configured on
/// the client — the timestamps carry microseconds and a cursor built from a truncated one matches
/// nothing.
public struct EntryCard: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let authorID: UUID
    /// The person's words, verbatim. `""` is legal — a photos-only entry.
    public let body: String
    public let visibility: EntryVisibility
    public let restaurantID: UUID?
    /// `user` when they named or tapped it, `sorter` when the sorter matched it from the words.
    public let restaurantSource: String?
    /// "Order #0142". Server-allocated per author.
    public let orderNumber: Int
    public let sortStatus: EntrySortStatus
    public let sortedAt: Date?
    public let createdAt: Date
    public let updatedAt: Date
    public let isMine: Bool
    /// Optional defensively: a blocked author simply is not there, and one missing author should
    /// cost one row rather than the whole page.
    public let author: Author?
    /// `nil` until a place is attached.
    public let place: Place?
    public let photos: [Photo]
    public let photoCount: Int
    /// Receipt lines, already in the order they print.
    public let items: [Item]
    public let dishCount: Int
    /// Over SCORED items only; `nil` when none. Matches the receipt footer.
    public let avgScore: Double?

    public struct Author: Sendable, Hashable, Codable, Identifiable {
        public let id: UUID
        public let username: String
        public let name: String?
        public let avatarURL: String?
        public let city: String?

        public init(id: UUID, username: String, name: String? = nil,
                    avatarURL: String? = nil, city: String? = nil) {
            self.id = id
            self.username = username
            self.name = name
            self.avatarURL = avatarURL
            self.city = city
        }

        enum CodingKeys: String, CodingKey {
            case id, username, name, city
            case avatarURL = "avatar_url"
        }
    }

    public struct Place: Sendable, Hashable, Codable, Identifiable {
        public let id: UUID
        public let name: String
        public let address: String?
        public let city: String?
        public let cuisine: String?

        public init(id: UUID, name: String, address: String? = nil,
                    city: String? = nil, cuisine: String? = nil) {
            self.id = id
            self.name = name
            self.address = address
            self.city = city
            self.cuisine = cuisine
        }
    }

    public struct Photo: Sendable, Hashable, Codable {
        public let url: String
        public let position: Int

        public init(url: String, position: Int) {
            self.url = url
            self.position = position
        }
    }

    public struct Item: Sendable, Hashable, Codable, Identifiable {
        public let reviewID: UUID
        public let dishID: UUID
        public let dishName: String
        /// `nil` = the person gave no number. Design rule 7: it prints an empty star and no text,
        /// and never a zero.
        public let score: Rating?
        /// A verbatim excerpt of their own words about this dish, or nothing.
        public let note: String?
        public let position: Int
        /// The *viewer's* own save state.
        public let saved: Bool

        public var id: UUID { reviewID }

        public init(reviewID: UUID, dishID: UUID, dishName: String, score: Rating? = nil,
                    note: String? = nil, position: Int, saved: Bool = false) {
            self.reviewID = reviewID
            self.dishID = dishID
            self.dishName = dishName
            self.score = score
            self.note = note
            self.position = position
            self.saved = saved
        }

        enum CodingKeys: String, CodingKey {
            case score, note, position, saved
            case reviewID = "review_id"
            case dishID = "dish_id"
            case dishName = "dish_name"
        }
    }

    // A wide row deserves a wide initialiser; the alternative is a builder nobody wants.
    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        id: UUID,
        authorID: UUID,
        body: String,
        visibility: EntryVisibility = .public,
        restaurantID: UUID? = nil,
        restaurantSource: String? = nil,
        orderNumber: Int,
        sortStatus: EntrySortStatus = .pending,
        sortedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        isMine: Bool = true,
        author: Author? = nil,
        place: Place? = nil,
        photos: [Photo] = [],
        items: [Item] = [],
        avgScore: Double? = nil
    ) {
        self.id = id
        self.authorID = authorID
        self.body = body
        self.visibility = visibility
        self.restaurantID = restaurantID
        self.restaurantSource = restaurantSource
        self.orderNumber = orderNumber
        self.sortStatus = sortStatus
        self.sortedAt = sortedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.isMine = isMine
        self.author = author
        self.place = place
        self.photos = photos
        self.photoCount = photos.count
        self.items = items
        self.dishCount = items.count
        self.avgScore = avgScore ?? Self.average(of: items)
    }

    /// The mean of the dishes that were actually scored. Unscored dishes are not zeros and are not
    /// counted — `4.5 + 3.0 + unscored` reads `3 dishes / Avg 3.75`.
    static func average(of items: [Item]) -> Double? {
        let scores = items.compactMap(\.score?.value)
        guard scores.isEmpty == false else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    enum CodingKeys: String, CodingKey {
        case id, body, visibility, author, place, photos, items
        case authorID = "author_id"
        case restaurantID = "restaurant_id"
        case restaurantSource = "restaurant_source"
        case orderNumber = "order_number"
        case sortStatus = "sort_status"
        case sortedAt = "sorted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isMine = "is_mine"
        case photoCount = "photo_count"
        case dishCount = "dish_count"
        case avgScore = "avg_score"
    }
}

extension EntryCard: KeysetPaginated {
    public static let table = "entry_cards"
    /// The view is one JSON row per entry; there is no column list to narrow.
    public static let columns = "*"
    public var pageCursor: PageCursor { PageCursor(createdAt: createdAt, id: id) }
}

public extension EntryCard {
    /// A copy with some fields moved — wide by nature, because it mirrors the row, and every
    /// argument means "leave it alone" when it is `nil`.
    ///
    /// The row is a read model of `let` fields, and editing one in place would invite a view
    /// rewriting what the server said; this is the one way to derive another — used by the
    /// in-memory service and by the optimistic insert on the journal.
    func replacing(
        visibility: EntryVisibility? = nil,
        restaurantID: UUID? = nil,
        sortStatus: EntrySortStatus? = nil,
        sortedAt: Date? = nil,
        place: Place? = nil,
        photos: [Photo]? = nil,
        items: [Item]? = nil
    ) -> EntryCard {
        EntryCard(
            id: id,
            authorID: authorID,
            body: body,
            visibility: visibility ?? self.visibility,
            restaurantID: restaurantID ?? self.restaurantID,
            restaurantSource: restaurantSource,
            orderNumber: orderNumber,
            sortStatus: sortStatus ?? self.sortStatus,
            sortedAt: sortedAt ?? self.sortedAt,
            createdAt: createdAt,
            updatedAt: Date(),
            isMine: isMine,
            author: author,
            place: place ?? self.place,
            photos: photos ?? self.photos,
            items: items ?? self.items
        )
    }

    /// The place's name, or nothing. Never a placeholder — an entry with no place shows no place.
    var placeName: String? { place?.name }

    /// True once there is a receipt to print.
    var isSorted: Bool { sortStatus == .sorted }

    /// A sorted entry with a place but no lines is a real, designed outcome (the sorter found no
    /// dish it could stand behind), and it still prints a receipt — an empty one is not a failure.
    var hasReceipt: Bool { isSorted && place != nil }
}

#if DEBUG
public extension EntryCard {
    /// The design's own entry, sorted — the fixture every preview and the in-memory service start
    /// from, so what a screenshot shows and what `design/v1` draws are the same words.
    static let previewSorted = EntryCard(
        id: UUID(uuidString: "A7E00000-0000-4000-8000-000000000142")!,
        authorID: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
        body: "Tipo 00 with Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, "
            + "glossy, gone in four minutes. Tiramisu 3.0 a bit flat after that. Jess's prawn "
            + "spaghetti looked the business.",
        restaurantID: UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!,
        restaurantSource: "user",
        orderNumber: 142,
        sortStatus: .sorted,
        sortedAt: Date(timeIntervalSince1970: 1_789_000_100),
        createdAt: Date(timeIntervalSince1970: 1_789_000_000),
        author: Author(id: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
                       username: "eamon", city: "Melbourne"),
        place: Place(id: UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!,
                     name: "Tipo 00", address: "361 Little Bourke St", city: "Melbourne"),
        // The artboard's own three photos, bundled as prototype assets.
        photos: [
            Photo(url: "asset://ragu", position: 1),
            Photo(url: "asset://prawn", position: 2),
            Photo(url: "asset://tiramisu", position: 3)
        ],
        items: [
            // The notes read as `Entry.dc.html` prints them — the sorter lifts a sentence and the
            // receipt sets it as one.
            Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000001")!,
                 dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000001")!,
                 dishName: "Tagliatelle al ragù", score: Rating(rounding: 4.5),
                 note: "Unreal. Rich, glossy, gone in four minutes.", position: 1),
            Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000002")!,
                 dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000002")!,
                 dishName: "Tiramisu", score: Rating(rounding: 3),
                 note: "A bit flat after that.", position: 2),
            Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000003")!,
                 dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000003")!,
                 dishName: "Prawn spaghetti", position: 3)
        ]
    )
}
#endif
