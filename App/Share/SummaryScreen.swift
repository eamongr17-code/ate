import AteKit
import SwiftUI

/// **The Summary** — what follows Post in the composer (`SummaryFinal`, 2026-09-26). The entry's
/// receipt is the hero on the coral ground, and Share sends it — the existing share path, the same
/// picture the Share screen sends.
///
/// **Round 5: the receipt enters once, whole.** "Posting…" held while the sorter worked
/// (``PostHold``); when the sort answered inside it, the receipt enters with the screen. When it did
/// not, the coral ground stands with its two pills and the band empty — no skeleton, no word — and
/// the receipt enters the moment its shape is final (``EntrySummaryStore/showsReceipt``).
///
/// **An empty receipt is never printed or shared** (``EntrySummaryStore``). An entry with no place
/// sorts to no lines — its plan is parked — so its receipt keeps the skeleton and puts the Place key
/// where the place prints; picking one attaches it (`correct_entry_place`), the parked plan prints,
/// and Share comes on. A print that could not finish offers "Print it again". Done is always there.
///
/// Done lands on the Journal, with the new entry at the top of it.
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
    /// The row as it lands — sorted, a place attached — so the journal slip under this screen is
    /// the printed entry by the time Done returns to it.
    var onUpdated: (EntryCard) -> Void = { _ in }

    /// The composer's latch: the sort's own answer, heard as it lands rather than at the next poll.
    let sorted: Latch<EntryCard?>?
    /// The receipt was whole the moment the screen came up ("Posting…" covered the sort).
    private let printedOnArrival: Bool
    /// The camera roll, for the one quiet ask (``PhotoAccessAsk``). `nil` asks nothing.
    let photoLibrary: (any AtePhotoLibrary)?

    @State private var sender = ShareSender()
    @State private var isPickingPlace = false
    /// When the screen came up, for how long the band stood empty.
    @State private var appearedAt = ContinuousClock.now
    @State private var hasCountedEntrance = false

    init(
        card: EntryCard,
        photos: [AtePhoto],
        handle: String,
        actions: EntrySummaryStore.Actions,
        sorted: Latch<EntryCard?>? = nil,
        photoLibrary: (any AtePhotoLibrary)? = nil,
        places: any PlaceDirectory,
        analytics: @escaping AnalyticsRecorder,
        onDone: @escaping () -> Void,
        onUpdated: @escaping (EntryCard) -> Void = { _ in }
    ) {
        let store = EntrySummaryStore(card: card, actions: actions)
        _store = State(initialValue: store)
        printedOnArrival = store.showsReceipt
        self.sorted = sorted
        self.photoLibrary = photoLibrary
        self.photos = photos
        self.handle = handle
        self.places = places
        self.analytics = analytics
        self.onDone = onDone
        self.onUpdated = onUpdated
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
            onPrimary: primaryAction,
            isHero: true,
            showsCard: store.showsReceipt
        )
        .task { await store.watch() }
        .task { await hear() }
        .task(id: store.phase == .printed) { await askForPhotosOnce() }
        .onChange(of: store.card) { _, card in onUpdated(card) }
        .onChange(of: store.showsReceipt, initial: true) { _, shows in countEntrance(shows) }
        .sheet(item: $sender.sending, onDismiss: { store.shareEnded() }, content: { sending in
            ShareSheet(sending: sending) { destination in
                analytics(EntryEvents.receiptShared(
                    entryID: store.card.id, source: destination == .instagramStories ? .instagramStories : .summary
                ))
            }
        })
        // The composer's own sheet — the same action looks and works the same everywhere.
        .atePlaceSheet(isPresented: $isPickingPlace, directory: places) { place in
            // The sheet only ever hands back a resolved row (`PlaceSheet`'s "Use …" waits).
            guard let id = place.id else { return }
            isPickingPlace = false
            analytics(EntryEvents.placeAttached(source: .picked))
            Task { await store.attachPlace(id) }
        }
        // A container, so the pills keep their own identifiers under it.
        .accessibilityElement(children: .contain)
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

    /// The sort's answer from the composer's latch — the same one the hold waited on.
    private func hear() async {
        guard let sorted, store.phase == .sorting else { return }
        guard let landed = await sorted.value(before: .now + Self.patience) else { return }
        if let card = landed {
            store.adopt(card)
        } else {
            // The sort itself failed: "Print it again" now, not after a poll's patience.
            store.sortFailed()
        }
    }

    /// **The one ask for the camera roll** (round 5): someone who was never asked would never see
    /// "From your photos", which only appears when there is something to suggest. So once a receipt
    /// has printed and settled, the system's own prompt comes up, once, with its purpose string and
    /// nothing of ours. Granted, the journal's photo-stack button appears when the Summary closes;
    /// refused, it stays hidden, and nothing asks again.
    ///
    /// Never over something else: while the share sheet or the place sheet is up the ask is not
    /// made at all, and waits for a later post rather than jumping in when the sheet goes.
    private func askForPhotosOnce() async {
        guard let photoLibrary, shouldAsk(photoLibrary) else { return }
        try? await Task.sleep(for: PhotoAccessAsk.delay)
        guard Task.isCancelled == false, shouldAsk(photoLibrary) else { return }
        let granted = await photoLibrary.requestAuthorization()
        analytics(SuggestionEvents.photoAccessAsked(granted: granted))
        if granted { NotificationCenter.default.post(name: .atePhotoAccessGranted, object: nil) }
    }

    private func shouldAsk(_ library: any AtePhotoLibrary) -> Bool {
        PhotoAccessAsk.shouldAsk(
            canAsk: library.canAsk,
            isPrinted: store.phase == .printed,
            isPresentingOther: store.isSharing || sender.sending != nil || isPickingPlace
        )
    }

    /// As long as the store itself watches (30 polls of 0.7s).
    private static let patience: Duration = .seconds(21)

    /// `summary_receipt_entered`, once: how long the band stood empty before the receipt came.
    private func countEntrance(_ shows: Bool) {
        guard shows, hasCountedEntrance == false, store.phase == .printed else { return }
        hasCountedEntrance = true
        analytics(EntryEvents.summaryReceiptEntered(
            entryID: store.card.id,
            waitMilliseconds: printedOnArrival ? 0 : PostHold.milliseconds(since: appearedAt)
        ))
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
        sender.send(artefact: artefact, photos: Array(photos.prefix(2)))
        // A render that produced nothing opens no sheet — Share is live again at once.
        if sender.sending == nil { store.shareEnded() }
    }
}
