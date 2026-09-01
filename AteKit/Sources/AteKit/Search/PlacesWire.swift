import Foundation

// The `places-search` edge-function wire contract (docs/backend/places-integration.md and
// manual-search-blend-contract.md). These types decode the function's JSON *exactly* — they are
// not domain models, and none of them is a `Restaurant`: the function selects
// `id, google_place_id, name, address, city, cuisine, cover_url` and deliberately omits
// `created_at`, which `Restaurant` requires.

// MARK: - Origin

/// A device location used to bias autocomplete and anchor nearby.
public struct SearchOrigin: Sendable, Hashable, Encodable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    private enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lng"
    }
}

// MARK: - autocomplete

/// A Google Places prediction. Not a row yet — selecting it costs an `op=details` round-trip that
/// upserts it into `restaurants`.
public struct PlacePrediction: Sendable, Hashable, Decodable {
    public let googlePlaceID: String
    public let name: String
    /// Address-ish line ("125 Flinders Ln, Melbourne VIC"). Absent on some predictions.
    public let secondary: String?
    /// Only present when the request carried an origin.
    public let distanceMeters: Double?

    public init(googlePlaceID: String, name: String, secondary: String? = nil, distanceMeters: Double? = nil) {
        self.googlePlaceID = googlePlaceID
        self.name = name
        self.secondary = secondary
        self.distanceMeters = distanceMeters
    }

    private enum CodingKeys: String, CodingKey {
        case googlePlaceID = "google_place_id"
        case name
        case secondary
        case distanceMeters = "distance_meters"
    }
}

/// A user-added (`source='manual'`) restaurant that fuzzy-matched the query. **Already a row** —
/// selecting it is free (no network).
public struct ManualRestaurantMatch: Sendable, Hashable, Decodable {
    public let id: UUID
    public let name: String
    /// `add_manual_restaurant` writes `''` when no locality was given; the RPC's return type also
    /// allows null. Both mean "no locality" — read ``locality``.
    public let city: String?
    public let cuisine: String?
    /// 0…1 trigram score. Ranking is the server's job; this is carried for debugging only.
    public let matchScore: Double

    public init(id: UUID, name: String, city: String? = nil, cuisine: String? = nil, matchScore: Double = 1) {
        self.id = id
        self.name = name
        self.city = city
        self.cuisine = cuisine
        self.matchScore = matchScore
    }

    public var locality: String? {
        guard let city, !city.isEmpty else { return nil }
        return city
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case city
        case cuisine
        case matchScore = "match_score"
    }
}

/// One entry of the blended, server-ranked `results[]`. The `kind` tag is the discriminator; the two
/// cases differ only in how selection resolves, never in how the row renders (§11.1).
public enum RestaurantSearchResult: Sendable, Hashable, Identifiable, Decodable {
    case place(PlacePrediction)
    case manual(ManualRestaurantMatch)

    private enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: any Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .kind)
        switch kind {
        case "place":
            self = .place(try PlacePrediction(from: decoder))
        case "manual":
            self = .manual(try ManualRestaurantMatch(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: try decoder.container(keyedBy: CodingKeys.self),
                debugDescription: "unknown search result kind '\(kind)'"
            )
        }
    }

    /// Stable across the two kinds, so one `ForEach` can render both (the legacy `keyExtractor`).
    public var id: String {
        switch self {
        case .place(let prediction): "p:\(prediction.googlePlaceID)"
        case .manual(let match): "m:\(match.id.uuidString)"
        }
    }

    public var name: String {
        switch self {
        case .place(let prediction): prediction.name
        case .manual(let match): match.name
        }
    }

    /// For telemetry (`search_result_selected(kind:)`) and nothing else — never a visual distinction.
    public var kind: String {
        switch self {
        case .place: "place"
        case .manual: "manual"
        }
    }
}

/// `op=autocomplete`. `results` is the field to render; `predictions` is the Places-only back-compat
/// field we deliberately ignore.
public struct PlacesAutocompleteResponse: Sendable, Decodable {
    public let stub: Bool
    /// Server-ranked and capped at 5. **Render in this order** — the client must not re-sort or
    /// re-section it (manual rows carry no distance and any distance sort would bury them).
    public let results: [RestaurantSearchResult]

    private enum CodingKeys: String, CodingKey { case stub, results }

    public init(stub: Bool, results: [RestaurantSearchResult]) {
        self.stub = stub
        self.results = results
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stub = try container.decodeIfPresent(Bool.self, forKey: .stub) ?? false
        // Lossy on purpose: a future third `kind` must degrade to "one fewer row", not to a failed
        // search. `results` is also absent on an older deployment — treat that as empty, not broken.
        let lossy = try container.decodeIfPresent([LossyDecoded<RestaurantSearchResult>].self, forKey: .results)
        self.results = (lossy ?? []).compactMap(\.value)
    }
}

// MARK: - nearby

/// A row from `op=nearby`.
///
/// **The stub trap.** In live mode `id` is a real `restaurants.id` UUID and the row is selectable
/// with zero round-trips. In STUB mode the function substitutes the Google place id string for `id`
/// (`stubNearby`: *"stub has no UUID; the place id stands in for the row id"*), so it is **not** a
/// row id and must be resolved through `op=details` first. Hence ``selection(stub:)`` — never read
/// `rawID` directly.
public struct NearbyRestaurant: Sendable, Hashable, Identifiable, Decodable {
    public let rawID: String
    public let googlePlaceID: String?
    public let name: String
    public let address: String?
    public let city: String?
    public let cuisine: String?
    public let coverURLString: String?
    public let distanceMeters: Double?

