import Foundation

// MARK: - Rows

/// **A dish in the Feed's edition** (round 8) — one row of `top_ate`, `because_you_loved`,
/// `new_to_record` or a craving shelf (`dishes_by_tag`): the dish, where it is served, what everybody
/// has scored it, its cover, and whether the viewer has it saved.
///
/// Dish-first: the dish is the row and the place is fine print under it. `score` is `nil` for a dish
/// nobody has put a number on and is never coalesced to zero (design rule 7). `coverURLString` is a
/// photo when there is one; without it the row draws the dish's letter tile — no layout depends on a
/// photo.
public struct FeedDish: Sendable, Hashable, Identifiable {
    public let dishID: UUID
    public let name: String
    /// Absent on `new_to_record`, which does not carry it; the row routes on ``dishID``.
    public let restaurantID: UUID?
    /// A display string.
    public let restaurantName: String
    public let suburb: String?
    public let score: Double?
    public let reviewCount: Int
    public let coverURLString: String?
    /// The viewer's own bookmark. Always `false` signed out.
    public var isSaved: Bool

    public var id: UUID { dishID }

    public init(
        dishID: UUID,
        name: String,
        restaurantID: UUID? = nil,
        restaurantName: String,
        suburb: String? = nil,
        score: Double? = nil,
        reviewCount: Int = 0,
        coverURLString: String? = nil,
        isSaved: Bool = false
    ) {
        self.dishID = dishID
        self.name = name
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.suburb = suburb
        self.score = score
        self.reviewCount = reviewCount
        self.coverURLString = coverURLString
        self.isSaved = isSaved
    }
}

extension FeedDish: Decodable {
    enum CodingKeys: String, CodingKey {
        case name, suburb, score, saved
        case dishID = "dish_id"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case reviewCount = "review_count"
        case coverURLString = "cover_url"
    }

    /// Tolerant where the contract lets a column be absent: `new_to_record` has no `restaurant_id` or
    /// `review_count`, and a row with no `saved` is simply not saved.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dishID = try container.decode(UUID.self, forKey: .dishID)
        name = try container.decode(String.self, forKey: .name)
        restaurantID = try container.decodeIfPresent(UUID.self, forKey: .restaurantID)
        restaurantName = try container.decodeIfPresent(String.self, forKey: .restaurantName) ?? ""
        suburb = try container.decodeIfPresent(String.self, forKey: .suburb)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        score = try container.decodeIfPresent(Double.self, forKey: .score)
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        coverURLString = try container.decodeIfPresent(String.self, forKey: .coverURLString)
        isSaved = try container.decodeIfPresent(Bool.self, forKey: .saved) ?? false
    }
}

/// **One line of The Top Ate** — `top_ate`: its rank (1…8) and the dish.
public struct TopAteLine: Sendable, Hashable, Identifiable, Decodable {
    public let rank: Int
    public var dish: FeedDish

    public var id: UUID { dish.dishID }

    public init(rank: Int, dish: FeedDish) {
        self.rank = rank
        self.dish = dish
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rank = try container.decode(Int.self, forKey: .rank)
        dish = try FeedDish(from: decoder)
    }

    enum CodingKeys: String, CodingKey { case rank }

    /// `01`…`08`, as the receipt numbers its lines.
    public var number: String { String(format: "%02d", max(0, rank)) }
}

/// **Because you loved…** — `because_you_loved`: the dish it is about (the viewer's most recent 5.0
/// or 6) and the dishes like it.
public struct LovedShelf: Sendable, Hashable {
    public let anchorDishID: UUID
    public let anchorName: String
    public var dishes: [FeedDish]

    public init(anchorDishID: UUID, anchorName: String, dishes: [FeedDish]) {
        self.anchorDishID = anchorDishID
        self.anchorName = anchorName
        self.dishes = dishes
    }

    /// "Because you loved tagliatelle" — the dish's name, read mid-sentence: its first letter lowered,
    /// unless the name opens on an acronym ("BBQ pork") or a single capital, which stay as written.
    public var title: String { "Because you loved \(Self.midSentence(anchorName))" }

    static func midSentence(_ name: String) -> String {
        let characters = Array(name)
        guard characters.count > 1, characters[0].isUppercase, characters[1].isLowercase else { return name }
        return characters[0].lowercased() + String(characters.dropFirst())
    }
}

