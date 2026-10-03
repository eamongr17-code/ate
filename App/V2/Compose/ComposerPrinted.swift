import AteKit
import SwiftUI

/// **Printed** — the composer's second face, inside the same sheet: the new entry's receipt on the
/// coral ground, lying straight, the photos clear above it. Close is the glass disc top left; Share,
/// the only action, the glass disc top right (live once the receipt has printed).
///
/// The rules are the current Summary's (``EntrySummaryStore``): the receipt enters once, whole —
/// fed out of the printer — and never changes shape after it is seen. An empty receipt is never
/// printed or shared: a placeless entry keeps its skeleton with the Place key where the place prints,
/// and picking one prints it. A print that could not finish offers "Print it again".
struct V2ComposerPrinted: View {
    /// What the writing face hands over once the words are accepted.
    struct Handoff {
        let card: EntryCard
        /// The composer's staged photos — the entry's own are still uploading; these are the same
        /// pictures, already in memory.
        let photos: [AtePhoto]
        /// The sort's own answer, heard as it lands.
        let sorted: Latch<EntryCard?>?
        /// The chips and 6s it was sorted with, so "Print it again" re-sorts with the same ones.
        let tagTokens: [TagToken]
        let sixTokens: [TagToken]
    }

    let app: AppModel
    let handoff: Handoff

