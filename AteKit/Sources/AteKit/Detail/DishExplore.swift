import Foundation
import Supabase

// MARK: - Rows

/// **One of a dish's tags** — `dish_tags(p_dish_id)`: what the dish is (a style the sorter pulled out
/// of the words, "pasta"), what kind of place serves it (the restaurant's cuisine), and where (its
/// suburb and city). Each is a door to every dish that shares it (``DishExploreReading``).
///
/// Made on the server when a dish is logged — never guessed on the phone.
public struct DishTag: Sendable, Hashable, Codable, Identifiable {
    /// What a tag says about the dish. The order of the cases is the order the dish page prints them.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case style
        case cuisine
        case suburb
        case city
        /// The existing dietary codes (`gf`, labelled `GF`) — last, as `dish_tags` serves them (0053).
        case diet
    }

    public let kind: Kind
    /// The tag's key — **opaque**: passed back to `dishes_by_tag` verbatim, never built or parsed on
    /// the phone (a suburb's is city-qualified, `fitzroy-melbourne`).
    public let slug: String
    /// The label as the server sends it. A style arrives lowercase ("pasta"); print ``title``.
    public let label: String

    public var id: String { "\(kind.rawValue):\(slug)" }

    /// **What the chip and the tag's page print.** `DishExplore.dc.html` sets every chip in sentence
    /// case — "Pasta", "Handmade" — and 0053 sends a style lowercase, so its first letter is raised
    /// here. Every other kind is printed exactly as sent ("Wine bar", "GF", "Fitzroy").
    public var title: String { DishTag.title(label, kind: kind) }

    static func title(_ label: String, kind: Kind) -> String {
        guard kind == .style, let first = label.first else { return label }
        return first.uppercased() + label.dropFirst()
    }

    public init(kind: Kind, slug: String, label: String) {
        self.kind = kind
        self.slug = slug
        self.label = label
    }
}

/// **The tags in the order the dish page prints them**: style, cuisine, suburb, city (then diet).
///
/// The server already orders `dish_tags` that way; this says it out loud so the one rule the canvas
/// draws is asserted by a test rather than trusted to a `select`. Stable within a kind, so the
/// server's own order survives, and one chip per tag — a duplicate id in a SwiftUI list is a crash.
public enum DishTagOrder {
    public static func explore(_ tags: [DishTag]) -> [DishTag] {
        var seen: Set<String> = []
        let unique = tags.filter { seen.insert($0.id).inserted && $0.label.isEmpty == false }
        return Kind.allCases.flatMap { kind in unique.filter { $0.kind == kind } }
    }

    private typealias Kind = DishTag.Kind
}

/// **A dish like this one** — one row of `similar_dishes`, and of `dishes_by_tag`: the dish, where it
/// is served, what everybody has scored it, and its cover.
///
/// `score` is `nil` for a dish nobody has put a number on, and is never coalesced to zero (design
/// rule 7): the card then prints no score at all.
public struct SimilarDish: Sendable, Hashable, Codable, Identifiable {
    public let dishID: UUID
    public let name: String
    public let restaurantID: UUID
    /// A display string — the card routes on ``dishID``.
    public let restaurantName: String
    public let score: Double?
    public let reviewCount: Int
    public let coverURLString: String?

    public var id: UUID { dishID }
    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }

    public init(
        dishID: UUID,
        name: String,
        restaurantID: UUID,
        restaurantName: String,
        score: Double? = nil,
        reviewCount: Int = 0,
        coverURLString: String? = nil
    ) {
        self.dishID = dishID
        self.name = name
        self.restaurantID = restaurantID
        self.restaurantName = restaurantName
        self.score = score
        self.reviewCount = reviewCount
        self.coverURLString = coverURLString
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.dishID = try container.decode(UUID.self, forKey: .dishID)
        self.name = try container.decode(String.self, forKey: .name)
        self.restaurantID = try container.decode(UUID.self, forKey: .restaurantID)
        self.restaurantName = try container.decode(String.self, forKey: .restaurantName)
        self.score = try container.decodeIfPresent(Double.self, forKey: .score)
        self.reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        self.coverURLString = try container.decodeIfPresent(String.self, forKey: .coverURLString)
    }

    enum CodingKeys: String, CodingKey {
        case name, score
        case dishID = "dish_id"
        case restaurantID = "restaurant_id"
        case restaurantName = "restaurant_name"
        case reviewCount = "review_count"
        case coverURLString = "cover_url"
    }

    /// Where this row sits in `dishes_by_tag`'s stream, for the next page's request.
    public var tagCursor: TagDishCursor {
        TagDishCursor(score: score, reviewCount: reviewCount, name: name, dishID: dishID)
    }
}

