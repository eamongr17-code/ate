import AteKit
import SwiftUI

/// **The Feed tab's stores**, made by its router the first time the tab is shown: the edition's
/// sections, the latest receipts, and the area they are about — the current Feed's three, wired the
/// same way (`FeedStores.swift`), with one change the contract makes (§6, Eamon 3 Oct):
///
/// - **It opens on your Journal's city**, not near me: someone who has never picked reads the city
///   their own entries are mostly in (else the busiest city with food), and nobody is asked for
///   their location on open.
/// - **Location is asked for only on Near me** (``FeedRoot``'s area menu); once picked, near me is
///   remembered and read from the phone on later visits.
@MainActor
struct V2FeedStores {
    let edition: FeedEditionStore
    let latest: EntryListStore
    let area: FeedAreaModel
    /// The one location path the app has — asked from the Near me pick and nowhere else.
    let locator: AteLocation

    init(services: AteServices) {
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
        let journal = services.journalQuerying
        area.opening = { [weak area] in
            let mine = services.hasSession ? (try? await journal.myEntryCities()) ?? [] : []
            if mine.isEmpty == false {
                return FeedAreaModel.openingLocation(journalCities: mine, feedCities: [])
            }
            await area?.loadCitiesIfNeeded()
            return FeedAreaModel.openingLocation(journalCities: [], feedCities: area?.cities ?? [])
        }
        // A short run, not the feed: one page of the cap, never paged (round 8).
        let latest = EntryListStore(
            pageSize: FeedEditionStore.latestCap,
            fallbackMessage: "Couldn't load the feed.",
            savedDishes: services.savedDishes
        ) { cursor, pageSize in
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
            isSignedIn: { services.hasSession },
            city: { await area.cityForFirstPage() },
            analytics: services.analytics,
            savedDishes: services.savedDishes,
            preferences: services.preferences
        )
        let locator = AteLocation()
        // Read only on near me, which is only ever a pick: the opening never lands on it.
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
        self.edition = edition
        self.latest = latest
        self.area = area
        self.locator = locator
    }
}
