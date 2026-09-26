import AteKit
import Observation
import SwiftUI

/// The entry page's state: the row, what the bill says, and which correction sheet is open.
@MainActor
@Observable
final class EntryModel: SavedDishObserving {
    /// What the bill on the page is doing.
    enum State: Equatable {
        /// The words are saved; the structure has not arrived. A designed state, not a spinner
        /// (`docs/DESIGN.md`, "Not drawn": words show, the bill absent).
        case pending
        /// The sorter could not finish. One retry, in the design's vocabulary.
        case failed
        case printed(AteReceipt)
    }

    /// Which line is being re-named, if any.
    struct Correcting: Identifiable, Equatable {
        let item: AteReceipt.Item
        var id: UUID { item.id }
    }

    /// What `Share` is about — `Identifiable` so it can present a cover.
    struct Sharing: Identifiable, Equatable {
        let artefact: ShareArtefact
        var id: UUID { artefact.entryID ?? UUID() }
    }

    private(set) var card: EntryCard?
    private(set) var composition = EntryComposition()
    private(set) var photos: [AtePhoto] = []
    private(set) var state: State = .pending
    var isCorrectingPlace = false
    var correcting: Correcting?
    /// A report, block or correction that did not happen, said once (``ActionFailure``).
    var failure: ActionFailure?
    /// Why the entry could not be shown, when it could not — and only while there is nothing on
    /// the page: a refresh that fails under a loaded entry leaves the entry where it is.
    private(set) var loadFailure: LoadFailure?
    /// The "…" menu's Delete, asking first.
    var isConfirmingDelete = false
    /// The delete did not go through. The entry is still here, and says so.
    var deleteFailed = false
    private(set) var isDeleting = false
    /// Non-nil presents `Share` — the coral screen the receipt actually leaves from.
    var sharing: Sharing?

    private let route: EntryRoute
    private let services: AteServices
    private let saves: SaveAction
    private var handle = ""
    private var hasReportedPrint = false

    init(route: EntryRoute, services: AteServices, saves: SaveAction) {
        self.route = route
        self.services = services
        self.saves = saves
        #if DEBUG
        // Not before the entry has loaded: the sheet opens on the place it is correcting, and one
        // opened against a card that is not there yet shows "Recent" instead of "Best match".
        #endif
    }

    // MARK: - Loading

    func load() async {
        handle = await services.entries.currentHandle() ?? handle
        await reload()
        // An entry that arrived here unsorted keeps asking, quietly, until it is: the person was
        // told their words were saved, and the receipt is the other half of that.
        if card?.sortStatus == .pending, state != .failed { await waitForSort() }
    }

    func reload() async {
        do {
            let card = try await services.entries.entry(id: route.entryID)
            loadFailure = nil
            apply(card, isStuck: await services.outbox.isStuck(entryID: route.entryID))
        } catch is CancellationError {
            return
        } catch {
            if card == nil { loadFailure = LoadFailure(error) }
        }
    }

    /// "Try again" on a page that could not reach Ate.
    func retryLoad() async {
        loadFailure = nil
        await load()
    }

    /// Polls for the receipt while the sorter works. The app asked for the sort itself when the
    /// entry was saved, so this is watching rather than driving — and it gives up rather than
    /// hammering, leaving the retry in the person's hands.
    private func waitForSort() async {
        for _ in 0..<Self.sortPollCount {
            try? await Task.sleep(for: Self.sortPollInterval)
            guard Task.isCancelled == false else { return }
            guard let card = try? await services.entries.entry(id: route.entryID) else { continue }
            apply(card)
            if card.sortStatus != .pending { return }
        }
    }

    private static let sortPollInterval = Duration.milliseconds(700)
    private static let sortPollCount = 12

    private func apply(_ card: EntryCard, isStuck: Bool = false) {
        #if DEBUG
        let isFirstRead = self.card == nil
        #endif
        self.card = card
        // The words as written — a place named in them is plain text (ComposerPlaceB).
        composition = EntryPresentation.composition(for: card)
        // Named by address, so a redraw (a bookmark, a correction) never reloads a photo.
        photos = EntrySlipPresentation.viewerPhotos(card)
        state = EntryPresentation.state(for: card, handle: handle)
        // An entry the outbox has given up on is not "still printing" — it is not printed, and it
        // needs the one thing that can change that: somebody asking again.
        if isStuck, case .pending = state { state = .failed }
        guard case .printed(let receipt) = state else { return }
        report(receipt)
        #if DEBUG
        if ComposerDebugLaunch.opensDishSheet, correcting == nil, let first = receipt.items.first {
            correcting = Correcting(item: first)
        }
        if ComposerDebugLaunch.opensPlaceSheet, isFirstRead {
            isCorrectingPlace = true
        }
        if ComposerDebugLaunch.opensShare, sharing == nil {
            share()
        }
        #endif
    }

