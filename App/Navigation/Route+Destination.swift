import SwiftUI

extension Route {
    /// **Every route's page, in one switch.** Each page is built in its own feature folder from the
    /// shell's ``RouteContext``; the shell only lays the page's top bar over what this returns.
    @MainActor @ViewBuilder
    func destination(_ context: RouteContext) -> some View {
        switch self {
        case .entry(let entry): EntryScreen(route: entry, context: context)
        // `Suggestions.dc.html` and `Ratings.dc.html` drew the tab bar under them; since round 4 every
        // pushed page hides it (Eamon's call, build 79), and these two lay the ground it stood on.
        case .suggestions: SuggestionsScreen(context: context).ateGround()
        case .profile(let userID): ProfileDestination(userID: userID, context: context)
        case .place(let restaurantID): PlaceDestination(restaurantID: restaurantID, context: context)
        case .dish(let dishID): DishDestination(dishID: dishID, context: context)
        case .tag(let tag): TagDishesScreen(tag: tag, context: context)
        case .ratings(let score): RatingsScreen(score: score, context: context).ateGround()
        // `Recap.dc.html` draws no tab bar — a statement is a printout you hold, on its own.
        case .statement(let month): RecapScreen(month: month, context: context)
        case .settings(let page): SettingsDestination(page: page, context: context)
        // The rebuilt Feed's list; the current app has no door to it.
        case .following: EmptyView()
        }
    }
}
