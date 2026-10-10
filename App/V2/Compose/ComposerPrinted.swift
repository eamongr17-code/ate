import AteKit
import SwiftUI

/// **Printed** — the composer's second face, inside the same sheet: the new entry's receipt on the
/// coral ground, lying straight, the photos clear above it, centred in the room between the corner
/// row and the foot. Close is the glass disc top left; Share, the only action, is the ink pill at the
/// foot (live once the receipt has printed; "Print it again" when a print could not finish).
///
/// The rules are the current Summary's (``EntrySummaryStore``), with build 87's speed change: the
/// face comes up the moment the words are saved, and the receipt enters once — fed out of the printer
/// at once as paper with skeleton lines (the order number, the place and the date are the server's
/// own, already read) — and the sorted lines print onto that same paper when the sort's reply lands.
/// Never an empty coral sheet; never a dish name the server has not confirmed. An empty receipt is
/// never printed or shared: a placeless entry keeps its skeleton with the Place key where the place
/// prints, and picking one prints it. A print that could not finish offers "Print it again".
struct V2ComposerPrinted: View {
    /// What the writing face hands over once the words are accepted.
    struct Handoff {
        let card: EntryCard
        /// The composer's staged photos — the entry's own are still uploading; these are the same
        /// pictures, already in memory.
        let photos: [AtePhoto]
        /// "Ate with": the handles on the With key — the signature line prints them before the
        /// entry's own row has its companions back.
        var companions: [String] = []
        /// The sort's own answer, heard as it lands.
        let sorted: Latch<EntryCard?>?
        /// The chips and 6s it was sorted with, so "Print it again" re-sorts with the same ones.
        let tagTokens: [TagToken]
        let sixTokens: [TagToken]
        /// The tap on Post, for `summary_receipt_entered`'s `ms_from_done`.
        var doneAt: ContinuousClock.Instant = .now
        /// An early sort of exactly these inputs was out (or landed) before Done.
        var cacheHit = false
    }

    let app: AppModel
    let handoff: Handoff

    @State private var store: EntrySummaryStore
    @State private var isSharing = false
    @State private var isPickingPlace = false
    @State private var appearedAt = ContinuousClock.now
    @State private var hasCountedEntrance = false
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
            AteSheetHeader(title: nil) { done() }
            // The photos and the receipt, centred in the room between the corners and the foot (a
            // long one scrolls).
            GeometryReader { room in
                ScrollView {
                    stage
                        .padding(.vertical, AteMetrics.section)
                        .frame(maxWidth: .infinity, minHeight: room.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            V2PrintedFoot(pill: foot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateAccentGround(AteColor.coral)
        // The sort's own reply first (it carries the card); the store's re-reads only if it never
        // comes — nothing polls while the reply is on its way.
        .task {
            await hear()
            await store.watch()
        }
        .task(id: store.phase == .printed) { await askForPhotosOnce() }
        .onChange(of: store.card) { _, card in NotificationCenter.ateEntryChanged(card) }
        .onChange(of: store.showsReceipt, initial: true) { _, shows in countEntrance(shows) }
        .onDisappear { countDone() }
        .sheet(isPresented: $isSharing, onDismiss: { store.shareEnded() }) {
            V2ReceiptShareSheet(
                receipt: receipt, photos: handoff.photos, source: .summary, analytics: services.analytics
            )
        }
        .v2PlaceSheet(isPresented: $isPickingPlace, directory: services.places) { place in
            guard let id = place.id else { return }
            isPickingPlace = false
            services.analytics(EntryEvents.placeAttached(source: .picked))
            Task { await store.attachPlace(id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary")
    }

    /// The receipt — on the paper from the first frame: its skeleton lines while it sorts, waits for
    /// a place, or could not finish; the printed lines, in place, once the sort lands.
    private var stage: some View {
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
    }

    /// The one action, at the foot: Share — off while there is nothing to send — or, when a print
    /// could not finish, "Print it again".
    private var foot: V2PrintedFoot.Pill {
        if store.phase == .stalled {
            return V2PrintedFoot.Pill(title: "Print it again", isEnabled: store.isBusy == false,
                                      identifier: "summary.reprint") {
                Task { await store.reprint() }
            }
        }
        return V2PrintedFoot.Pill(
            title: "Share",
            isEnabled: store.phase == .printed && store.isSharing == false,
            identifier: "summary.share",
            action: send
        )
    }

    /// Dish rows and scores only, never a note.
    private var receipt: AteReceipt {
        let handle = app.handle ?? store.card.author?.username ?? ""
        var receipt = EntryPresentation.receipt(for: store.card, handle: handle)
        if receipt.companions.isEmpty { receipt.companions = handoff.companions }
        return receipt
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
        isSharing = true
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
            waitMilliseconds: printedOnArrival ? 0 : PostHold.milliseconds(since: appearedAt),
            millisecondsFromDone: PostHold.milliseconds(since: handoff.doneAt),
            cacheHit: handoff.cacheHit
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
            isPresentingOther: store.isSharing || isSharing || isPickingPlace
        )
    }
}

/// **The printed receipt's foot** — the kit's ink pill, full width on the sheet gutter, pinned above
/// the home indicator by the sheet foot's own geometry. Nothing under it.
struct V2PrintedFoot: View {
    struct Pill {
        let title: String
        var isEnabled = true
        let identifier: String
        let action: () -> Void
    }

    let pill: Pill

    var body: some View {
        AteInkPill(title: pill.title, isEnabled: pill.isEnabled, identifier: pill.identifier, action: pill.action)
            .environment(\.atePalette, .automatic)
            .padding(.horizontal, SheetHeaderGeometry.gutter)
            .padding(.top, AteSheetScaffoldMetrics.footTop)
            .padding(.bottom, AteSheetScaffoldMetrics.footBottom)
    }
}

enum V2PrintedTiming {
    /// How long the sort's own reply is waited on before the store's re-reads take over: past the
    /// server's 5s model timeout, its ≤3s wait on a running preview, and a slow network.
    static let patience: Duration = .seconds(12)
}
