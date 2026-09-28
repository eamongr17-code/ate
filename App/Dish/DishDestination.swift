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
    /// A "More like this" card: that dish.
    var onDish: (UUID) -> Void = { _ in }
    /// A "More to explore" chip: that tag's page.
    var onTag: (DishTagRoute) -> Void = { _ in }

    @State private var store: DishPageStore
    @State private var explore: DishExploreStore?

    init(
        dishID: UUID,
        source: DetailSource,
        services: AteServices,
        saves: SaveAction,
        onPlace: @escaping (UUID) -> Void = { _ in },
        onEntry: @escaping (UUID) -> Void = { _ in },
        onProfile: @escaping (UUID) -> Void = { _ in },
        onDish: @escaping (UUID) -> Void = { _ in },
        onTag: @escaping (DishTagRoute) -> Void = { _ in }
    ) {
        self.dishID = dishID
        self.source = source
        self.services = services
        self.saves = saves
        self.onPlace = onPlace
        self.onEntry = onEntry
        self.onProfile = onProfile
        self.onDish = onDish
        self.onTag = onTag
        // Signed-in reads (round 7): a browser with no session never holds their space open.
        _explore = State(initialValue: services.hasSession
            ? DishExploreStore(dishID: dishID, reads: services.dishExplore)
            : nil)
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
            explore: explore,
            onTag: { tag in
                services.analytics(DetailEvents.dishTagOpened(kind: tag.kind))
                onTag(DishTagRoute(tag))
            },
            onSimilar: { dish, position in
                services.analytics(DetailEvents.similarDishOpened(position: position))
                // The card printed the dish, its place, its score and its photo: the page draws
                // them at once (round 6).
                DishPreviews.shared.note(DishPreview(dish))
                onDish(dish.dishID)
            },
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

extension DishDestination {
    /// One dish — and, under its reviews, the dishes like it and its tags (round 7).
    init(dishID: UUID, context: RouteContext) {
        self.init(
            dishID: dishID,
            source: context.source,
            services: context.services,
            saves: context.saves,
            onPlace: { context.open(.place($0), from: .dish) },
            onEntry: { context.open(.entry(EntryRoute(entryID: $0))) },
            onProfile: { context.open(.profile($0)) },
            onDish: { context.open(.dish($0), from: .similar) },
            onTag: { context.open(.tag($0)) }
        )
    }
}