/// **One row of New to the record** — `new_to_record`: a dish that got a new 6, a new 5.0, or its
/// first review since the viewer last opened the Feed.
public struct NewDish: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case six
        case five
        case new
    }

    public let kind: Kind
    public var dish: FeedDish
    public let at: Date

    public var id: UUID { dish.dishID }

    public init(kind: Kind, dish: FeedDish, at: Date) {
        self.kind = kind
        self.dish = dish
        self.at = at
    }

    /// The badge: `★6`, `★5`, `New`.
    public var badge: String {
        switch kind {
        case .six: "★6"
        case .five: "★5"
        case .new: "New"
        }
    }
}

extension NewDish: Decodable {
    enum CodingKeys: String, CodingKey { case kind, at }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "kind \(raw)")
        }
        self.kind = kind
        at = try container.decode(Date.self, forKey: .at)
        dish = try FeedDish(from: decoder)
    }
}

/// **A craving shelf** — one followed craving and its dishes (`dishes_by_tag` in the Feed's city).
public struct CravingShelf: Sendable, Hashable, Identifiable {
    public let craving: Craving
    public var dishes: [FeedDish]

    public var id: String { craving.id }

    public init(craving: Craving, dishes: [FeedDish]) {
        self.craving = craving
        self.dishes = dishes
    }
}

// MARK: - Cravings

/// **A craving** — a tag the viewer follows (`user_cravings`, round 8): the round-7 tag kinds, so a
/// shelf is `dishes_by_tag` and its See all is the tag's own page.
public struct Craving: Sendable, Hashable, Identifiable, Codable {
    public let kind: DishTag.Kind
    /// Opaque — passed back to `dishes_by_tag` verbatim.
    public let slug: String
    public let label: String

    public var id: String { "\(kind.rawValue):\(slug)" }
    /// What its shelf and its chip print ("Pasta"), by the tag's own rule.
    public var title: String { DishTag.title(label, kind: kind) }

    public init(kind: DishTag.Kind, slug: String, label: String) {
        self.kind = kind
        self.slug = slug
        self.label = label
    }

    /// The tag page its shelf's See all opens, in the Feed's city.
    public func route(city: String?) -> DishTagRoute {
        DishTagRoute(kind: kind, slug: slug, label: title, city: city)
    }
}

/// **One chip in the cravings picker** — `craving_options()`: a craving and the group it sits in.
public struct CravingOption: Sendable, Hashable, Identifiable {
    /// The picker's groups, in the order it prints them. No group is labelled on screen.
    public enum Group: String, Sendable, Hashable, CaseIterable, Codable {
        case dishes
        case cuisines
        case moods
    }

    public let craving: Craving
    public let group: Group

    public var id: String { craving.id }

    public init(craving: Craving, group: Group) {
        self.craving = craving
        self.group = group
    }
}

// MARK: - The seam

/// **What the Feed's edition reads and writes** (round 8). Every read takes the Feed's city (`nil` is
/// everywhere) and works signed out where the Feed does; the personal ones answer nothing signed out.
public protocol FeedEditionReading: Sendable {
    /// `top_ate(p_city, p_limit)`.
    func topAte(city: String?, limit: Int) async throws -> [TopAteLine]
    /// `because_you_loved(p_city, p_limit)` — `nil` when there is no anchor (signed out, no 5.0 yet).
    func becauseYouLoved(city: String?, limit: Int) async throws -> LovedShelf?
    /// `new_to_record(p_city, p_since, p_limit)`.
    func newToRecord(city: String?, since: Date, limit: Int) async throws -> [NewDish]
    /// `my_cravings()`.
    func myCravings() async throws -> [Craving]
    /// `craving_options()`.
    func cravingOptions() async throws -> [CravingOption]
    /// `set_cravings(p_cravings)` — replaces the whole set (in shelf order; duplicates collapse, at
    /// most ``CravingPicker/maximum``) and answers with the set as it now stands.
    func setCravings(_ cravings: [Craving]) async throws -> [Craving]
    /// A shelf: the first page of `dishes_by_tag(p_kind, p_slug, p_limit, p_city)`.
    func cravingDishes(_ craving: Craving, city: String?, limit: Int) async throws -> [FeedDish]
}
