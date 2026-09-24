import Foundation
import Supabase

// MARK: - Rows

/// **The place page's header**, as `place_summary(p_restaurant_id)` hands it over: the row, its
/// aggregates, and the viewer's own history here in the same round trip.
///
/// `avgRating` is read, never computed. It is the mean of per-dish averages (data-model §1.2), so
/// averaging ``MenuDish`` scores on the client gives a different, wrong number — that was the
/// legacy client's bug and there is deliberately nothing here that could reintroduce it. `nil` means
/// nothing at this place is rated yet, and it is drawn as nothing rather than as a zero.
public struct PlaceSummary: Sendable, Hashable, Codable, Identifiable {
    public let restaurantID: UUID
    /// A display string. Everything keys on ``restaurantID`` (ARCHITECTURE.md — UUID keys
    /// everywhere); two suburbs apart there are three "Hakata Gensuke".
    public let name: String
    public let address: String?
    /// **What the header's suburb chip prints.** Never ``city``: on a live Google row `city` is a
    /// mangled slice of the formatted address, and a chip is a fact or it is nothing (design rule
    /// 8). `nil` draws no chip at all (0029).
    public let locality: String?
    /// The raw `city` column. Decoded because it is in the shape; **not drawn anywhere** — see
    /// ``locality``.
    public let city: String?
    public let cuisine: String?
    public let coverURLString: String?
    /// The mean of per-dish averages to 1dp — `nil` when nothing here is rated.
    public let avgRating: Double?
    /// Receipt LINES across the place. Not visits — see ``entryCount`` (0029).
    public let reviewCount: Int
    /// Visits: how many entries have been written here, by anybody.
    public let entryCount: Int
    /// How many different people have written about this place — what the header's people chip says.
    public let peopleCount: Int
    public let dishCount: Int
    /// The viewer's own visits here. Zero means the "Your N visits" band is simply absent.
    public let myVisits: Int
    public let myLastVisit: Date?

    public var id: UUID { restaurantID }
    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }
    public var isRated: Bool { avgRating != nil }
    public var hasVisits: Bool { myVisits > 0 }

    // A wide row deserves a wide initialiser; the alternative is a builder nobody wants.
    // swiftlint:disable:next function_default_parameter_at_end
    public init(
        restaurantID: UUID,
        name: String,
        address: String? = nil,
        locality: String? = nil,
        city: String? = nil,
        cuisine: String? = nil,
        coverURLString: String? = nil,
        avgRating: Double? = nil,
        reviewCount: Int = 0,
        entryCount: Int = 0,
        peopleCount: Int = 0,
        dishCount: Int = 0,
        myVisits: Int = 0,
        myLastVisit: Date? = nil
    ) {
        self.restaurantID = restaurantID
        self.name = name
        self.address = address
        self.locality = locality
        self.city = city
        self.cuisine = cuisine
        self.coverURLString = coverURLString
        self.avgRating = avgRating
        self.reviewCount = reviewCount
        self.entryCount = entryCount
        self.peopleCount = peopleCount
        self.dishCount = dishCount
        self.myVisits = myVisits
        self.myLastVisit = myLastVisit
    }

    /// Hand-written for one reason: `locality` and `entry_count` only exist from 0029 on the wire,
    /// and a row served by a project that has not taken the migration yet is still a row — it just
    /// has no suburb and no visit count. Every column 0029 appends is read with `decodeIfPresent`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.restaurantID = try container.decode(UUID.self, forKey: .restaurantID)
        self.name = try container.decode(String.self, forKey: .name)
        self.address = try container.decodeIfPresent(String.self, forKey: .address)
        self.locality = try container.decodeIfPresent(String.self, forKey: .locality)
        self.city = try container.decodeIfPresent(String.self, forKey: .city)
        self.cuisine = try container.decodeIfPresent(String.self, forKey: .cuisine)
        self.coverURLString = try container.decodeIfPresent(String.self, forKey: .coverURLString)
        self.avgRating = try container.decodeIfPresent(Double.self, forKey: .avgRating)
        self.reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        self.entryCount = try container.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0
        self.peopleCount = try container.decodeIfPresent(Int.self, forKey: .peopleCount) ?? 0
        self.dishCount = try container.decodeIfPresent(Int.self, forKey: .dishCount) ?? 0
        self.myVisits = try container.decodeIfPresent(Int.self, forKey: .myVisits) ?? 0
        self.myLastVisit = try container.decodeIfPresent(Date.self, forKey: .myLastVisit)
    }

    enum CodingKeys: String, CodingKey {
        case name, address, locality, city, cuisine
        case restaurantID = "restaurant_id"
        case coverURLString = "cover_url"
        case avgRating = "avg_rating"
        case reviewCount = "review_count"
        case entryCount = "entry_count"
        case peopleCount = "people_count"
        case dishCount = "dish_count"
        case myVisits = "my_visits"
        case myLastVisit = "my_last_visit"
    }
}

