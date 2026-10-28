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
            querying: services.journalQuerying,
            cache: services.pageCache("journal")
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
    /// When the camera roll was last read — every return to the Journal asks, and a Back within
    /// ``freshFor`` of the last read is not worth another pass through Photos.
    @ObservationIgnored private var readAt: Date?
    private static let freshFor: TimeInterval = 30
    /// Which read is the latest: an older one finishing after it is dropped.
    @ObservationIgnored private var reads = 0

    init(services: AteServices) {
        self.services = services
    }

    /// `force`: something changed what the count is (access granted, photos written up) — read now.
    func load(force: Bool = false) async {
        guard services.photos.isAuthorized else {
            count = 0
            return
        }
        if force == false, let readAt, Date().timeIntervalSince(readAt) < Self.freshFor { return }
        readAt = Date()
        reads += 1
        let read = reads
        let recent = await services.photos.recent()
        // A newer read (a post, a dismissal) started while this one classified the roll: its number
        // wins. And what was dismissed or posted is read after the roll, not before it — a sitting
        // written up during the read must not come back on the bell (Eamon, 28 Oct).
        guard read == reads else { return }
        let dismissals = PhotoSuggestionDismissals(store: UserDefaultsStore(), owner: services.photoOwner)
        count = dismissals.count(recent)
    }

    /// From your photos has just read the roll itself: its number is the newer one, and it counts as
    /// a fresh read.
    func settle(_ waiting: Int) {
        reads += 1
        count = max(0, waiting)
        readAt = Date()
    }
}
