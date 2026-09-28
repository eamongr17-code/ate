import AteKit
import SwiftUI

/// **A dish, pushed.** Holds the store for the same reason ``PlaceDestination`` does, and wires the
/// one action a dish page has to the one ``SaveAction`` the whole app shares — so the bookmark in
/// its top bar behaves exactly like the one on a feed slip, in-flight guard and all.
struct DishDestination: View {
    let dishID: UUID
    let source: DetailSource
    let services: AteServices
    let saves: SaveAction
    var onPlace: (UUID) -> Void = { _ in }
    var onEntry: (UUID) -> Void = { _ in }
    var onProfile: (UUID) -> Void = { _ in }

    @State private var store: DishPageStore

    init(
        dishID: UUID,
        source: DetailSource,
        services: AteServices,
        saves: SaveAction,
        onPlace: @escaping (UUID) -> Void = { _ in },
        onEntry: @escaping (UUID) -> Void = { _ in },
        onProfile: @escaping (UUID) -> Void = { _ in }
    ) {
        self.dishID = dishID
        self.source = source
        self.services = services
        self.saves = saves
        self.onPlace = onPlace
        self.onEntry = onEntry
        self.onProfile = onProfile
        #if DEBUG
        let reads = SlowDetailReads.dishes(services.dishPages)
        #else
        let reads = services.dishPages
        #endif
        _store = State(initialValue: DishPageStore(
            dishID: dishID,
            source: source,
            dishes: reads,
            savedDishes: services.savedDishes,
            deletions: services.entryDeletions,
            // What the row that opened it already knew — the page draws from it at once (round 6).
            previews: DishPreviews.shared,
            analytics: services.analytics
        ))
    }

    var body: some View {
        DishScreen(
            store: store,
            onPlace: onPlace,
            // A review is a quote from a visit; tapping it opens that visit. A legacy review has
            // none, and its row is not a button at all — this never fires for one.
            onReview: { review in
                guard let entryID = review.entryID else { return }
                services.analytics(DetailEvents.dishReviewOpened(target: .entry))
                onEntry(entryID)
            },
            // The avatar and handle are the person, never the review (round 4).
            onProfile: { userID in
                services.analytics(DetailEvents.dishReviewOpened(target: .profile))
                onProfile(userID)
            },
            onSave: { summary in
                Task {
                    await saves.toggle(
                        dishID: summary.dishID,
                        // No entry to credit: this save was made on the dish itself, not off
                        // somebody's visit, so the provenance is honestly nothing.
                        entryID: nil,
                        isSaved: store.isSaved,
                        source: .dish
                    )
                }
            }
        )
    }
}