/// One line of **"What to order"** — `place_dishes(p_restaurant_id, p_limit)`.
///
/// `score` is `nil` for a dish nobody has put a number on. That is a product state, not missing
/// data: it prints an empty star and sinks to the bottom of the list (design rule 7).
///
/// Named `MenuDish` rather than `PlaceDish` because ``PlaceDish`` is already taken by the dish
/// sheet's lossy view of the **same RPC** (id, name, people count — no score, no cover). Two
/// decoders for one function is one too many; ``PlaceDirectory/dishes(atPlace:limit:)`` should be
/// folded onto this row when something next touches the dish sheet.
public struct MenuDish: Sendable, Hashable, Codable, Identifiable, DishRankable {
    public let dishID: UUID
    public let name: String
    public let score: Double?
    /// How many different people have scored it — the number the artboard prints under the name.
    public let peopleCount: Int
    /// How many reviews it has — **the column the list is ordered by** (0030), and the first part
    /// of its cursor. One 5.0 from one person does not outrank a 4.4 from twelve.
    public let reviewCount: Int
    public let coverURLString: String?

    public var id: UUID { dishID }
    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }
    public var isRated: Bool { score != nil }

    /// Where this row sits in the stream, for the next page's request.
    public var pageCursor: MenuDishCursor {
        MenuDishCursor(reviewCount: reviewCount, score: score, name: name, dishID: dishID)
    }

    public init(
        dishID: UUID,
        name: String,
        score: Double? = nil,
        peopleCount: Int = 0,
        reviewCount: Int = 0,
        coverURLString: String? = nil
    ) {
        self.dishID = dishID
        self.name = name
        self.score = score
        self.peopleCount = peopleCount
        self.reviewCount = reviewCount
        self.coverURLString = coverURLString
    }

    enum CodingKeys: String, CodingKey {
        case score
        case dishID = "dish_id"
        case name = "dish_name"
        case peopleCount = "people_count"
        case reviewCount = "review_count"
        case coverURLString = "cover_url"
    }
}

/// **A four-part keyset**, because `place_dishes` orders `review_count desc, score desc nulls last,
/// lower(dish_name), dish_id` — four columns, so four values from the last row (0030).
///
/// **That order is ``DishRanking``'s**, settled where it belongs: in the `ORDER BY`. The client
/// therefore does not sort the menu at all, and must not start — a list you page cannot be
/// reordered on arrival without the second page interleaving into the first. `DishRanking` remains
/// the written statement of the rule, and the contract test asserts the server still obeys it.
public struct MenuDishCursor: Sendable, Hashable, Codable {
    public let reviewCount: Int
    /// Nullable: unscored dishes sort last, and the cursor has to be able to sit among them.
    public let score: Double?
    public let name: String
    public let dishID: UUID

    public init(reviewCount: Int, score: Double?, name: String, dishID: UUID) {
        self.reviewCount = reviewCount
        self.score = score
        self.name = name
        self.dishID = dishID
    }
}

/// One page of a place's menu. Its own type for the same reason ``DishReviewPage`` has one: the
/// cursor is not `(created_at, id)`.
public struct MenuDishPage: Sendable, Equatable {
    public let items: [MenuDish]
    public let nextCursor: MenuDishCursor?

