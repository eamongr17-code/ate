import AteKit
import SwiftUI

/// **A profile, pushed.** The store is held by this view rather than made in the navigation
/// destination's builder, which SwiftUI calls again on every re-render — a store made there would be
/// thrown away and reloaded mid-scroll.
///
/// It also owns the two things a profile has to tell the rest of the app: a save here is a save
/// everywhere (the feed behind it flips too), and a block empties every open list.
struct ProfileDestination: View {
    let userID: UUID
    let services: AteServices
    /// The list behind this page.
    let feed: EntryListStore
    let saved: SavedDishesStore
    var onOpen: (EntryCard) -> Void = { _ in }
    var onBlocked: (UUID) -> Void = { _ in }

    @State private var store: ProfileStore

    init(
        userID: UUID,
        services: AteServices,
        feed: EntryListStore,
        saved: SavedDishesStore,
        onOpen: @escaping (EntryCard) -> Void = { _ in },
        onBlocked: @escaping (UUID) -> Void = { _ in }
    ) {
        self.userID = userID
        self.services = services
        self.feed = feed
        self.saved = saved
        self.onOpen = onOpen
        self.onBlocked = onBlocked
        _store = State(initialValue: ProfileStore(userID: userID, profiles: services.profiles))
    }

    var body: some View {
        ProfileScreen(
            store: store,
            onOpen: onOpen,
            onSave: { entry, dish in
                Task {
                    await saveAction.toggle(
                        dishID: dish.dishID,
                        entryID: entry.id,
                        isSaved: dish.isSaved,
                        source: .profile
                    ) { isSaved in
                        store.entries.setSaved(dishID: dish.dishID, to: isSaved)
                        // The same bookmark, on the same dish, in the list this page was opened
                        // from. Going back to a feed that disagrees would read as a lost save.
                        feed.setSaved(dishID: dish.dishID, to: isSaved)
                    }
                }
            },
            onBlocked: {
                services.analytics(SocialEvents.userBlocked())
                onBlocked(userID)
            },
            onViewed: { isMe in services.analytics(SocialEvents.profileViewed(isMe: isMe)) },
            onReported: { services.analytics(SocialEvents.profileReported()) }
        )
    }

    private var saveAction: SaveAction {
        SaveAction(saves: services.saves, analytics: services.analytics, shelf: saved)
    }
}
