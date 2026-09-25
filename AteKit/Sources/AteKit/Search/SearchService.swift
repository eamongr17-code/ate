import Foundation
import Supabase

/// **Everything the Search tab reads.** One seam, four scopes and the Nearby list, so the store can be
/// driven from fixtures and the screen can be photographed with no backend at all.
///
/// Every read is keyset-paged: `nil` asks for the first page, and a page's ``SearchPage/next`` asks
/// for the one after it. Rows come back in the server's order and are never re-sorted.
public protocol SearchReading: Sendable {
    /// The Places scope's standing list. Location only ever *ranks* this list — nothing here is
    /// attached to anything (design rule 8), and no origin simply means no list.
    func nearbyPlaces(origin: SearchOrigin, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<PlaceResult>
    func places(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<PlaceResult>
    func dishes(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<DishResult>
    func people(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<PersonResult>
    /// Your shelf. A `nil` query is the whole of it, newest save first — the segment's pre-typing
    /// state — on the same cursor as a filtered one.
    func savedDishes(matching query: String?, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<SavedDish>
}

/// The live Search tab: `search_places`, `search_dishes`, `search_people`, `search_saved` and
/// `nearby_places` (migration 0031).
///
/// Five RPCs, one shape of call: the query, a limit, and the last row's key spelled out field by
/// field. Each row is the whole row — the name, the suburb (`locality`, never `city`), the aggregate
/// and the cover arrive together, so nothing is hydrated after the fact.
///
/// Accent folding and the two-character floor are the server's (`search_key`), not ours: "ragu"
/// finds "ragù" because the RPC says so, and a one-letter query costs one request that returns `[]`.
public struct SearchClient: SearchReading {
    /// One page of results. The artboard's rows are 62–76 tall, so a screen holds ~9; the server
    /// clamps at 50.
    public static let defaultPageSize = 20
    /// How far Nearby looks. The RPC's own default, written down so a change is a decision.
    public static let nearbyRadiusMeters = 5000.0

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    // MARK: - Places

    public func nearbyPlaces(
        origin: SearchOrigin,
        after cursor: SearchCursor?,
        pageSize: Int
    ) async throws -> SearchPage<PlaceResult> {
        var parameters: [String: AnyJSON] = [
            "p_lat": .double(origin.latitude),
            "p_lng": .double(origin.longitude),
            "p_radius_m": .double(Self.nearbyRadiusMeters),
            "p_limit": .integer(pageSize)
        ]
        if case .nearby(let distance, let id) = cursor {
            parameters["p_cursor_distance_m"] = .double(distance)
            parameters["p_cursor_id"] = .string(id.uuidString.lowercased())
        }
        let rows: [NearbyPlaceRow] = try await api.rpc("nearby_places", parameters: parameters)
        return .of(rows, limit: pageSize, row: PlaceResult.init, cursor: SearchCursor.init)
    }

    public func places(query: String, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<PlaceResult> {
        var parameters = Self.base(query, pageSize)
        if case .place(let tier, let reviews, let name, let id) = cursor {
            parameters["p_cursor_match_tier"] = .integer(tier)
            parameters["p_cursor_review_count"] = .integer(reviews)
            parameters["p_cursor_name"] = .string(name)
            parameters["p_cursor_id"] = .string(id.uuidString.lowercased())
        }
        let rows: [SearchPlaceRow] = try await api.rpc("search_places", parameters: parameters)
        return .of(rows, limit: pageSize, row: PlaceResult.init, cursor: SearchCursor.init)
    }

    // MARK: - Dishes and people

    public func dishes(query: String, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<DishResult> {
        var parameters = Self.base(query, pageSize)
        if case .dish(let tier, let reviews, let name, let id) = cursor {
            parameters["p_cursor_match_tier"] = .integer(tier)
            parameters["p_cursor_review_count"] = .integer(reviews)
            parameters["p_cursor_dish_name"] = .string(name)
            parameters["p_cursor_dish_id"] = .string(id.uuidString.lowercased())
        }
        let rows: [SearchDishRow] = try await api.rpc("search_dishes", parameters: parameters)
        return .of(rows, limit: pageSize, row: DishResult.init, cursor: SearchCursor.init)
    }

    public func people(query: String, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<PersonResult> {
        var parameters = Self.base(query, pageSize)
        if case .person(let tier, let username, let id) = cursor {
            parameters["p_cursor_match_tier"] = .integer(tier)
            parameters["p_cursor_username"] = .string(username)
            parameters["p_cursor_user_id"] = .string(id.uuidString.lowercased())
        }
        let rows: [SearchPersonRow] = try await api.rpc("search_people", parameters: parameters)
        return .of(rows, limit: pageSize, row: PersonResult.init, cursor: SearchCursor.init)
    }

    // MARK: - Saved

    /// `search_saved` — the shelf's own columns and its own `(saved_at, dish_id)` order, so a dish sits
    /// in the same place whichever screen found it. Matches the dish OR the place: "Tipo" finds what
    /// you saved there.
    public func savedDishes(
        matching query: String?,
        after cursor: SearchCursor?,
        pageSize: Int
    ) async throws -> SearchPage<SavedDish> {
        try await api.requireCurrentUserID()
        var parameters: [String: AnyJSON] = [
            "p_query": query.map { .string($0) } ?? .null,
            "p_limit": .integer(pageSize)
        ]
        if case .saved(let savedAt, let dishID) = cursor {
            parameters["p_cursor_saved_at"] = .string(PostgRESTTimestamp.string(from: savedAt))
            parameters["p_cursor_dish_id"] = .string(dishID.uuidString.lowercased())
        }
        let rows: [SearchSavedRow] = try await api.rpc("search_saved", parameters: parameters)
        return .of(rows, limit: pageSize, row: SavedDish.init, cursor: SearchCursor.init)
    }

    // MARK: - Machinery

    private static func base(_ query: String, _ pageSize: Int) -> [String: AnyJSON] {
        ["p_query": .string(query), "p_limit": .integer(pageSize)]
    }
}
