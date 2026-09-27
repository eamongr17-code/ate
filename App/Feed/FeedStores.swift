import AteKit
import SwiftUI

extension FeedScreen {
    /// The feed's two stores, made once by the shell: the list, and the area it is about.
    ///
    /// Every page the list loads reads the area at the moment it is asked for, so a reload after
    /// the pill changes is the whole of switching areas. The list also listens for deletes: your
    /// own entry is never in the feed, but a delete is announced to everything that shows entries.
    @MainActor
    static func stores(services: AteServices) -> (list: EntryListStore, area: FeedAreaModel) {
        let reader = services.feed
        let api = services.api
        let area = FeedAreaModel(
            reader: reader,
            store: UserDefaultsStore(),
            owner: { [api] in api.currentUserID },
            analytics: services.analytics
        )
        let list = EntryListStore(
            fallbackMessage: "Couldn't load the feed.",
            savedDishes: services.savedDishes
        ) { cursor, pageSize in
            // The city (round 5) replaces the locality area. A first page works near me out (for at
            // most a couple of seconds); every later page reads the city the first one did.
            let city = cursor == nil ? await area.cityForFirstPage() : await area.cityForNextPage
            return try await reader.feedPage(
                after: cursor, pageSize: pageSize, includeOwn: false, area: nil, city: city
            )
        }
        list.listen(to: services.entryDeletions)
        // Near me asks for the location the first time a feed page is read on it — the Feed
        // opening, never launch — through the one location path the app has.
        let locator = AteLocation()
        area.locate = { [locator] in
            await locator.current().map { (latitude: $0.latitude, longitude: $0.longitude) }
        }
        // An answer that lands after the feed was read, and moves the city: read it again.
        area.onNearMeChanged = { [weak list] in
            Task { await list?.reload() }
        }
        return (list, area)
    }
}
