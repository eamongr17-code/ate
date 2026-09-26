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
    /// Where the PLACE is named in `body` — a 0-based **Unicode scalar** offset and a scalar length
    /// (`integration-design.md`). `nil` when the words never named it, and then no place pill is
    /// drawn. Never used to search: see ``EntryBodyTokens``.
    public let placeOffset: Int?
    public let placeLength: Int?

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
        /// Unreliable — rows resolved before 0031 hold a mangled street-and-postcode here. Never
        /// printed as the place's label; read ``locality``.
        public let city: String?
        public let cuisine: String?
        /// The suburb, as `place_locality(address, city)` derives it — the ONLY safe label for a
        /// place (`integration-design.md`). Optional on the wire: a view that does not carry it yet
        /// decodes as `nil`, and the slip then prints no suburb rather than falling back to `city`.
        public let locality: String?

        public init(id: UUID, name: String, address: String? = nil,
                    city: String? = nil, cuisine: String? = nil, locality: String? = nil) {
            self.id = id
            self.name = name
            self.address = address
            self.city = city
            self.cuisine = cuisine
            self.locality = locality
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
        /// Where the SCORE is in `body`: a 0-based **Unicode scalar** offset and a scalar length.
        ///
        /// This is `score_evidence`, so it *holds* the number but can be longer than it — "4.5 stars",
        /// "4 out of 5" (migration 0024). `nil` when the server cannot point at it.
        public let evidenceOffset: Int?
        public let evidenceLength: Int?
        /// Where the DISH is named in `body`, same units. The body's own spelling, which may differ in
        /// case from ``dishName`` (that is the menu's).
        public let mentionOffset: Int?
        public let mentionLength: Int?
        /// The author fixed this line themselves; no re-sort, forced or not, overwrites it.
        public let corrected: Bool
        /// The dish's dietary tags, as the sorter read them out of the words (`tags: [String]`,
        /// lowercase codes). Optional on the wire: a row served before the column existed has none.
        public let tags: [DietTag]

        public var id: UUID { reviewID }

        // swiftlint:disable:next function_default_parameter_at_end
        public init(reviewID: UUID, dishID: UUID, dishName: String, score: Rating? = nil,
                    note: String? = nil, position: Int, saved: Bool = false,
                    evidenceOffset: Int? = nil, evidenceLength: Int? = nil,
                    mentionOffset: Int? = nil, mentionLength: Int? = nil,
                    corrected: Bool = false, tags: [DietTag] = []) {
            self.reviewID = reviewID
            self.dishID = dishID
            self.dishName = dishName
            self.score = score
            self.note = note
            self.position = position
            self.saved = saved
            self.evidenceOffset = evidenceOffset
            self.evidenceLength = evidenceLength
            self.mentionOffset = mentionOffset
            self.mentionLength = mentionLength
            self.corrected = corrected
            self.tags = tags
        }

        /// Hand-written for one reason: `corrected` is a plain `Bool` in the app and a column that
        /// only exists from 0025 on the wire. Decoding it with `decodeIfPresent` means a row served
        /// by an older view is still a row — it simply has no corrections.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.reviewID = try container.decode(UUID.self, forKey: .reviewID)
            self.dishID = try container.decode(UUID.self, forKey: .dishID)
            self.dishName = try container.decode(String.self, forKey: .dishName)
            self.score = try container.decodeIfPresent(Rating.self, forKey: .score)
            self.note = try container.decodeIfPresent(String.self, forKey: .note)
            self.position = try container.decode(Int.self, forKey: .position)
            self.saved = try container.decodeIfPresent(Bool.self, forKey: .saved) ?? false
            self.evidenceOffset = try container.decodeIfPresent(Int.self, forKey: .evidenceOffset)
            self.evidenceLength = try container.decodeIfPresent(Int.self, forKey: .evidenceLength)
            self.mentionOffset = try container.decodeIfPresent(Int.self, forKey: .mentionOffset)
            self.mentionLength = try container.decodeIfPresent(Int.self, forKey: .mentionLength)
            self.corrected = try container.decodeIfPresent(Bool.self, forKey: .corrected) ?? false
            self.tags = DietTag.decoding(try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
        }

        enum CodingKeys: String, CodingKey {
            case score, note, position, saved, corrected, tags
            case reviewID = "review_id"
            case dishID = "dish_id"
            case dishName = "dish_name"
            case evidenceOffset = "evidence_offset"
            case evidenceLength = "evidence_length"
            case mentionOffset = "mention_offset"
            case mentionLength = "mention_length"
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
        avgScore: Double? = nil,
        placeOffset: Int? = nil,
        placeLength: Int? = nil
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
        self.placeOffset = placeOffset
        self.placeLength = placeLength
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
        case placeOffset = "place_offset"
        case placeLength = "place_length"
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
            items: items ?? self.items,
            // A PLACE CORRECTION CLEARS THE PLACE TOKEN, exactly as `correct_entry_place` does in SQL
            // (0024): the words named some other venue, so there is nothing in them to point at any
            // more, and an offset kept here would put a pill for this place on the name of that one.
            placeOffset: place == nil ? placeOffset : nil,
            placeLength: place == nil ? placeLength : nil
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
    /// from, so what a screenshot shows and what `design/v1` draws are the same words. Written the
    /// way the composer writes now: the place is on the entry, not in the words (ComposerPlaceB).
    static let previewSorted = previewTipo(tagged: false)

    /// …and the same visit with its dietary tags (`DietTagsB`): "Tiramisu v", "prawn spaghetti gf".
    static let previewSortedTagged = previewTipo(tagged: true)

    private static func previewTipo(tagged: Bool) -> EntryCard {
        let body = tagged
            ? "With Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, glossy, gone in "
                + "four minutes. Tiramisu v 3.0 a bit flat after that. Jess's prawn spaghetti gf looked the "
                + "business."
            : "With Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, glossy, gone in "
                + "four minutes. Tiramisu 3.0 a bit flat after that. Jess's prawn spaghetti looked the "
                + "business."
        // Offsets in Unicode scalars, found rather than hand-counted — the unit the server serves.
        func offset(of needle: String) -> Int? {
            body.range(of: needle).map { body.unicodeScalars.distance(from: body.startIndex, to: $0.lowerBound) }
        }
        return EntryCard(
            id: UUID(uuidString: "A7E00000-0000-4000-8000-000000000142")!,
            authorID: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
            body: body,
            restaurantID: UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!,
            restaurantSource: "user",
            orderNumber: 142,
            sortStatus: .sorted,
            // Sat 19 Sep 2026, 8:14 pm in Melbourne — the artboard's day.
            sortedAt: Date(timeIntervalSince1970: 1_789_812_940),
            createdAt: Date(timeIntervalSince1970: 1_789_812_840),
            author: Author(id: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
                           username: "eamon", city: "Melbourne"),
            place: Place(id: UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!,
                         name: "Tipo 00", address: "361 Little Bourke St", city: "Melbourne",
                         locality: "CBD"),
            // The artboard's own three photos, bundled as prototype assets.
            photos: [
                Photo(url: "asset://ragu", position: 1),
                Photo(url: "asset://prawn", position: 2),
                Photo(url: "asset://tiramisu", position: 3)
            ],
            items: [
                // The offsets are the real ones for this body, so a preview, a screenshot and a UI
                // drive all render through the offset path the server feeds (`-ate-preview-data`'s
                // locally sorted entries carry none, and exercise the fallback — both halves of
                // ``EntryBodyTokens`` are reachable on a simulator).
                Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000001")!,
                     dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000001")!,
                     dishName: "Tagliatelle al ragù", score: Rating(rounding: 4.5),
                     note: "Unreal. Rich, glossy, gone in four minutes.", position: 1,
                     evidenceOffset: offset(of: "4.5"), evidenceLength: 3,
                     mentionOffset: offset(of: "tagliatelle al ragù"), mentionLength: 19),
                Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000002")!,
                     dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000002")!,
                     dishName: "Tiramisu", score: Rating(rounding: 3),
                     note: "A bit flat after that.", position: 2,
                     evidenceOffset: offset(of: "3.0"), evidenceLength: 3,
                     mentionOffset: offset(of: "Tiramisu"), mentionLength: 8,
                     tags: tagged ? [.v] : []),
                Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000003")!,
                     dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000003")!,
                     dishName: "Prawn spaghetti", position: 3,
                     mentionOffset: offset(of: "prawn spaghetti"), mentionLength: 15,
                     tags: tagged ? [.gf] : [])
            ]
        )
    }

    /// `Main.dc.html`'s second slip: one dish, one photo, Thu 17 Sep.
    static let previewCroissant: EntryCard = {
        let body = "Queued twenty minutes like everyone else and the almond croissant 5.0 is the best "
            + "thing I have eaten this year."
        // Offsets in Unicode scalars, found rather than hand-counted.
        func offset(of needle: String) -> Int? {
            body.range(of: needle).map { body.unicodeScalars.distance(from: body.startIndex, to: $0.lowerBound) }
        }
        return EntryCard(
            id: UUID(uuidString: "A7E00000-0000-4000-8000-000000000141")!,
            authorID: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
            body: body,
            restaurantID: UUID(uuidString: "B7E00000-0000-4000-8000-000000000009")!,
            restaurantSource: "user",
            orderNumber: 141,
            sortStatus: .sorted,
            // Thu 17 Sep 2026, 9:40 am in Melbourne.
            sortedAt: Date(timeIntervalSince1970: 1_789_602_100),
            createdAt: Date(timeIntervalSince1970: 1_789_602_000),
            author: Author(id: UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!,
                           username: "eamon", city: "Melbourne"),
            place: Place(id: UUID(uuidString: "B7E00000-0000-4000-8000-000000000009")!,
                         name: "Lune Croissanterie", address: "119 Rose St", city: "Melbourne",
                         locality: "CBD"),
            photos: [Photo(url: "asset://cake", position: 1)],
            items: [
                Item(reviewID: UUID(uuidString: "C7E00000-0000-4000-8000-000000000141")!,
                     dishID: UUID(uuidString: "D7E00000-0000-4000-8000-000000000141")!,
                     dishName: "Almond croissant", score: Rating(rounding: 5),
                     note: "The best thing I have eaten this year.", position: 1,
                     evidenceOffset: offset(of: "5.0"), evidenceLength: 3,
                     mentionOffset: offset(of: "almond croissant"), mentionLength: 16)
            ]
        )
    }()
}
#endif