    private func report(_ receipt: AteReceipt) {
        guard hasReportedPrint == false else { return }
        hasReportedPrint = true
        services.analytics(EntryEvents.receiptPrinted(
            itemCount: receipt.items.count,
            hasAverage: receipt.average != nil
        ))
    }

    /// The receipt, when there is one: the dish rows as line items, plus everything only the artefact
    /// prints (the order number, the handle, the barcode). The share button is off until it exists —
    /// a receipt is the only thing this screen has to share, and the page itself is not one.
    var receipt: AteReceipt? {
        if case .printed(let receipt) = state { return receipt }
        return nil
    }

    /// The page's dish rows — the card's own, tags and bookmarks and all.
    var dishes: [AteSlip.Dish] {
        guard let card else { return [] }
        return EntryPresentation.dishes(for: card)
    }

    /// A dish row asked for its correction: ``DishSheet`` opens on the line it came from.
    func correct(_ dish: AteSlip.Dish) {
        guard let item = receipt?.items.first(where: { $0.id == dish.id }) else { return }
        correcting = Correcting(item: item)
    }

    // MARK: - Actions

    /// Opens `Share` — the coral screen the artefact is approved on and sent from. `receipt_shared`
    /// fires there, at the tap that actually sends it: looking at a receipt is not sharing one.
    func share() {
        guard let artefact = shareArtefact() else { return }
        sharing = Sharing(artefact: artefact)
    }

    /// The share card's subject, built from this entry's own row so the artefact and the page can
    /// never disagree about what was eaten. `nil` while the bill has not printed — there is nothing
    /// to send yet, and a blank page is not an artefact.
    func shareArtefact() -> ShareArtefact? {
        guard let receipt, let card else { return nil }
        return .entry(receipt, photos: card.photos.compactMap { URL(string: $0.url) })
    }

    /// "Print it again". Two different failures wear the same button: an entry that never reached
    /// the server (the outbox gave up on it) and one that reached it and could not be sorted.
    func retrySort() async {
        state = .pending
        if await services.outbox.isStuck(entryID: route.entryID) {
            await services.outbox.retry(entryID: route.entryID)
        } else {
            _ = try? await services.entries.sort(entryID: route.entryID, force: true)
        }
        await reload()
    }

    // MARK: - Somebody else's entry

    /// Whose entry this is. Your own gets the pencil and the globe; anybody else's gets a byline and
    /// bookmarks. One row, two readings (`docs/DESIGN.md`, "Not drawn").
    var isMine: Bool { card?.isMine ?? true }

    /// The byline on somebody else's entry — their avatar, their handle, and how long ago.
    var byline: AteByline? {
        guard let card, card.isMine == false, let author = card.author else { return nil }
        return AteByline(
            userID: author.id,
            handle: author.username,
            age: RelativeAge.short(card.createdAt)
        )
    }

    /// True when every line of this entry is already on the shelf — what the top bar's bookmark
    /// reads. An entry with no lines is never "saved": there is nothing to have saved.
    var isEveryDishSaved: Bool { card?.isEveryDishSaved ?? false }

    /// One line's bookmark. A save is one dish, wherever it is tapped — and the page hears about
    /// it the same way the feed underneath it does, through the broadcast.
    func toggleSave(dish: AteSlip.Dish) async {
        guard let card else { return }
        await saves.toggle(dishID: dish.dishID, entryID: card.id, isSaved: dish.isSaved, source: .entry)
    }

    /// The bookmark in the top bar: every dish on this visit, at once — `save_entry_dishes`, which
    /// is the same thing "Save this place" does on the actions sheet.
    func toggleSaveEveryDish() async {
        guard let card, card.items.isEmpty == false else { return }
        let dishIDs = card.items.map(\.dishID)
        if card.isEveryDishSaved {
            await saves.unsaveEveryDish(dishIDs: dishIDs, source: .entry)
        } else {
            await saves.saveEveryDish(entryID: card.id, dishIDs: dishIDs, source: .entry)
        }
    }

    /// The bookmark changed somewhere — here, or on a list this page was opened from.
    func savedDishChanged(dishID: UUID, isSaved: Bool) {
        applySaved(dishID: dishID, to: isSaved)
    }

    // MARK: - Delete

