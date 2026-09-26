import AteKit
import SwiftUI

/// **The Summary** — what follows Done in the composer (`SummaryLoading` → `SummaryFinal`,
/// 2026-09-26). The entry's receipt is the hero on the coral ground, printing while the sorter works:
/// the place, the photos, the order number and the date print at once; the lines are skeleton bars
/// with a slow breath, and no word says "printing". When the sort lands the receipt settles and
/// Share comes on — the existing share path, the same picture the Share screen sends.
///
/// **An empty receipt is never printed or shared** (``EntrySummaryStore``). An entry with no place
/// sorts to no lines — its plan is parked — so its receipt keeps the skeleton and puts the Place key
/// where the place prints; picking one attaches it (`correct_entry_place`), the parked plan prints,
/// and Share comes on. A print that could not finish offers "Print it again". Done is always there.
///
/// Done lands on the entry's own page, which the shell has already put under this screen.
struct SummaryScreen: View {
    @State private var store: EntrySummaryStore
    /// The composer's staged photos — the entry's own are still uploading, and these are the same
    /// pictures, already in memory.
    let photos: [AtePhoto]
    /// Who signs the receipt, until the row's own author is there to.
    let handle: String
    let places: any PlaceDirectory
    let analytics: AnalyticsRecorder
    let onDone: () -> Void

    @State private var sender = ShareSender()
    @State private var isPickingPlace = false

    init(
        card: EntryCard,
        photos: [AtePhoto],
        handle: String,
        actions: EntrySummaryStore.Actions,
        places: any PlaceDirectory,
        analytics: @escaping AnalyticsRecorder,
        onDone: @escaping () -> Void
    ) {
        _store = State(initialValue: EntrySummaryStore(card: card, actions: actions))
        self.photos = photos
        self.handle = handle
        self.places = places
        self.analytics = analytics
        self.onDone = onDone
    }

    var body: some View {
        ShareStage(
            artefact: artefact,
            photos: Array(photos.prefix(2)),
            isPrinting: store.phase != .printed,
            breathes: store.phase == .sorting,
            primary: primary,
            onAddPlace: store.phase == .needsPlace && store.isBusy == false ? { isPickingPlace = true } : nil,
            onDone: done,
            onPrimary: primaryAction
        )
        .task { await store.watch() }
        .sheet(item: $sender.sending, onDismiss: { store.shareEnded() }, content: { sending in
            ShareSheet(items: [sending.image])
        })
        .sheet(isPresented: $isPickingPlace) {
            // The composer's own sheet — the same action looks and works the same everywhere.
            PlaceSheet(directory: places) { place in
                isPickingPlace = false
                guard let id = place.id else { return }
                analytics(EntryEvents.placeAttached(source: .picked))
                Task { await store.attachPlace(id) }
            }
        }
        .accessibilityIdentifier("summary")
    }

    private var primary: ShareStage.Primary {
        switch store.phase {
        case .stalled: .reprint(isEnabled: store.isBusy == false)
        case .printed: .share(isEnabled: store.isSharing == false, didFail: sender.didFail)
        case .sorting, .needsPlace: .share(isEnabled: false, didFail: false)
        }
    }

    /// The row as a receipt — dish rows and scores only, never a note (Eamon, 2026-09-26).
    private var artefact: ShareArtefact {
        let receipt = EntryPresentation.receipt(for: store.card, handle: handle)
        return .entry(receipt, photos: store.card.photos.compactMap { URL(string: $0.url) })
    }

    /// Counted once, however many times it is tapped on the way out.
    private func done() {
        guard let event = store.done() else { return }
        analytics(event)
        onDone()
    }

    private func primaryAction() {
        switch store.phase {
        case .stalled:
            Task { await store.reprint() }
        case .printed:
            share()
        case .sorting, .needsPlace:
            break
        }
    }

    /// One `summary_shared` per sheet: the store refuses a second tap while one is up.
    private func share() {
        guard let event = store.share() else { return }
        analytics(event)
        sender.send(artefact: artefact, photos: Array(photos.prefix(2))) {
            analytics(EntryEvents.receiptShared(entryID: store.card.id, source: .summary))
        }
        // A render that produced nothing opens no sheet — Share is live again at once.
        if sender.sending == nil { store.shareEnded() }
    }
}