    @State private var store: EntrySummaryStore
    @State private var sender = V2ReceiptSender()
    @State private var isPickingPlace = false
    @State private var appearedAt = ContinuousClock.now
    @State private var hasCountedEntrance = false
    /// Once the receipt is up it stays up — a reprint's sort keeps the skeleton rather than emptying
    /// the page.
    @State private var hasShownStage = false
    /// The receipt was whole the moment the face came up (the tick's dots covered the sort).
    private let printedOnArrival: Bool
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, handoff: Handoff) {
        self.app = app
        self.handoff = handoff
        let store = EntrySummaryStore(
            card: handoff.card,
            actions: .live(app.services.entries, tagTokens: handoff.tagTokens, sixTokens: handoff.sixTokens)
        )
        _store = State(initialValue: store)
        printedOnArrival = store.showsReceipt
    }

    private var services: AteServices { app.services }

    var body: some View {
        VStack(spacing: 0) {
            AteSheetHeader(title: nil, primary: share) { done() }
            // The photos and the receipt, centred in the room under the corners (a long one scrolls).
            GeometryReader { room in
                ScrollView {
                    stage
                        .padding(.vertical, AteMetrics.section)
                        .frame(maxWidth: .infinity, minHeight: room.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateAccentGround(AteColor.coral)
        .task { await store.watch() }
        .task { await hear() }
        .task(id: store.phase == .printed) { await askForPhotosOnce() }
        .onChange(of: store.card) { _, card in NotificationCenter.ateEntryChanged(card) }
        .onChange(of: store.showsReceipt, initial: true) { _, shows in countEntrance(shows) }
        .onDisappear { countDone() }
        .sheet(item: $sender.sending, onDismiss: { store.shareEnded() }, content: { sending in
            ShareSheet(sending: sending) { destination in
                services.analytics(EntryEvents.receiptShared(
                    entryID: store.card.id,
                    source: destination == .instagramStories ? .instagramStories : .summary
                ))
            }
        })
        .v2PlaceSheet(isPresented: $isPickingPlace, directory: services.places) { place in
            guard let id = place.id else { return }
            isPickingPlace = false
            services.analytics(EntryEvents.placeAttached(source: .picked))
            Task { await store.attachPlace(id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary")
    }

    /// The receipt — its skeleton while it sorts, waits for a place, or could not finish, with
    /// "Print it again" under it then.
    @ViewBuilder
    private var stage: some View {
        if hasShownStage || store.showsReceipt || store.phase == .stalled {
            VStack(spacing: AteMetrics.section) {
                AtePrintedReceiptStage(
                    receipt: receipt,
                    photos: Array(handoff.photos.prefix(2)),
                    isPrinting: store.phase != .printed,
                    breathes: store.phase == .sorting,
                    onAddPlace: store.phase == .needsPlace && store.isBusy == false
                        ? { isPickingPlace = true } : nil,
                    enters: true
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("summary.receipt")
                .onAppear { hasShownStage = true }
                if store.phase == .stalled {
                    AteInkPill(
                        title: "Print it again",
                        size: .empty,
                        isEnabled: store.isBusy == false,
                        identifier: "summary.reprint"
                    ) {
                        Task { await store.reprint() }
                    }
                    .environment(\.atePalette, .automatic)
                }
            }
        }
    }

    /// Share, top right — off while there is nothing to send.
    private var share: AteSheetPrimary {
        AteSheetPrimary(
            icon: .share,
            label: "Share",
            isEnabled: store.phase == .printed && store.isSharing == false,
            action: send
        )
    }

    /// Dish rows and scores only, never a note.
    private var receipt: AteReceipt {
        EntryPresentation.receipt(for: store.card, handle: app.handle ?? store.card.author?.username ?? "")
    }

    /// The sort's answer from the composer's latch — the one the tick's dots waited on.
    private func hear() async {
        guard let sorted = handoff.sorted, store.phase == .sorting else { return }
        guard let landed = await sorted.value(before: .now + V2PrintedTiming.patience) else { return }
        if let card = landed {
            store.adopt(card)
        } else {
            store.sortFailed()
        }
    }

    /// One `summary_shared` per sheet: the store refuses a second tap while one is up.
    private func send() {
        guard let event = store.share() else { return }
        services.analytics(event)
        sender.send(receipt, photos: Array(handoff.photos.prefix(2)))
        if sender.sending == nil { store.shareEnded() }
    }

    /// Close, top left — counted once, however the sheet goes.
    private func done() {
        countDone()
        dismiss()
    }

    private func countDone() {
        guard let event = store.done() else { return }
        services.analytics(event)
    }

    /// `summary_receipt_entered`, once: how long the band stood empty before the receipt came.
    private func countEntrance(_ shows: Bool) {
        guard shows, hasCountedEntrance == false, store.phase == .printed else { return }
        hasCountedEntrance = true
        services.analytics(EntryEvents.summaryReceiptEntered(
            entryID: store.card.id,
            waitMilliseconds: printedOnArrival ? 0 : PostHold.milliseconds(since: appearedAt)
        ))
    }

    /// **The one ask for the camera roll**: once a receipt has printed and settled, the system's own
    /// prompt, once — never over the share sheet or the place sheet.
    private func askForPhotosOnce() async {
        let library = services.photos
        guard shouldAsk(library) else { return }
        try? await Task.sleep(for: PhotoAccessAsk.delay)
        guard Task.isCancelled == false, shouldAsk(library) else { return }
        let granted = await library.requestAuthorization()
        services.analytics(SuggestionEvents.photoAccessAsked(granted: granted))
        if granted { NotificationCenter.default.post(name: .atePhotoAccessGranted, object: nil) }
    }

    private func shouldAsk(_ library: any AtePhotoLibrary) -> Bool {
        PhotoAccessAsk.shouldAsk(
            canAsk: library.canAsk,
            isPrinted: store.phase == .printed,
            isPresentingOther: store.isSharing || sender.sending != nil || isPickingPlace
        )
    }
}

/// **Render, and hand it to the system.** A render that fails opens nothing and is felt, never
/// written; the share is counted by the system sheet, when the picture actually leaves.
struct V2ReceiptSender {
    var sending: ShareSender.Sending?

    @MainActor
    mutating func send(_ receipt: AteReceipt, photos: [AtePhoto]) {
        guard let image = AtePrintedReceiptImage.render(receipt, photos: photos) else {
            AteHaptics.refused()
            return
        }
        sending = ShareSender.Sending(image: image, sticker: AtePrintedReceiptImage.sticker(receipt, photos: photos))
    }
}

enum V2PrintedTiming {
    /// As long as the store itself watches (30 polls of 0.7s).
    static let patience: Duration = .seconds(21)
}
