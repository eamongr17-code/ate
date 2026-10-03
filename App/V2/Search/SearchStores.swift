import AteKit
import SwiftUI

/// **The Search tab's stores**, made by its router the first time the tab is shown: the one query
/// and its four scopes (opening on Dishes — "this is a dish focused app", Eamon 3 Oct — and staying
/// on the chosen scope when the field is cleared), and the recent searches shown before typing.
@MainActor
struct SearchStores {
    let search: SearchStore
    let recents: RecentSearches

    init(services: AteServices) {
        search = SearchStore(
            service: services.search,
            scope: .dishes,
            analytics: services.analytics,
            savedDishes: services.savedDishes,
            clearsTo: nil
        )
        recents = RecentSearches(owner: services.api.currentUserID)
    }
}
