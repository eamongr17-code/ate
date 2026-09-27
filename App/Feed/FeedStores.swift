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
            // The city (round 5) replaces the locality area: every page is read with the same one.
            let city = await area.city
            return try await reader.feedPage(
                after: cursor, pageSize: pageSize, includeOwn: false, area: nil, city: city
            )
        }
        list.listen(to: services.entryDeletions)
        return (list, area)
    }
}