/// **`dishes_by_tag`'s keyset** (0053) — `place_dishes`' order: score (a secret 6 above a 5, the
/// unscored last), then how many reviews, then the name case-folded, then the id as the total
/// tiebreak. `score` is nullable because the cursor has to be able to sit among the unscored dishes.
public struct TagDishCursor: Sendable, Hashable, Codable {
    public let score: Double?
    public let reviewCount: Int
    public let name: String
    public let dishID: UUID

    public init(score: Double?, reviewCount: Int, name: String, dishID: UUID) {
        self.score = score
        self.reviewCount = reviewCount
        self.name = name
        self.dishID = dishID
    }

    /// **The order `dishes_by_tag` serves**, as one comparison — true when `lhs` comes first. What
    /// the fakes page by, so a test proves the store threads the cursor rather than an index.
    public static func isBefore(_ lhs: TagDishCursor, _ rhs: TagDishCursor) -> Bool {
        switch (lhs.score, rhs.score) {
        case (let left?, let right?) where left != right: return left > right
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if lhs.reviewCount != rhs.reviewCount { return lhs.reviewCount > rhs.reviewCount }
        let left = lhs.name.lowercased(), right = rhs.name.lowercased()
        if left != right { return left < right }
        return lhs.dishID.uuidString.lowercased() < rhs.dishID.uuidString.lowercased()
    }
}

/// One page of a tag's dishes.
public struct TagDishPage: Sendable, Equatable {
    public let items: [SimilarDish]
    public let nextCursor: TagDishCursor?

    public init(items: [SimilarDish], nextCursor: TagDishCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    /// "Last page" is a short read, exactly as ``Page`` infers it.
    public init(items: [SimilarDish], requestedLimit: Int) {
        self.items = items
        self.nextCursor = items.count < requestedLimit ? nil : items.last?.tagCursor
    }

    public var isLastPage: Bool { nextCursor == nil }
}

/// **Where a tag chip goes** — the tag page's route: which tag, and the name its top bar prints (the
/// chip's own ``DishTag/title``).
public struct DishTagRoute: Sendable, Hashable, Codable {
    public let kind: DishTag.Kind
    public let slug: String
    public let label: String
    /// The city the page is read in — a Feed craving shelf's See all keeps the Feed's city (round 8).
    /// `nil` is everywhere, as a dish page's chip opens it.
    public let city: String?

    public init(kind: DishTag.Kind, slug: String, label: String, city: String? = nil) {
        self.kind = kind
        self.slug = slug
        self.label = label
        self.city = city
    }