    /// Your own entry, gone: the server first, then the journal, the feed and any open profile
    /// (``EntryDeletions``), then `entry_deleted`. Returns whether it went, so the page pops only
    /// when there is nothing left to show.
    func delete() async -> Bool {
        guard let card, card.isMine, isDeleting == false else { return false }
        isDeleting = true
        defer { isDeleting = false }
        let deleter = EntryDeleter(
            entries: services.entries,
            deletions: services.entryDeletions,
            analytics: services.analytics,
            outbox: services.outbox
        )
        guard await deleter.delete(card) else {
            deleteFailed = true
            return false
        }
        return true
    }

    /// Report this entry. The author is reported from their profile; this is about the words.
    @discardableResult
    func report() async -> Bool {
        do {
            try await services.profiles.report(entryID: route.entryID, reason: nil, note: nil)
            services.analytics(SocialEvents.entryReported())
            return true
        } catch {
            failure = .report
            return false
        }
    }

    /// Block this entry's author. Returns their id so the caller can empty the lists behind it.
    func blockAuthor() async -> UUID? {
        guard let card, card.isMine == false else { return nil }
        do {
            try await services.profiles.block(userID: card.authorID)
            services.analytics(SocialEvents.userBlocked())
            return card.authorID
        } catch {
            failure = .block
            return nil
        }
    }

    /// Writes a bookmark into the row this page is drawn from, so the bill and the top bar agree
    /// with every other list before the server answers.
    private func applySaved(dishID: UUID, to isSaved: Bool) {
        guard let card else { return }
        let updated = card.settingSaved(dishID: dishID, to: isSaved)
        self.card = updated
        state = EntryPresentation.state(for: updated, handle: handle)
    }

    /// The receipt's header: `correct_entry_place`. Re-resolves every line at the new place — or
    /// prints the parked plan, if the entry had none.
    func correctPlace(_ place: PlaceRef) async {
        isCorrectingPlace = false
        guard let id = place.id else { return }
        services.analytics(EntryEvents.corrected(.place))
        guard let updated = try? await services.entries.correctPlace(
            entryID: route.entryID, restaurantID: id
        ) else {
            failure = .correctPlace
            return
        }
        apply(updated)
    }

    /// A line item: `correct_entry_dish`. A menu pick passes the id, "Add as a new dish" the name.
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async {
        correcting = nil
        services.analytics(EntryEvents.corrected(.dish))
        do {
            try await services.entries.correctDish(reviewID: reviewID, dishID: dishID, dishName: dishName)
        } catch {
            failure = .correctDish
        }
        await reload()
    }
}

/// Turning a row into the things the design draws. Pure and free of the network, so what the entry
/// page shows for a given row can be reasoned about — and tested — without one.
enum EntryPresentation {
    /// The words with their tokens back in them.
    ///
    /// The scores come from the **receipt lines**, not from a re-parse of the prose: the server has
    /// already decided which numbers in the body were scores, and guessing again on the client would
    /// be a second opinion about somebody's own words. Where each one *sits* is
    /// ``EntryBodyTokens``, which is in AteKit because a price that looks like a score is a bug you
    /// want a test for, not a screenshot.
    static func composition(for card: EntryCard) -> EntryComposition {
        EntryBodyTokens.composition(for: card)
    }

    static func state(for card: EntryCard, handle: String) -> EntryModel.State {
        switch card.sortStatus {
        case .pending:
            return .pending
        case .failed:
            return .failed
        case .sorted:
            // **An empty receipt is never printed or shared.** A placeless entry sorts to no lines —
            // its plan is parked until a place is attached, which the place line does — so it is
            // still waiting, not printed. A place with nothing on it is the sorter finding no dish
            // it could stand behind: the retry is the honest answer.
            guard card.place != nil else { return .pending }
            guard card.items.isEmpty == false else { return .failed }
            return .printed(receipt(for: card, handle: handle))
        }
    }

    /// The receipt a sorted entry prints: **dish rows and scores only** — never a note under a line
    /// (Eamon, 2026-09-26). A place never attached prints no header rather than a guess.
    static func receipt(for card: EntryCard, handle: String) -> AteReceipt {
        AteReceipt(
            id: card.id,
            place: card.place?.name ?? "",
            placeID: card.place?.id,
            address: card.place?.address,
            items: card.items.map {
                AteReceipt.Item(
                    id: $0.reviewID, name: $0.dishName, score: $0.score,
                    dishID: $0.dishID, isSaved: $0.saved
                )
            },
            orderNumber: card.orderNumber,
            date: card.createdAt,
            handle: card.author?.username ?? handle
        )
    }

    /// The page's dish rows: the same rows a slip draws, from the same fields.
    static func dishes(for card: EntryCard) -> [AteSlip.Dish] {
        card.items.map {
            AteSlip.Dish(
                id: $0.reviewID, dishID: $0.dishID, name: $0.dishName,
                score: $0.score, isSaved: $0.saved, tags: $0.tags
            )
        }
    }
}
