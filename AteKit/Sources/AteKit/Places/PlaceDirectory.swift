import Foundation

/// A place, as the place sheet offers it.
///
/// Two kinds of row, and the difference is one round trip: a `restaurant` is already a row we hold
/// (so selecting it is free), a `googlePlace` is a prediction that becomes a row through
/// `places-search?op=details` — the only restaurant-create path there is.
public struct PlaceSuggestion: Identifiable, Sendable, Hashable {
    public enum Selection: Sendable, Hashable {
        case restaurant(UUID)
        case googlePlace(String)
    }

    /// Stable within one result set. A UUID string for a row, the Google place id for a prediction.
    public let id: String
    public var name: String
    /// The address or suburb under the name. `nil` rather than an empty string — a row with nothing
    /// to say shows nothing (design rule 1).
    public var subtitle: String?
    public var selection: Selection
    /// How far away, when the row came from a nearby search. `PlaceSheet.dc.html` prints it at the
    /// right of the row ("20 m", "140 m"); a typed result has none and shows none.
    public var distanceMeters: Double?

    public init(
        id: String,
        name: String,
        subtitle: String? = nil,
        selection: Selection,
        distanceMeters: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.selection = selection
        self.distanceMeters = distanceMeters
    }

    public init(restaurantID: UUID, name: String, subtitle: String? = nil, distanceMeters: Double? = nil) {
        self.init(
            id: restaurantID.uuidString.lowercased(),
            name: name,
            subtitle: subtitle,
            selection: .restaurant(restaurantID),
            distanceMeters: distanceMeters
        )
    }

    /// "20 m", "140 m", "1.2 km" — the artboard's own right-hand column.
    public var distance: String? {
        guard let distanceMeters, distanceMeters >= 0 else { return nil }
        if distanceMeters < 1000 {
            return "\(Int(distanceMeters.rounded())) m"
        }
        return "\((distanceMeters / 1000).formatted(.number.precision(.fractionLength(0...1)))) km"
    }

    /// The row that is already a place we hold, if this is one.
    public var restaurantID: UUID? {
        if case .restaurant(let id) = selection { return id }
        return nil
    }
}

/// Finding, resolving and creating places for the composer's Place key and the entry's place
/// correction. One seam, because the two surfaces must offer exactly the same set — the same action
/// working identically everywhere it appears.
public protocol PlaceDirectory: Sendable {
    /// Typed query. Server order is preserved; the client never re-sorts a blend.
    func search(_ query: String) async throws -> [PlaceSuggestion]
    /// The empty-query default: places this person has already eaten at.
    func recents(limit: Int) async throws -> [PlaceSuggestion]
    /// `PlaceSheet`'s Nearby section. Asked for **only** when the sheet has a location to ask with,
    /// which is only ever after the person allowed it on this screen. Design rule 8 is untouched:
    /// this lists rooms, it never attaches one.
    func nearby(latitude: Double, longitude: Double) async throws -> [PlaceSuggestion]
    /// Turns a tapped row into a real place with a UUID. Free for rows that are already rows.
    func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceRef
    /// "Add a new place" — `add_manual_restaurant`. The only create path that is not Google's.
    func add(name: String, suburb: String?, street: String?) async throws -> PlaceRef
    /// The dishes already on a place's menu, for the dish sheet.
    func dishes(atPlace placeID: UUID, limit: Int) async throws -> [PlaceDish]
}

/// One dish on a place's menu, as the dish sheet lists it.
public struct PlaceDish: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    /// "24 people" — how many distinct people have written about it. `nil` when nobody has yet.
    public var peopleCount: Int?

    public init(id: UUID, name: String, peopleCount: Int? = nil) {
        self.id = id
        self.name = name
        self.peopleCount = peopleCount
    }
}
