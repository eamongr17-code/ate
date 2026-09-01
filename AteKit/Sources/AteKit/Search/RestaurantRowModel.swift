import Foundation

/// One restaurant row in the picker, whatever section it came from (§11.1: *"Render kind:'place' and
/// kind:'manual' with the SAME row view"*).
///
/// Building this in AteKit rather than in the view is what keeps "the same action works identically
/// everywhere it appears" true: nearby, recents, manual matches and Places predictions all collapse
/// to `name + secondary + distance + how-to-select` before a `View` ever sees them.
public struct RestaurantRowModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// Suburb or address line, for display. Nil renders nothing — never a placeholder.
    public let secondary: String?
    /// The suburb alone, when we actually know it. Carried separately from ``secondary`` because
    /// that line may be a full street address (a Places prediction), and what a picked restaurant
    /// shows under its name is a suburb ("Chin Chin · Melbourne"), not "125 Flinders Ln, Melbourne VIC".
    public let locality: String?
    /// Nil renders nothing. Never "0 km" (§11.1).
    public let distanceMeters: Double?
    public let selection: RestaurantSelection

    public init(
        id: String,
        name: String,
        secondary: String?,
        locality: String? = nil,
        distanceMeters: Double?,
        selection: RestaurantSelection
    ) {
        self.id = id
        self.name = name
        self.secondary = secondary
        self.locality = locality
        self.distanceMeters = distanceMeters
        self.selection = selection
    }

    /// A blended `results[]` entry. Manual rows carry no distance by construction
    /// (`add_manual_restaurant` never sets `location`) — so they render name + suburb only.
    public init(_ result: RestaurantSearchResult) {
        switch result {
        case .place(let prediction):
            self.init(
                id: result.id,
                name: prediction.name,
                secondary: prediction.secondary.nonEmpty,
                locality: nil,
                distanceMeters: prediction.distanceMeters,
                selection: .place(googlePlaceID: prediction.googlePlaceID)
            )
        case .manual(let match):
            self.init(
                id: result.id,
                name: match.name,
                secondary: match.locality,
                locality: match.locality,
                distanceMeters: nil,
                selection: .restaurant(id: match.id)
            )
        }
    }

    /// A nearby row. `stub` comes from the enclosing response and decides whether the row is
    /// directly selectable or has to be resolved first — returns nil for an unusable row.
    public init?(_ nearby: NearbyRestaurant, stub: Bool) {
        guard let selection = nearby.selection(stub: stub) else { return nil }
        self.init(
            id: "n:\(nearby.rawID)",
            name: nearby.name,
            secondary: nearby.locality ?? nearby.address.nonEmpty,
            locality: nearby.locality,
            distanceMeters: nearby.distanceMeters,
            selection: selection
        )
    }

    /// A recents row — always a real row, always free to select.
    public init(recent restaurant: Restaurant) {
        self.init(
            id: "r:\(restaurant.id.uuidString)",
            name: restaurant.name,
            secondary: restaurant.locality ?? restaurant.address.nonEmpty,
            locality: restaurant.locality,
            distanceMeters: nil,
            selection: .restaurant(id: restaurant.id)
        )
    }

    /// For `search_result_selected(kind:)`.
    public var telemetryKind: String {
        switch selection {
        case .restaurant: "manual"
        case .place: "place"
        }
    }
}

extension Optional where Wrapped == String {
    /// `nil` for both nil and `""`, so "no secondary line" has one spelling.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
