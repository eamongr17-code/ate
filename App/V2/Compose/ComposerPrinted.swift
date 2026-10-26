import AteKit
import SwiftUI
import UIKit

/// **Printed** — the composer's second face, inside the same sheet: the ink share sheet
/// (``V2ShareSheet``, 11 Oct, approved), with the new entry's receipt printing on its sticker card.
/// The story and post cards and the row of ways out come live once the receipt has printed —
/// nothing opens before a person can share (Eamon, 10 Oct) — or "Try again" takes the row's
/// place when a receipt could not finish. No close: the sheet goes down by its handle.
///
/// **A wait that is not short says so** (receipt fallback, 18 Oct, approved): slow past 8s, unfinished,
/// or never sent (offline), the row's place holds a line saying the entry is saved and the sheet can
/// be closed — the receipt finishes in the background, and prints here if it lands while open.
///
/// The rules are the current Summary's (``EntrySummaryStore``), with build 87's speed change: the
/// face comes up the moment the words are saved, and the receipt enters once — fed out of the printer
/// at once as paper with skeleton lines (the order number, the place and the date are the server's
/// own, already read) — and the sorted lines print onto that same paper when the sort's reply lands.
/// Never an empty coral sheet; never a dish name the server has not confirmed. An empty receipt is
/// never printed or shared: a placeless entry keeps its skeleton with the Place key where the place
/// prints, and picking one prints it. A receipt that could not finish offers "Try again".
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
        /// The entry's landing finished — photos up, sorted, and matched to its dishes (or the match
        /// failed or was skipped): which photo is which dish can be read.
        var matched: Latch<Bool>?
        /// The chips and 6s it was sorted with, so "Try again" re-sorts with the same ones.
        let tagTokens: [TagToken]
        let scoreTokens: [TagToken]?
        /// …and the diet codes turned off per dish.
        var dietOffTokens: [DietOffToken] = []
        /// The tap on Post, for `summary_receipt_entered`'s `ms_from_done`.
        var doneAt: ContinuousClock.Instant = .now
        /// An early sort of exactly these inputs was out (or landed) before Done.
        var cacheHit = false
        /// The words went to the outbox, not the server: the card is the local stand-in.
        var isQueued = false
    }

    let app: AppModel
    let handoff: Handoff

    @State private var store: EntrySummaryStore
    /// One of the row's sheets is up (the system sheet, Messages).
    @State private var isSharing = false
    @State private var isPickingPlace = false
    /// The dish name tapped on the receipt, being fixed in "Which dish?".
    @State private var fixing: EntryModel.Correcting?
    @State private var appearedAt = ContinuousClock.now
    @State private var hasCountedEntrance = false
    /// The photos as pixels, by position, for the share cards.
    @State private var photos: [Int: UIImage] = [:]
    /// Each dish's own photos, once the match has answered (several dishes only).
    @State private var dishPhotos: [UUID: [Int]] = [:]
    @State private var photoLoaded = false
    /// The wait has run past ``ReceiptFallback/slowAfter``.
    @State private var isSlow = false
    /// The fallback lines already counted on this screen.
    @State private var countedFallbacks: Set<ReceiptFallback> = []
    /// The receipt was whole the moment the face came up (the tick's dots covered the sort).
    private let printedOnArrival: Bool

    init(app: AppModel, handoff: Handoff) {
        self.app = app
        self.handoff = handoff
        let store = EntrySummaryStore(
            card: handoff.card,
            isQueued: handoff.isQueued,
            actions: .live(
                app.services.entries, tagTokens: handoff.tagTokens, scoreTokens: handoff.scoreTokens,
                dietOffTokens: handoff.dietOffTokens
            )
        )
        _store = State(initialValue: store)
        printedOnArrival = store.showsReceipt
    }

    private var services: AteServices { app.services }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: AteMetrics.section)
            V2ShareSheet(
                receipt: receipt,
                photos: photos,
                dishPhotos: dishPhotos,
                opensOn: .sticker,
                source: .summary,
                isLive: store.phase == .printed && photoLoaded,
                printing: V2ShareSheet.Printing(
                    isPrinting: store.phase != .printed,
                    breathes: store.phase == .sorting && store.isQueued == false,
                    onAddPlace: store.phase == .needsPlace && store.isBusy == false
                        ? { isPickingPlace = true } : nil,
                    onFixDish: store.phase == .printed ? { item in
                        guard store.isBusy == false, isSharing == false else { return }
                        fixing = EntryModel.Correcting(item: item)
                    } : nil,
                    enters: true
                ),
                reprint: store.phase == .stalled && fallback?.offersRetry != false ? V2PrintedFoot.Pill(
                    title: ReceiptFallback.retryTitle, isEnabled: store.isBusy == false, identifier: "summary.reprint"
                ) {
                    Task { await store.reprint() }
                } : nil,
                note: fallback?.message,
                analytics: services.analytics,
                onFirstShare: send,
                isPresenting: $isSharing
            )
            .accessibilityIdentifier("summary.receipt")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(AteColor.ink)
        .task {
            photos = await SharePhotos.images(
                handoff.photos.enumerated().map { (position: $0.offset, photo: $0.element) }
            )
            photoLoaded = true
        }
        .task(id: store.phase == .printed) { await readDishPhotos() }
        // The sort's own reply first (it carries the card); the store's re-reads only if it never
        // comes — nothing polls while the reply is on its way.
        .task {
            await hear()
            await store.watch()
        }
        .task(id: store.phase == .printed) { await askOnce() }
        .task {
            try? await Task.sleep(for: ReceiptFallback.slowAfter)
            withAnimation(AteMotion.fillIn) { isSlow = true }
        }
        // The background finished something (the outbox, on a connection back or a foreground):
        // a receipt still waiting here takes it.
        .onChange(of: app.outboxLanded) { _, _ in Task { await store.recheck() } }
        .onChange(of: fallback, initial: true) { _, kind in countFallback(kind) }
        .onChange(of: store.card) { _, card in NotificationCenter.ateEntryChanged(card) }
        .onChange(of: store.showsReceipt, initial: true) { _, shows in countEntrance(shows) }
        .onDisappear { countDone() }
        .v2PlaceSheet(
            isPresented: $isPickingPlace, directory: services.places, nearby: services.nearbyPlaces
        ) { place in
            guard let id = place.id else { return }
            isPickingPlace = false
            services.analytics(EntryEvents.placeAttached(source: .picked))
            Task { await store.attachPlace(id) }
        }
        .v2DishSheet(
            item: $fixing,
            directory: services.places,
            placeID: { store.card.place?.id },
            placeName: { store.card.place?.name },
            onPick: { item, dishID, dishName in fix(item, dishID: dishID, dishName: dishName) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary")
    }

    /// The line in the row's place, while the receipt is slow, unfinished or never sent.
    private var fallback: ReceiptFallback? {
        ReceiptFallback.on(store.phase, isQueued: store.isQueued, isSlow: isSlow)
    }

    private func countFallback(_ kind: ReceiptFallback?) {
        guard let kind, countedFallbacks.contains(kind) == false else { return }
        countedFallbacks.insert(kind)
        services.analytics(EntryEvents.receiptFallbackShown(kind, surface: "summary"))
    }

    /// Dish rows and scores only, never a note.
    private var receipt: AteReceipt {
        let handle = app.handle ?? store.card.author?.username ?? ""
        var receipt = EntryPresentation.receipt(for: store.card, handle: handle)
        if receipt.companions.isEmpty { receipt.companions = handoff.companions }
        return receipt
    }

    /// **Which photo is which dish**, for a review of several. The match runs once the photos are up
    /// and the lines sorted, a few seconds after the receipt prints. Until it answers, each dish is a
    /// sticker only and the whole receipt takes the photos; the dishes' stories and posts join when it
    /// lands (26 Oct, Eamon: one photo went on all three dishes). Read once, when the entry's landing
    /// has finished; a receipt sorted again by "Try again" was never matched, so it is asked once.
    private func readDishPhotos() async {
        guard store.phase == .printed, store.isQueued == false, handoff.photos.isEmpty == false,
              store.card.items.count > 1 else { return }
        let entries = services.entries
        let entryID = store.card.id
        let printedAt = ContinuousClock.now
        let landed = await handoff.matched?.value(before: .now + V2PrintedTiming.matchPatience) != nil
        guard Task.isCancelled == false else { return }
        var pairs = await readPairs(entryID)
        if let read = pairs, read.isPaired == false, read.hasPhotos {
            await entries.matchPhotosIfNeverMatched(entryID: entryID)
            guard Task.isCancelled == false else { return }
            pairs = await readPairs(entryID) ?? pairs
        }
        if let pairs { dishPhotos = pairs.positions }
        services.analytics(EntryEvents.sharePhotoPairs(
            outcome: pairs.map { $0.isPaired ? "paired" : "none" } ?? "failed",
            landed: landed,
            milliseconds: PostHold.milliseconds(since: printedAt)
        ))
    }

    private struct Pairs {
        let positions: [UUID: [Int]]
        let isPaired: Bool
        let hasPhotos: Bool
    }

    private func readPairs(_ entryID: UUID) async -> Pairs? {
        guard let card = try? await services.entries.entry(id: entryID),
              let tags = try? await services.entries.photoDishTags(entryID: entryID) else { return nil }
        let positions = SharePhotoPairs.positions(
            reviewIDs: card.items.map(\.reviewID), photos: card.photos, tags: tags
        )
        return Pairs(
            positions: positions,
            isPaired: positions.values.contains { $0.isEmpty == false },
            hasPhotos: card.photos.isEmpty == false
        )
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

    /// A name fixed from the receipt: the same `correct_entry_dish` as the entry page's long press,
    /// and the line reprints in place.
    private func fix(_ item: AteReceipt.Item, dishID: UUID?, dishName: String?) {
        fixing = nil
        services.analytics(EntryEvents.corrected(.dish))
        Task {
            if await store.correctDish(reviewID: item.id, dishID: dishID, dishName: dishName) == false {
                AteHaptics.refused()
            }
        }
    }

    /// `summary_shared`, once per screen: the first disc tapped.
    private func send() {
        guard let event = store.share() else { return }
        services.analytics(event)
        store.shareEnded()
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

    /// **One system prompt per receipt**: once a receipt has printed and settled, the camera roll's,
    /// once; on a later receipt, notifications', once, so a friend's "ate with" can reach this phone
    /// (someone tagged who never tagged anyone or opened Notifications was otherwise never asked).
    /// Never over the share sheet or the place sheet.
    private func askOnce() async {
        let library = services.photos
        guard shouldAsk(canAsk: true) else { return }
        try? await Task.sleep(for: PhotoAccessAsk.delay)
        guard Task.isCancelled == false else { return }
        if shouldAsk(canAsk: library.canAsk) {
            let granted = await library.requestAuthorization()
            services.analytics(SuggestionEvents.photoAccessAsked(granted: granted))
            if granted { NotificationCenter.default.post(name: .atePhotoAccessGranted, object: nil) }
        } else if app.hasSession, shouldAsk(canAsk: true) {
            await AtePush.shared.askOnce(trigger: .receipt, services: services)
        }
    }

    private func shouldAsk(canAsk: Bool) -> Bool {
        PhotoAccessAsk.shouldAsk(
            canAsk: canAsk,
            isPrinted: store.phase == .printed,
            isPresentingOther: isSharing || isPickingPlace
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
    /// How long the entry's landing (photos up, sort, match) is waited on before which photo is which
    /// dish is read anyway: the uploads, the sort's patience and the match's own model call.
    static let matchPatience: Duration = .seconds(45)
}
