import Foundation
import Supabase

/// The live place directory: the existing `places-search` blend, widened with `search_all`.
///
/// **Two sources, deliberately.** `places-search?op=autocomplete` is what the composer has always
/// used — Google's predictions blended with the manual rows we hold, in server order, billed as one
/// session per pick. `search_all` (0023) additionally finds places we hold that Google would not
/// rank first for this query: somewhere the person has already eaten and named differently.
///
/// They run **concurrently and independently**: either may fail (the RPC does not exist until 0023
/// reaches an environment, and Google can rate-limit) and a search survives on whichever answered.
/// A place sheet that goes blank because one of two backends blinked is a place nobody attaches.
public struct PlaceDirectoryClient: PlaceDirectory {
    private let api: AteAPIClient
    private let restaurants: RestaurantSearchService
    private let places: any PlacesSearching
    /// One Places session per sheet: the keystrokes and the final `op=details` are billed together.
    private let sessionToken: PlacesSessionToken

    public init(api: AteAPIClient, sessionToken: PlacesSessionToken = PlacesSessionToken()) {
        self.api = api
        self.places = PlacesSearchClient(api: api)
        self.restaurants = RestaurantSearchService(api: api)
        self.sessionToken = sessionToken
    }

    public func search(_ query: String) async throws -> [PlaceSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        async let blended = try? restaurants.search(query: trimmed, origin: nil, sessionToken: sessionToken)
        async let held = try? searchAll(trimmed)

        // Places we already hold lead: selecting one costs nothing and cannot mint a duplicate row.
        var seen = Set<String>()
        var results: [PlaceSuggestion] = []
        for suggestion in (await held ?? []) + (await blended ?? []).map(PlaceSuggestion.init)
        where seen.insert(suggestion.dedupKey).inserted {
            results.append(suggestion)
        }
        return results
    }

    public func recents(limit: Int) async throws -> [PlaceSuggestion] {
        let rows = try await restaurants.recents(limit: limit)
        return rows.map(PlaceSuggestion.init)
    }

    /// `places-search?op=nearby`, already KNN-ordered and capped by the edge function. Returned in
    /// the server's order, never re-sorted.
    public func nearby(latitude: Double, longitude: Double) async throws -> [PlaceSuggestion] {
        let rows = try await restaurants.nearby(
            origin: SearchOrigin(latitude: latitude, longitude: longitude)
        )
        return rows.map(PlaceSuggestion.init)
    }

    public func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceRef {
        switch suggestion.selection {
        case .restaurant(let id):
            return PlaceRef(id: id, name: suggestion.name)
        case .googlePlace(let googlePlaceID):
            let response = try await places.details(
                googlePlaceID: googlePlaceID, sessionToken: sessionToken
            )
            return PlaceRef(id: response.restaurant.id, name: response.restaurant.name)
        }
    }

    public func add(name: String, suburb: String?, street: String?) async throws -> PlaceRef {
        // `add_manual_restaurant` takes a city; the street line is not a column it holds, so it is
        // folded into the city string only when there is one — never invented.
        let picked = try await restaurants.addManual(
            name: name,
            city: suburb?.nonEmptyTrimmed,
            cuisine: nil
        )
        _ = street
        return PlaceRef(id: picked.id, name: picked.name)
    }

    public func dishes(atPlace placeID: UUID, limit: Int) async throws -> [PlaceDish] {
        let rows: [PlaceDishRow] = try await api.rpc(
            "place_dishes",
            parameters: [
                "p_restaurant_id": .string(placeID.uuidString.lowercased()),
                "p_limit": .integer(limit)
            ]
        )
        return rows.map { PlaceDish(id: $0.dishID, name: $0.dishName, peopleCount: $0.peopleCount) }
    }

    // MARK: - search_all

    private func searchAll(_ query: String) async throws -> [PlaceSuggestion] {
        let rows: [SearchAllRow] = try await api.rpc(
            "search_all",
            parameters: ["p_query": .string(query), "p_limit_per_kind": .integer(8)]
        )
        return rows
            .filter { $0.kind == "place" }
            .compactMap { row in
                guard let id = UUID(uuidString: row.id) else { return nil }
                return PlaceSuggestion(restaurantID: id, name: row.title, subtitle: row.subtitle)
            }
    }

    private struct SearchAllRow: Decodable, Sendable {
        let kind: String
        let id: String
        let title: String
        let subtitle: String?
    }

    private struct PlaceDishRow: Decodable, Sendable {
        let dishID: UUID
        let dishName: String
        let peopleCount: Int?

        enum CodingKeys: String, CodingKey {
            case dishID = "dish_id"
            case dishName = "dish_name"
            case peopleCount = "people_count"
        }
    }
}

extension PlaceSuggestion {
    /// A blended picker row.
    init(_ row: RestaurantRowModel) {
        switch row.selection {
        case .restaurant(id: let id):
            self.init(
                restaurantID: id, name: row.name, subtitle: row.secondary,
                distanceMeters: row.distanceMeters
            )
        case .place(googlePlaceID: let googlePlaceID):
            self.init(
                id: googlePlaceID,
                name: row.name,
                subtitle: row.secondary,
                selection: .googlePlace(googlePlaceID),
                distanceMeters: row.distanceMeters
            )
        }
    }

    /// Two sources can offer the same place — `search_all` by row, the blend by Google prediction.
    /// Name-and-suburb is the only key both can produce, so it is what dedup uses; a name is a
    /// display string, and this is the one place it is allowed to behave like a key.
    var dedupKey: String {
        if let restaurantID { return restaurantID.uuidString.lowercased() }
        return "\(name.lowercased())|\(subtitle?.lowercased() ?? "")"
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
