import AteKit
import SwiftUI

/// The Feed's three stores, as the shell holds them.
@MainActor
struct FeedStores {
    let edition: FeedEditionStore
    let latest: EntryListStore
    let area: FeedAreaModel
}

extension FeedScreen {
    /// The feed's stores, made once by the shell: the edition's sections, the latest receipts, and the
    /// area they are about.
    ///
    /// Every read takes the area's city at the moment it is asked for, so a reload after the chip
    /// changes is the whole of switching areas. The latest receipts also listen for deletes: your own
    /// entry is never in the feed, but a delete is announced to everything that shows entries.
    @MainActor
    static func stores(
        services: AteServices,
        isSignedIn: @escaping @MainActor () -> Bool
    ) -> FeedStores {
        let reader = services.feed
        let api = services.api
        // Whose remembered choices: the signed-in person — or, on the preview drive, its one person.
        let preview = services.isPreviewData ? AteServices.previewOwner : nil
        let owner: @Sendable () -> UUID? = { [api] in preview ?? api.currentUserID }
        let area = FeedAreaModel(
            reader: reader,
            store: UserDefaultsStore(),
            owner: owner,
            analytics: services.analytics
        )
        // A short run, not the feed: one page of the cap, never paged (round 8).
        let latest = EntryListStore(
            pageSize: FeedEditionStore.latestCap,
            fallbackMessage: "Couldn't load the feed.",
            savedDishes: services.savedDishes
        ) { cursor, pageSize in
            // A first page works near me out (for at most a couple of seconds); a later one reads the
            // city the first one did.
            let city = cursor == nil ? await area.cityForFirstPage() : await area.cityForNextPage
            return try await reader.feedPage(
                after: cursor, pageSize: pageSize, includeOwn: false, area: nil, city: city
            )
        }
        latest.listen(to: services.entryDeletions)
        let edition = FeedEditionStore(
            reads: services.feedEdition,
            store: UserDefaultsStore(),
            owner: owner,
            isSignedIn: isSignedIn,
            city: { await area.cityForFirstPage() },
            analytics: services.analytics,
            savedDishes: services.savedDishes
        )
        // Near me asks for the location the first time a feed page is read on it — the Feed
        // opening, never launch — through the one location path the app has.
        let locator = AteLocation()
        area.locate = { [locator] in
            await locator.current().map { (latitude: $0.latitude, longitude: $0.longitude) }
        }
        // An answer that lands after the feed was read, and moves the city: read it again.
        area.onNearMeChanged = { [weak latest, weak edition] in
            Task {
                async let sections: Void? = edition?.reload()
                await latest?.reload()
                _ = await sections
            }
        }
        return FeedStores(edition: edition, latest: latest, area: area)
    }
}
