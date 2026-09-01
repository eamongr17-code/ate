#if DEBUG
import AteKit
import Foundation
import SwiftUI

/// In-memory stand-ins for the two search seams.
///
/// Their real job is to prove the seam: `SearchPicker` never touches `AteAPIClient`, Supabase, or a
/// JWT, so every state in §11.5 (first load, keystroke, empty, error, offline, signed out) can be
/// driven from a preview instead of from staging data that happens to be shaped right.
struct PreviewRestaurantSearch: RestaurantSearchProviding {
    var rows: [RestaurantRowModel] = PreviewFixtures.restaurantRows
    var searchRows: [RestaurantRowModel]?
    var failure: (any Error)?
    var latency: Duration = .milliseconds(120)

    func nearby(origin: SearchOrigin) async throws -> [RestaurantRowModel] {
        try await settle()
        return rows
    }

    func recents(limit: Int) async throws -> [RestaurantRowModel] {
        try await settle()
        return Array(rows.prefix(2))
    }

    func search(
        query: String,
        origin: SearchOrigin?,
        sessionToken: PlacesSessionToken?
    ) async throws -> [RestaurantRowModel] {
        try await settle()
        return searchRows ?? rows.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func resolve(_ row: RestaurantRowModel, sessionToken: PlacesSessionToken?) async throws -> PickedRestaurant {
        try await settle()
        return PickedRestaurant(id: UUID(), name: row.name, locality: row.locality)
    }

    func addManual(name: String, city: String?, cuisine: String?) async throws -> PickedRestaurant {
        try await settle()
        return PickedRestaurant(id: UUID(), name: name, locality: city)
    }

    private func settle() async throws {
        try? await Task.sleep(for: latency)
        if let failure { throw failure }
    }
}

struct PreviewDishSearch: DishSearchProviding {
    var historyRows: [DishRowModel] = PreviewFixtures.historyRows
    var menuRows: [DishRowModel] = PreviewFixtures.menuRows
    var failure: (any Error)?
    var latency: Duration = .milliseconds(120)

    func history(restaurantID: UUID, limit: Int) async throws -> [DishRowModel] {
        try await settle()
        return Array(historyRows.prefix(limit))
    }

    func menu(restaurantID: UUID, offset: Int, limit: Int) async throws -> DishListPage {
        try await settle()
        return DishListPage(rows: menuRows, nextOffset: nil)
    }

    func filterMenu(restaurantID: UUID, query: String, limit: Int) async throws -> [DishRowModel] {
        try await settle()
        return menuRows.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func popular(offset: Int, limit: Int) async throws -> DishListPage {
        try await settle()
        return DishListPage(rows: menuRows, nextOffset: nil)
    }

    func searchAll(query: String, limit: Int) async throws -> [DishRowModel] {
        try await settle()
        return menuRows.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func resolveOrCreate(name: String, restaurantID: UUID) async throws -> PickedDish {
        try await settle()
        return PickedDish(id: UUID(), name: name, restaurantID: restaurantID, wasCreated: true)
    }

    private func settle() async throws {
        try? await Task.sleep(for: latency)
        if let failure { throw failure }
    }
}

enum PreviewFixtures {
    static let restaurantID = UUID()

    static let restaurantRows: [RestaurantRowModel] = [
        RestaurantRowModel(
            id: "p:1", name: "Chin Chin", secondary: "Melbourne",
            locality: "Melbourne", distanceMeters: 540, selection: .place(googlePlaceID: "ChIJ1")
        ),
        RestaurantRowModel(
            id: "m:2", name: "Marg's Diner", secondary: "Fitzroy",
            locality: "Fitzroy", distanceMeters: nil, selection: .restaurant(id: restaurantID)
        ),
        RestaurantRowModel(
            id: "p:3", name: "Attica", secondary: "Ripponlea",
            locality: "Ripponlea", distanceMeters: 6200, selection: .place(googlePlaceID: "ChIJ3")
        )
    ]

    static let historyRows: [DishRowModel] = [
        DishRowModel(
            dishID: UUID(), name: "Kingfish sashimi", restaurantID: restaurantID,
            score: 4.6, reviewCount: 18, yourScore: Rating(exactly: 4.0),
            yourLastReviewedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    ]

    static let menuRows: [DishRowModel] = [
        DishRowModel(dishID: UUID(), name: "Son-in-law eggs", restaurantID: restaurantID, score: 4.8, reviewCount: 42),
        DishRowModel(dishID: UUID(), name: "Massaman curry", restaurantID: restaurantID, score: 4.1, reviewCount: 17),
        // The honest unrated state: `–/5`, never `0`.
        DishRowModel(dishID: UUID(), name: "Betel leaf", restaurantID: restaurantID, score: nil, reviewCount: 0)
    ]
}

extension SearchServices {
    static let preview = SearchServices(
        restaurants: PreviewRestaurantSearch(),
        dishes: PreviewDishSearch(),
        telemetry: NoOpSearchTelemetrySink()
    )

    static let previewEmpty = SearchServices(
        restaurants: PreviewRestaurantSearch(rows: [], searchRows: []),
        dishes: PreviewDishSearch(historyRows: [], menuRows: []),
        telemetry: NoOpSearchTelemetrySink()
    )

    static let previewSignedOut = SearchServices(
        restaurants: PreviewRestaurantSearch(failure: AteAPIError.notAuthenticated),
        dishes: PreviewDishSearch(failure: AteAPIError.notAuthenticated),
        telemetry: NoOpSearchTelemetrySink()
    )
}

#Preview("Search tab") {
    SearchView(services: .preview)
}

#Preview("Search tab — nothing to show") {
    SearchView(services: .previewEmpty)
}

#Preview("WHERE step (.pick)") {
    NavigationStack {
        SearchPicker(
            subject: .restaurants,
            context: .pick,
            services: .preview,
            onSelect: { _ in }
        )
        .navigationTitle("Where?")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("WHAT step (.pick)") {
    NavigationStack {
        SearchPicker(
            subject: .dishes(restaurantID: PreviewFixtures.restaurantID, restaurantName: "Chin Chin"),
            context: .pick,
            services: .preview,
            onSelect: { _ in }
        )
        .navigationTitle("Chin Chin")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