    public init(_ tag: DishTag) {
        self.init(kind: tag.kind, slug: tag.slug, label: tag.title)
    }
}

// MARK: - The seam

/// **What the dish page reads below its reviews**, and the tag page it opens: a dish's tags, the dishes
/// most like it, and one tag's dishes. Signed-in reads (round 7), additive to ``DishPageReading``.
public protocol DishExploreReading: Sendable {
    /// `dish_tags(p_dish_id)`.
    func dishTags(dishID: UUID) async throws -> [DishTag]
    /// `similar_dishes(p_dish_id, p_limit)` — ranked by the server, the dish itself excluded, and
    /// only dishes sharing a style or the cuisine (0053).
    func similarDishes(dishID: UUID, limit: Int) async throws -> [SimilarDish]
    /// `dishes_by_tag(p_kind, p_slug, p_limit, cursor…, p_city)` — one keyset page, best first, in a
    /// city when one is given (round 8; `nil` is everywhere).
    func dishesByTag(
        kind: DishTag.Kind,
        slug: String,
        city: String?,
        after cursor: TagDishCursor?,
        pageSize: Int
    ) async throws -> TagDishPage
}

extension DishExploreReading {
    /// Everywhere — a dish page's chip.
    public func dishesByTag(
        kind: DishTag.Kind,
        slug: String,
        after cursor: TagDishCursor?,
        pageSize: Int
    ) async throws -> TagDishPage {
        try await dishesByTag(kind: kind, slug: slug, city: nil, after: cursor, pageSize: pageSize)
    }
}

/// The live reads: `dish_tags`, `similar_dishes`, `dishes_by_tag`.
public struct DishExploreClient: DishExploreReading {
    /// `similar_dishes`' own default (it clamps at 50).
    public static let similarLimit = 10
    /// `dishes_by_tag` clamps `p_limit` at 100; asking for more comes back short and makes
    /// `isLastPage` lie.
    public static let maximumPageSize = 100

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func dishTags(dishID: UUID) async throws -> [DishTag] {
        let data = try await api.supabase
            .rpc("dish_tags", params: ["p_dish_id": AnyJSON.string(dishID.uuidString.lowercased())])
            .execute()
            .data
        return try Self.decodeTags(data)
    }

    public func similarDishes(dishID: UUID, limit: Int) async throws -> [SimilarDish] {
        let data = try await api.supabase
            .rpc("similar_dishes", params: [
                "p_dish_id": AnyJSON.string(dishID.uuidString.lowercased()),
                "p_limit": AnyJSON.integer(max(1, limit))
            ])
            .execute()
            .data
        return try PostgRESTDate.decoder.decode([SimilarDish].self, from: data)
    }

    public func dishesByTag(
        kind: DishTag.Kind,
        slug: String,
        city: String?,
        after cursor: TagDishCursor?,
        pageSize: Int
    ) async throws -> TagDishPage {
        let limit = min(Self.maximumPageSize, max(1, pageSize))
        var parameters = Self.tagParameters(kind: kind, slug: slug, city: city, limit: limit)
        // All four, or none: the first page is the plain call, and `p_cursor_score` is legitimately
        // null among the unscored dishes — the cursor's presence decides, never the value's.
        if let cursor {
            parameters["p_cursor_score"] = cursor.score.map { .double($0) } ?? .null
            parameters["p_cursor_review_count"] = .integer(cursor.reviewCount)
            parameters["p_cursor_name"] = .string(cursor.name)
            parameters["p_cursor_dish_id"] = .string(cursor.dishID.uuidString.lowercased())
        }
        let data = try await api.supabase
            .rpc("dishes_by_tag", params: parameters)
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([SimilarDish].self, from: data)
        return TagDishPage(items: rows, requestedLimit: limit)
    }

    /// `dishes_by_tag`'s first-page parameters. `p_city` only when there is a city: everywhere is the
    /// plain call, which every version of the function answers.
    static func tagParameters(kind: DishTag.Kind, slug: String, city: String?, limit: Int) -> [String: AnyJSON] {
        var parameters: [String: AnyJSON] = [
            "p_kind": .string(kind.rawValue),
            "p_slug": .string(slug),
            "p_limit": .integer(limit)
        ]
        if let city { parameters["p_city"] = .string(city) }
        return parameters
    }

    /// A kind this build does not know is dropped, row by row, rather than taking every tag down.
    static func decodeTags(_ data: Data) throws -> [DishTag] {
        try JSONDecoder().decode([WireTag].self, from: data).compactMap { row in
            DishTag.Kind(rawValue: row.kind).map { DishTag(kind: $0, slug: row.slug, label: row.label) }
        }
    }

    private struct WireTag: Decodable {
        let kind: String
        let slug: String
        let label: String
    }
}
