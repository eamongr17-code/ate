#if DEBUG
import Foundation

/// The place directory, in memory — previews, tests, and the `-ate-preview-data` simulator drive.
///
/// Debug only, like the in-memory entry service: a shipped binary has no path to a place that did
/// not come from `places-search` or `add_manual_restaurant`.
public struct InMemoryPlaceDirectory: PlaceDirectory {
    private let places: [PlaceSuggestion]
    private let menu: [UUID: [PlaceDish]]

    public init(places: [PlaceSuggestion]? = nil, menu: [UUID: [PlaceDish]]? = nil) {
        self.places = places ?? Self.melbourne
        self.menu = menu ?? Self.tipoMenu
    }

    public func search(_ query: String) async throws -> [PlaceSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 2 else { return [] }
        return places.filter { $0.name.lowercased().contains(needle) }
    }

    public func recents(limit: Int) async throws -> [PlaceSuggestion] {
        Array(places.prefix(limit))
    }

    public func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceRef {
        PlaceRef(id: suggestion.restaurantID ?? UUID(), name: suggestion.name)
    }

    public func add(name: String, suburb: String?, street: String?) async throws -> PlaceRef {
        PlaceRef(id: UUID(), name: name)
    }

    public func dishes(atPlace placeID: UUID, limit: Int) async throws -> [PlaceDish] {
        Array((menu[placeID] ?? Self.tipoMenu.values.first ?? []).prefix(limit))
    }

    static let tipoID = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!

    static let melbourne: [PlaceSuggestion] = [
        PlaceSuggestion(restaurantID: tipoID, name: "Tipo 00", subtitle: "361 Little Bourke St"),
        PlaceSuggestion(restaurantID: UUID(uuidString: "B7E00000-0000-4000-8000-000000000002")!,
                        name: "Kisume", subtitle: "175 Flinders Ln"),
        PlaceSuggestion(restaurantID: UUID(uuidString: "B7E00000-0000-4000-8000-000000000003")!,
                        name: "Butchers Diner", subtitle: "224 Little Bourke St"),
        PlaceSuggestion(restaurantID: UUID(uuidString: "B7E00000-0000-4000-8000-000000000004")!,
                        name: "Osteria Ilaria", subtitle: "367 Little Bourke St"),
        PlaceSuggestion(restaurantID: UUID(uuidString: "B7E00000-0000-4000-8000-000000000005")!,
                        name: "400 Gradi", subtitle: "99 Lygon St")
    ]

    static let tipoMenu: [UUID: [PlaceDish]] = [
        tipoID: [
            PlaceDish(id: UUID(uuidString: "D7E00000-0000-4000-8000-000000000001")!,
                      name: "Tagliatelle al ragù", peopleCount: 24),
            PlaceDish(id: UUID(uuidString: "D7E00000-0000-4000-8000-000000000004")!,
                      name: "Pappardelle al ragù", peopleCount: 6),
            PlaceDish(id: UUID(uuidString: "D7E00000-0000-4000-8000-000000000005")!,
                      name: "Tagliolini al nero", peopleCount: 17),
            PlaceDish(id: UUID(uuidString: "D7E00000-0000-4000-8000-000000000003")!,
                      name: "Prawn spaghetti", peopleCount: 31)
        ]
    ]
}
#endif
