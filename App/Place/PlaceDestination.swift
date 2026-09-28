import AteKit
import SwiftUI

/// **A place, pushed.** The store is held by this view rather than made in the navigation
/// destination's builder, which SwiftUI calls again on every re-render — a store made there would
/// be thrown away and reloaded mid-scroll.
///
/// Both of its entry lists listen to ``SavedDishBroadcast`` like every other list, so a dish saved
/// on the entry page pushed on top of this one is already saved when the reader comes back.
struct PlaceDestination: View {
    let restaurantID: UUID
    let source: DetailSource
    let services: AteServices
    let saves: SaveAction
    var onDish: (UUID) -> Void = { _ in }
    var onOpen: (EntryCard) -> Void = { _ in }
    var onProfile: (UUID) -> Void = { _ in }

    @State private var store: PlacePageStore

    init(
        restaurantID: UUID,
        source: DetailSource,
        services: AteServices,
        saves: SaveAction,
        onDish: @escaping (UUID) -> Void = { _ in },
        onOpen: @escaping (EntryCard) -> Void = { _ in },
        onProfile: @escaping (UUID) -> Void = { _ in }
    ) {
        self.restaurantID = restaurantID
        self.source = source
        self.services = services
        self.saves = saves
        self.onDish = onDish
        self.onOpen = onOpen
        self.onProfile = onProfile
        #if DEBUG
        let reads = SlowDetailReads.places(services.placePages)
        #else
        let reads = services.placePages
        #endif
        _store = State(initialValue: PlacePageStore(
            restaurantID: restaurantID,
            source: source,
            places: reads,
            savedDishes: services.savedDishes,
            deletions: services.entryDeletions,
            previews: PlacePreviews.shared,
            analytics: services.analytics
        ))
    }

    var body: some View {
        PlaceScreen(
            store: store,
            onDish: onDish,
            onOpen: onOpen,
            onProfile: onProfile,
            // The same save the feed makes, from the same object: optimistic, broadcast, felt, and
            // counted at the tap.
            onSave: { entry, dish in
                Task {
                    await saves.toggle(
                        dishID: dish.dishID,
                        entryID: entry.id,
                        isSaved: dish.isSaved,
                        source: .place
                    )
                }
            },
            onMenuPhoto: { services.analytics(DetailEvents.menuPhotoOpened()) }
        )
    }
}

extension PlaceDestination {
    /// A place, as the shell pushes it.
    init(restaurantID: UUID, context: RouteContext) {
        self.init(
            restaurantID: restaurantID,
            source: context.source,
            services: context.services,
            saves: context.saves,
            onDish: { context.open(.dish($0), from: .place) },
            onOpen: { context.open(.entry($0)) },
            onProfile: { context.open(.profile($0)) }
        )
    }
}
