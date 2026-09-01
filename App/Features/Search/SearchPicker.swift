import AteKit
import SwiftUI

/// What a picker hands back.
enum SearchPickerSelection: Hashable {
    case restaurant(PickedRestaurant)
    case dish(PickedDish)
}

/// **The one search component** (spec §10).
///
/// Search field, debounce, sectioning, ranking, states and create-fallback are identical in both
/// contexts; only chrome, the selection effect and the exit differ — and all three of those belong
/// to the *host*, not here. So `SearchPicker` renders the list and calls `onSelect`; the Search tab
/// pushes a detail, the Log sheet's WHERE/WHAT steps pop back with the value. Neither the nav title
/// nor the leading Cancel/Back item is set here, for the same reason: they are the host's toolbar.
///
/// Selection is programmatic rather than a `NavigationLink(value:)` even in `.browse`, because a
/// Places prediction is not a row yet — tapping it costs an `op=details` round-trip before there is
/// anything to navigate to. One code path for both kinds beats a link for one and a button for the
/// other (rule 2: the same action works identically everywhere it appears).
struct SearchPicker: View {
    let subject: SearchSubject
    let context: SearchContextName
    let services: SearchServices
    let onSelect: (SearchPickerSelection) -> Void

    /// Supplied by the Search tab so the scope buttons sit on the same view as `.searchable`.
    var scope: Binding<SearchScope>?

    @State private var searchText = ""
    @State private var focusRequested = false
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        scoped(
            content
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: prompt
                )
                .searchFocused($isSearchFieldFocused)
        )
        .onChange(of: focusRequested) { _, requested in
            // §11.3 keyboard rule, resolved by the dish list and applied here, where the field is.
            if requested { isSearchFieldFocused = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch subject {
        case .restaurants:
            RestaurantPickerList(
                services: services,
                context: context,
                searchText: searchText,
                onSelect: { onSelect(.restaurant($0)) }
            )
        case .dishes, .allDishes:
            DishPickerList(
                subject: subject,
                services: services,
                context: context,
                searchText: searchText,
                requestSearchFocus: $focusRequested,
                onSelect: { onSelect(.dish($0)) }
            )
            .id(subject)
        }
    }

    @ViewBuilder
    private func scoped(_ base: some View) -> some View {
        if let scope {
            base.searchScopes(scope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
        } else {
            base
        }
    }

    private var prompt: LocalizedStringKey {
        switch subject {
        case .restaurants: "Restaurants"
        case .dishes(_, let name): "Dishes at \(name)"
        case .allDishes: "Dishes"
        }
    }
}

/// The Search tab's two scopes. **No People scope** — V1 has no social graph (PRODUCT.md).
enum SearchScope: String, CaseIterable, Identifiable, Hashable {
    case dishes
    case restaurants

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dishes: "Dishes"
        case .restaurants: "Restaurants"
        }
    }

    var subject: SearchSubject {
        switch self {
        case .dishes: .allDishes
        case .restaurants: .restaurants
        }
    }
}
