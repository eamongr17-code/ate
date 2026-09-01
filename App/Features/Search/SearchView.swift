import AteKit
import SwiftUI

/// The Search tab (§10, `.browse`).
///
/// Root of its own `NavigationStack`, large "Search" title, two scopes — **Dishes and Restaurants
/// only; there is no People scope**, because V1 has no social graph.
///
/// A host does `SearchView(services: .live(api: api), detail: .live(api: api))` — both from the
/// app's one shared client.
struct SearchView: View {
    let services: SearchServices
    /// How this stack builds detail screens (same seam the feed uses).
    let detail: DetailContext

    @State private var scope: SearchScope = .dishes
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            SearchPicker(
                subject: scope.subject,
                context: .browse,
                services: services,
                onSelect: { selection in
                    // A picked row pushes the same route values the feed pushes — one destination
                    // vocabulary for the whole app, ids only, names never used as identity.
                    switch selection {
                    case .dish(let dish): path.append(DishRoute(dishID: dish.id))
                    case .restaurant(let restaurant): path.append(RestaurantRoute(restaurantID: restaurant.id))
                    }
                },
                scope: $scope
            )
            .navigationTitle("Search")
            .detailDestinations(source: .search, context: detail)
        }
    }
}