    public init(items: [MenuDish], nextCursor: MenuDishCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    /// "Last page" is a short read, exactly as ``Page`` infers it.
    public init(items: [MenuDish], requestedLimit: Int) {
        self.items = items
        self.nextCursor = items.count < requestedLimit ? nil : items.last?.pageCursor
    }

    public var isEmpty: Bool { items.isEmpty }
    public var isLastPage: Bool { nextCursor == nil }
}

/// Whose entries a place's list is showing. The server's `p_scope`, as a closed set rather than a
/// string literal at the call site.
public enum PlaceEntryScope: String, Sendable, CaseIterable, Codable {
    case all
    /// The viewer's own — "Your N visits", private entries included (RLS shows you yours).
    case mine
    case others
}

// MARK: - The seam

/// Everything the place page reads, behind one protocol so ``PlacePageStore`` is testable without a
/// network and previews can run on fixtures.
public protocol PlacePageReading: Sendable {
    func placeSummary(restaurantID: UUID) async throws -> PlaceSummary
    /// One page of the ranked menu, cut with the four-part keyset (0029).
    func placeDishes(
        restaurantID: UUID,
        after cursor: MenuDishCursor?,
        pageSize: Int
    ) async throws -> MenuDishPage
    /// One keyset page of the entries written at this place.
    func entriesAtPlace(
        restaurantID: UUID,
        scope: PlaceEntryScope,
        after cursor: PageCursor?,
        pageSize: Int
    ) async throws -> Page<EntryCard>
}

/// The live place reads: `place_summary`, `place_dishes`, `get_entries_at_place`.
///
/// Thin by design: it fetches, and every ordering decision is the server's — which since 0030 is
/// ``DishRanking``'s rule, so there is nothing left to disagree about. See ``MenuDishCursor``.
public struct PlacePageClient: PlacePageReading {
    /// `place_dishes` clamps `p_limit` at 200. A real menu fits inside one page of that; the cursor
    /// exists so a pathological one still walks rather than silently stopping at 200.
    public static let maximumDishes = 200
    /// `get_entries_at_place` clamps `p_page_size` at 50; asking for more comes back short and makes
    /// `isLastPage` lie.
    public static let maximumPageSize = 50

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func placeSummary(restaurantID: UUID) async throws -> PlaceSummary {
        let data = try await api.supabase
            .rpc("place_summary", params: [
                "p_restaurant_id": AnyJSON.string(restaurantID.uuidString.lowercased())
            ])
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([PlaceSummary].self, from: data)
        // A place that is not there — deleted, or never was — is a missing row, not a network
        // failure, and the screen says so rather than crashing on a nil join.
        guard let row = rows.first else {
            throw AteAPIError.notFound(table: "restaurants", id: restaurantID)
        }
        return row
    }

    public func placeDishes(
        restaurantID: UUID,
        after cursor: MenuDishCursor?,
        pageSize: Int = PlacePageClient.maximumDishes
    ) async throws -> MenuDishPage {
        let limit = min(Self.maximumDishes, max(1, pageSize))
        var parameters: [String: AnyJSON] = [
            "p_restaurant_id": .string(restaurantID.uuidString.lowercased()),
            "p_limit": .integer(limit)
        ]
        // The four cursor parameters are only sent when there IS a cursor, so the first page is the
        // same call it has always been and a project mid-migration still serves it. `p_cursor_score`
        // is legitimately null for an unscored dish, which is why the cursor's *presence* is what
        // decides here, never the value's.
        if let cursor {
            parameters["p_cursor_review_count"] = .integer(cursor.reviewCount)
            parameters["p_cursor_score"] = cursor.score.map { .double($0) } ?? .null
            parameters["p_cursor_dish_name"] = .string(cursor.name)
            parameters["p_cursor_dish_id"] = .string(cursor.dishID.uuidString.lowercased())
        }
        let data = try await api.supabase
            .rpc("place_dishes", params: parameters)
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([MenuDish].self, from: data)
        return MenuDishPage(items: rows, requestedLimit: limit)
    }

    public func entriesAtPlace(
        restaurantID: UUID,
        scope: PlaceEntryScope,
        after cursor: PageCursor?,
        pageSize: Int
    ) async throws -> Page<EntryCard> {
        try await api.requireCurrentUserID()
        let limit = min(Self.maximumPageSize, max(1, pageSize))
        var parameters: [String: AnyJSON] = [
            "p_restaurant_id": .string(restaurantID.uuidString.lowercased()),
            "p_scope": .string(scope.rawValue),
            "p_page_size": .integer(limit)
        ]
        // First page → nulls. Next page → the LAST row's `created_at` AND `id` (contract, Reads).
        parameters["p_cursor_created_at"] = cursor
            .map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null
        parameters["p_cursor_id"] = cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null

        let data = try await api.supabase
            .rpc("get_entries_at_place", params: parameters)
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
        return Page(items: rows, requestedLimit: limit)
    }
}
