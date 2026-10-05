import AteKit
import SwiftUI

/// **The Journal tab's stores**, made by its router the first time the tab is shown: your entries
/// and the count of photos waiting to be written up.
@MainActor
struct JournalStores {
    let journal: JournalStore
    let photos: JournalPhotoCount

    init(services: AteServices) {
        journal = JournalStore(
            entries: services.entries,
            deletions: services.entryDeletions,
            querying: services.journalQuerying
        )
        photos = JournalPhotoCount(services: services)
    }
}

/// **How many recent meals are waiting to be written up** — the coral count on the Journal's photos
/// control. It reads the camera roll only when it has already been allowed: the ask belongs to From
/// your photos, never to a launch. A sitting dismissed there is gone from the count too, for good.
@MainActor
@Observable
final class JournalPhotoCount {
    private(set) var count = 0

    @ObservationIgnored private let services: AteServices

    init(services: AteServices) {
        self.services = services
    }

    func load() async {
        guard services.photos.isAuthorized else {
            count = 0
            return
        }
        let dismissals = PhotoSuggestionDismissals(store: UserDefaultsStore(), owner: services.photoOwner)
        count = dismissals.count(await services.photos.recent())
    }
}
