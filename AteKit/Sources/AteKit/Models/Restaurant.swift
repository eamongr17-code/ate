import Foundation

/// Where a restaurant row came from (`restaurants.source`, migration 0014).
///
/// The DB pins this to exactly two values with a CHECK constraint, and a second CHECK ties it to
/// `google_place_id` in both directions — so this is a closed set, not an open string.
public enum RestaurantSource: String, Codable, Sendable, CaseIterable {
    /// Google-Places-backed catalogue row; `googlePlaceID` is non-nil.
    case places
    /// User-entered via the `add_manual_restaurant` RPC; `googlePlaceID` is nil.
    case manual
}

/// A restaurant in the shared global catalogue (`public.restaurants`, data-model §1.2).
///
/// Reference data: never end-user updatable or deletable. `avgRating` / `reviewCount` are NOT on
/// this row — they are derived and live on ``RestaurantStats``.
public struct Restaurant: AteRecord, Hashable {
    public static let table = "restaurants"
    public static let columns = "id,source,google_place_id,name,address,city,cuisine,cover_url,created_at"

    public let id: UUID
    public let source: RestaurantSource
    /// Nil for `source == .manual` (nullable since 0014); the natural key for Places rows.
    public let googlePlaceID: String?
    /// Display string. Never an identifier — joins go through ``id``.
    public let name: String
    public let address: String?
    /// NOT NULL server-side; `""` means "no locality" for manual rows (0014 keeps `city` non-null).
    public let city: String
    public let cuisine: String?
    /// The stored Places/app cover. The *derived* UGC cover lives on ``RestaurantStats/coverURLString``.
    public let coverURLString: String?
    public let createdAt: Date

    public init(
        id: UUID,
        source: RestaurantSource,
        googlePlaceID: String?,
        name: String,
        address: String? = nil,
        city: String,
        cuisine: String? = nil,
        coverURLString: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.source = source
        self.googlePlaceID = googlePlaceID
        self.name = name
        self.address = address
        self.city = city
        self.cuisine = cuisine
        self.coverURLString = coverURLString
        self.createdAt = createdAt
    }

    /// URLs are parsed at the edge, not at decode time — a malformed stored URL must not fail the
    /// whole row.
    public var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }

    /// `city` is NOT NULL but `""` is the "no locality supplied" sentinel for manual rows.
    public var locality: String? { city.isEmpty ? nil : city }

    public var isManual: Bool { source == .manual }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case googlePlaceID = "google_place_id"
        case name
        case address
        case city
        case cuisine
        case coverURLString = "cover_url"
        case createdAt = "created_at"
    }
}
