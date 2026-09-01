import AteKit
import SwiftUI

/// The Search tab (§10, `.browse`).
///
/// Root of its own `NavigationStack`, large "Search" title, two scopes — **Dishes and Restaurants
/// only; there is no People scope**, because V1 has no social graph.
///
/// NOT wired into a `TabView` here on purpose: the tab scaffold belongs to the Feed build and the
/// lead composes them at merge. A host does `SearchView(services: .live(api: api))`.
struct SearchView: View {
    let services: SearchServices

    @State private var scope: SearchScope = .dishes
    @State private var path: [SearchDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            SearchPicker(
                subject: scope.subject,
                context: .browse,
                services: services,
                onSelect: { selection in
                    path.append(SearchDestination(selection))
                },
                scope: $scope
            )
            .navigationTitle("Search")
            .navigationDestination(for: SearchDestination.self) { destination in
                SearchDestinationPlaceholder(destination: destination)
            }
        }
    }
}

/// What a `.browse` selection pushes.
///
/// Carries the display name alongside the id so the destination has a title before it has loaded —
/// ids are the identity, names are never used as one.
enum SearchDestination: Hashable {
    case dish(id: UUID, name: String)
    case restaurant(id: UUID, name: String)

    init(_ selection: SearchPickerSelection) {
        switch selection {
        case .dish(let dish): self = .dish(id: dish.id, name: dish.name)
        case .restaurant(let restaurant): self = .restaurant(id: restaurant.id, name: restaurant.name)
        }
    }
}

/// Stand-in until Dish detail and Restaurant detail land (those surfaces belong to other builds in
/// this wave). **Integration point:** swap this one `navigationDestination` body for the real
/// screens; nothing else in the search stack changes.
struct SearchDestinationPlaceholder: View {
    let destination: SearchDestination

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text("This screen ships with the detail flow.")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var title: String {
        switch destination {
        case .dish(_, let name), .restaurant(_, let name): name
        }
    }

    private var icon: String {
        switch destination {
        case .dish: "fork.knife"
        case .restaurant: "storefront"
        }
    }
}