    public init(
        rawID: String,
        googlePlaceID: String? = nil,
        name: String,
        address: String? = nil,
        city: String? = nil,
        cuisine: String? = nil,
        coverURLString: String? = nil,
        distanceMeters: Double? = nil
    ) {
        self.rawID = rawID
        self.googlePlaceID = googlePlaceID
        self.name = name
        self.address = address
        self.city = city
        self.cuisine = cuisine
        self.coverURLString = coverURLString
        self.distanceMeters = distanceMeters
    }

    public var id: String { rawID }

    public var locality: String? {
        guard let city, !city.isEmpty else { return nil }
        return city
    }

    /// How selecting this row resolves, per the `stub` flag on the enclosing response.
    /// Returns nil for a row that can be neither used nor resolved (a malformed payload).
    public func selection(stub: Bool) -> RestaurantSelection? {
        if !stub, let id = UUID(uuidString: rawID) { return .restaurant(id: id) }
        if let googlePlaceID { return .place(googlePlaceID: googlePlaceID) }
        // Live mode, non-UUID id, no place id: nothing we can do with this row — drop it.
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case rawID = "id"
        case googlePlaceID = "google_place_id"
        case name
        case address
        case city
        case cuisine
        case coverURLString = "cover_url"
        case distanceMeters = "distance_meters"
    }
}

public struct PlacesNearbyResponse: Sendable, Decodable {
    public let stub: Bool
    /// `"db"`, `"google"` or `"blend"` — diagnostic only.
    public let source: String?
    public let restaurants: [NearbyRestaurant]

    public init(stub: Bool, source: String? = nil, restaurants: [NearbyRestaurant]) {
        self.stub = stub
        self.source = source
        self.restaurants = restaurants
    }

    private enum CodingKeys: String, CodingKey { case stub, source, restaurants }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stub = try container.decodeIfPresent(Bool.self, forKey: .stub) ?? false
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
        let lossy = try container.decodeIfPresent([LossyDecoded<NearbyRestaurant>].self, forKey: .restaurants)
        self.restaurants = (lossy ?? []).compactMap(\.value)
    }
}

// MARK: - details

/// The restaurant row `op=details` hands back after upserting the resolved place. A partial
/// projection of `restaurants` (no `created_at`, no `source`), which is why it is not a ``Restaurant``.
public struct ResolvedRestaurant: Sendable, Hashable, Identifiable, Decodable {
    public let id: UUID
    public let googlePlaceID: String?
    public let name: String
    public let address: String?
    public let city: String?
    public let cuisine: String?
    public let coverURLString: String?

    public init(
        id: UUID,
        googlePlaceID: String? = nil,
        name: String,
        address: String? = nil,
        city: String? = nil,
        cuisine: String? = nil,
        coverURLString: String? = nil
    ) {
        self.id = id
        self.googlePlaceID = googlePlaceID
        self.name = name
        self.address = address
        self.city = city
        self.cuisine = cuisine
        self.coverURLString = coverURLString
    }

    public var locality: String? {
        guard let city, !city.isEmpty else { return nil }
        return city
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case googlePlaceID = "google_place_id"
        case name
        case address
        case city
        case cuisine
        case coverURLString = "cover_url"
    }
}

public struct PlacesDetailsResponse: Sendable, Decodable {
    public let stub: Bool
    public let restaurant: ResolvedRestaurant

    public init(stub: Bool, restaurant: ResolvedRestaurant) {
        self.stub = stub
        self.restaurant = restaurant
    }

    private enum CodingKeys: String, CodingKey { case stub, restaurant }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stub = try container.decodeIfPresent(Bool.self, forKey: .stub) ?? false
        self.restaurant = try container.decode(ResolvedRestaurant.self, forKey: .restaurant)
    }
}

// MARK: - Selection

/// What tapping a restaurant row has to do. The whole point of the type is that the *view* never
/// has to know whether a row came from nearby, the blend, recents, or the stub.
public enum RestaurantSelection: Sendable, Hashable {
    /// Already a `restaurants` row — hand the id straight back, no network.
    case restaurant(id: UUID)
    /// A Places prediction — resolve via `op=details` (spinner on the tapped row only).
    case place(googlePlaceID: String)
}

/// The value ``SearchPicker`` hands back when a restaurant is picked.
public struct PickedRestaurant: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let locality: String?

    public init(id: UUID, name: String, locality: String?) {
        self.id = id
        self.name = name
        self.locality = locality
    }

    public init(_ restaurant: Restaurant) {
        self.init(id: restaurant.id, name: restaurant.name, locality: restaurant.locality)
    }

    public init(_ restaurant: ResolvedRestaurant) {
        self.init(id: restaurant.id, name: restaurant.name, locality: restaurant.locality)
    }
}

// MARK: - Lossy array element

/// Decodes `T`, or nothing, without failing its enclosing array. Additive server changes (a new
/// result `kind`, a new nearby shape) must cost one row, not the whole screen.
struct LossyDecoded<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?

    init(from decoder: any Decoder) throws {
        self.value = try? T(from: decoder)
    }
}
