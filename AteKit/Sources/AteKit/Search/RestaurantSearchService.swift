import Foundation
import PostgREST
import Supabase

/// Everything the restaurant subject of the picker needs. A protocol so the view model can be
/// driven from fixtures, and so the Log flow's WHERE step consumes exactly the same seam.
public protocol RestaurantSearchProviding: Sendable {
    /// §11.1 empty-query default: nearby, distance-ascending, ≤10, served by the edge function.
    func nearby(origin: SearchOrigin) async throws -> [RestaurantRowModel]
    /// §11.1 empty-query default: the last `limit` restaurants this viewer logged at.
    func recents(limit: Int) async throws -> [RestaurantRowModel]
    /// §11.1 ≥2 chars: the server-ranked blend. **Returned in server order, never re-sorted.**
    func search(
        query: String,
        origin: SearchOrigin?,
        sessionToken: PlacesSessionToken?
    ) async throws -> [RestaurantRowModel]
    /// Turn a tapped row into a real restaurant. Free for rows that are already rows; one
    /// `op=details` round-trip for a Places prediction.
    func resolve(_ row: RestaurantRowModel, sessionToken: PlacesSessionToken?) async throws -> PickedRestaurant
    /// §11.2 create-fallback: `add_manual_restaurant`.
    func addManual(name: String, city: String?, cuisine: String?) async throws -> PickedRestaurant
}

public struct RestaurantSearchService: RestaurantSearchProviding {
    /// §11.1: recents is "last 5 logged restaurants".
    public static let defaultRecentsLimit = 5
    /// How many of the viewer's reviews to scan to find `limit` *distinct* restaurants. Someone who
    /// logs five dishes per sitting needs a wider window than five reviews; one page is plenty and
    /// costs one round-trip.
    static let recentsScanPageSize = 60

    private let api: AteAPIClient
    private let places: any PlacesSearching
    private let nearbyCache: NearbyCache

    public init(api: AteAPIClient, places: (any PlacesSearching)? = nil, nearbyCache: NearbyCache = NearbyCache()) {
        self.api = api
        self.places = places ?? PlacesSearchClient(api: api)
        self.nearbyCache = nearbyCache
    }

    // MARK: - Nearby

    public func nearby(origin: SearchOrigin) async throws -> [RestaurantRowModel] {
        if let cached = await nearbyCache.value(for: origin) { return cached }
        let response = try await places.nearby(origin: origin, radiusMeters: nil)
        // The edge function already returns these KNN/distance-ordered and capped. Rows we can
        // neither select nor resolve are dropped rather than rendered as dead ends.
        let rows = response.restaurants.compactMap { RestaurantRowModel($0, stub: response.stub) }
        await nearbyCache.store(rows, for: origin)
        return rows
    }

    // MARK: - Recents

    public func recents(limit: Int = RestaurantSearchService.defaultRecentsLimit) async throws -> [RestaurantRowModel] {
        let viewerID = try await api.requireCurrentUserID()
        let page = try await api.page(
            Review.self,
            request: PageRequest(limit: Self.recentsScanPageSize)
        ) { $0.eq("reviewer_id", value: viewerID.uuidString) }

        // Newest-first order, deduped, capped — the restaurant you logged at most recently leads.
        var ordered: [UUID] = []
        var seen = Set<UUID>()
        for review in page.items where seen.insert(review.restaurantID).inserted {
            ordered.append(review.restaurantID)
            if ordered.count == limit { break }
        }
        guard !ordered.isEmpty else { return [] }

        // `in.(…)` comes back in arbitrary order — restore the recency order explicitly.
        let restaurants = try await api.fetchByIDs(Restaurant.self, ids: ordered)
        let byID = Dictionary(uniqueKeysWithValues: restaurants.map { ($0.id, $0) })
        return ordered.compactMap { byID[$0] }.map(RestaurantRowModel.init(recent:))
    }

    // MARK: - Search

    public func search(
        query: String,
        origin: SearchOrigin?,
        sessionToken: PlacesSessionToken?
    ) async throws -> [RestaurantRowModel] {
        let response = try await places.autocomplete(query: query, origin: origin, sessionToken: sessionToken)
        // ONE flat section, server order preserved (manual-search-blend-contract §3/§5.3: the FE
        // must NOT re-sort — manual rows carry no distance and any distance sort buries them).
        return response.results.map(RestaurantRowModel.init)
    }

    // MARK: - Resolution

    public func resolve(
        _ row: RestaurantRowModel,
        sessionToken: PlacesSessionToken?
    ) async throws -> PickedRestaurant {
        switch row.selection {
        case .restaurant(let id):
            // Already a row (manual match, recent, or a live-mode nearby row): zero round-trips.
            return PickedRestaurant(id: id, name: row.name, locality: row.locality)
        case .place(let googlePlaceID):
            let response = try await places.details(googlePlaceID: googlePlaceID, sessionToken: sessionToken)
            return PickedRestaurant(response.restaurant)
        }
    }

    // MARK: - Manual add

    public func addManual(name: String, city: String?, cuisine: String?) async throws -> PickedRestaurant {
        try await api.requireCurrentUserID()
        // The RPC trims and validates server-side and returns the whole row; `location` (PostGIS
        // EWKB) rides along in the payload and is ignored by Restaurant's explicit CodingKeys.
        let restaurant: Restaurant = try await api.rpc(
            "add_manual_restaurant",
            parameters: [
                "p_name": .string(name),
                "p_city": .string(city ?? ""),
                "p_cuisine": cuisine.map { AnyJSON.string($0) } ?? .null
            ]
        )
        return PickedRestaurant(restaurant)
    }
}

/// The 5-minute nearby cache (§1.2: *"Nearby prefetched on app foreground (cached 5 min) so `+`
/// opens with results present"*).
///
/// Keyed on the origin rounded to ~100 m, so a stationary device with jittering GPS gets one cached
/// answer rather than a fresh billable call per fix. An actor because the prefetch (foreground) and
/// the read (picker appear) genuinely race.
public actor NearbyCache {
    /// ~100 m at Melbourne's latitude — three decimal places of a degree.
    static let originPrecision: Double = 1000
    public static let defaultTTL: Duration = .seconds(300)

    private struct Entry {
        let rows: [RestaurantRowModel]
        let storedAt: ContinuousClock.Instant
    }

    private var entries: [String: Entry] = [:]
    private let ttl: Duration
    private let clock = ContinuousClock()

    public init(ttl: Duration = NearbyCache.defaultTTL) {
        self.ttl = ttl
    }

    public func value(for origin: SearchOrigin) -> [RestaurantRowModel]? {
        guard let entry = entries[Self.key(origin)] else { return nil }
        guard clock.now - entry.storedAt < ttl else {
            entries[Self.key(origin)] = nil
            return nil
        }
        return entry.rows
    }

    public func store(_ rows: [RestaurantRowModel], for origin: SearchOrigin) {
        entries[Self.key(origin)] = Entry(rows: rows, storedAt: clock.now)
    }

    public func clear() {
        entries.removeAll()
    }

    static func key(_ origin: SearchOrigin) -> String {
        let lat = (origin.latitude * originPrecision).rounded() / originPrecision
        let lng = (origin.longitude * originPrecision).rounded() / originPrecision
        return "\(lat),\(lng)"
    }
}
