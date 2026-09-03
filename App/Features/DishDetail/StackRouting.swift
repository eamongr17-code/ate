import AteKit
import SwiftUI

// How a screen deep inside a navigation stack pushes the next one, and who counts the tap.
//
// The problem this solves: `DishDetailView` and `DiaryEntryView` are pushed *into* whatever stack is
// hosting them and never see that stack's `NavigationPath`. A stock `NavigationLink(value:)` handles
// the push — but it is not an action, so there is nowhere to record `restaurant_name_tapped` or
// `diary_entry_dish_opened`, and inside a dense row it is promoted to the whole row, which is exactly
// the nested-target failure Rule R (§5) is about.
//
// So the push arrives as an environment action installed once per stack, in the shape SwiftUI uses
// for `openURL`/`dismiss`. Two consequences worth the pattern: one place per stack decides how a
// route is reached, and the funnel event fires in that one place rather than at each of five sites.

/// Opens a restaurant from anywhere in the installing stack. See ``RestaurantNameLink``.
struct OpenRestaurantAction {
    private let handler: (@MainActor (UUID, RestaurantLinkOrigin) -> Void)?

    init(handler: (@MainActor (UUID, RestaurantLinkOrigin) -> Void)? = nil) {
        self.handler = handler
    }

    /// False in previews and in any host that hasn't installed routing — callers degrade rather than
    /// render a dead affordance.
    var isWired: Bool { handler != nil }

    @MainActor
    func callAsFunction(_ restaurantID: UUID, from origin: RestaurantLinkOrigin) {
        handler?(restaurantID, origin)
    }
}

/// Opens a dish's public page from anywhere in the installing stack.
struct OpenDishAction {
    private let handler: (@MainActor (UUID) -> Void)?

    init(handler: (@MainActor (UUID) -> Void)? = nil) {
        self.handler = handler
    }

    var isWired: Bool { handler != nil }

    @MainActor
    func callAsFunction(_ dishID: UUID) {
        handler?(dishID)
    }
}

extension EnvironmentValues {
    @Entry var openRestaurant = OpenRestaurantAction()
    @Entry var openDish = OpenDishAction()
}

extension View {
    /// Installs this stack's push actions. **Once per `NavigationStack`, at its root**, next to
    /// ``SwiftUI/View/detailDestinations(source:context:)`` — the two are a pair: this one appends
    /// the route value, that one turns it into a screen.
    ///
    /// `restaurant_name_tapped` is recorded here rather than inside ``RestaurantNameLink`` so the
    /// whole app has one place where a restaurant is opened and one place where the event fires.
    func stackRouting(
        path: Binding<NavigationPath>,
        analytics: @escaping AnalyticsRecorder
    ) -> some View {
        self
            .environment(\.openRestaurant, OpenRestaurantAction { restaurantID, origin in
                analytics(DiaryEvents.restaurantNameTapped(from: origin))
                path.wrappedValue.append(RestaurantRoute(restaurantID: restaurantID))
            })
            .environment(\.openDish, OpenDishAction { dishID in
                path.wrappedValue.append(DishRoute(dishID: dishID))
            })
    }
}
