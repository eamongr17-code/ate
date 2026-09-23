import AteKit
import SwiftUI

/// **A profile, pushed.** The store is held by this view rather than made in the navigation
/// destination's builder, which SwiftUI calls again on every re-render — a store made there would be
/// thrown away and reloaded mid-scroll.
///
/// Its entries listen to ``SavedDishBroadcast`` like every other list, so a dish saved on the entry
/// page pushed on top of this one is already saved when the reader comes back to it. A block is the
/// one thing still passed up by hand: it is not a fact about a dish, it is the end of the page.
struct ProfileDestination: View {
    let userID: UUID
    let services: AteServices
    let saves: SaveAction
    var onOpen: (EntryCard) -> Void = { _ in }
    var onBlocked: (UUID) -> Void = { _ in }

    @State private var store: ProfileStore

    init(
        userID: UUID,
        services: AteServices,
        saves: SaveAction,
        onOpen: @escaping (EntryCard) -> Void = { _ in },
        onBlocked: @escaping (UUID) -> Void = { _ in }
    ) {
        self.userID = userID
        self.services = services
        self.saves = saves
        self.onOpen = onOpen
        self.onBlocked = onBlocked
        _store = State(initialValue: ProfileStore(
            userID: userID,
            profiles: services.profiles,
            savedDishes: services.savedDishes
        ))
    }

    var body: some View {
        ProfileScreen(
            store: store,
            onOpen: onOpen,
            onSave: { entry, dish in
                Task {
                    await saves.toggle(
                        dishID: dish.dishID,
                        entryID: entry.id,
                        isSaved: dish.isSaved,
                        source: .profile
                    )
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
}
