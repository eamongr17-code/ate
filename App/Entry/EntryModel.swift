import AteKit
import Observation
import SwiftUI

/// The entry page's state: the row, what the receipt says, and which correction sheet is open.
@MainActor
@Observable
final class EntryModel {
    /// What the paper under the words is doing.
    enum State: Equatable {
        /// The words are saved; the structure has not arrived. A designed state, not a spinner
        /// (`docs/DESIGN.md`, "Not drawn": words show, receipt absent).
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

    private(set) var card: EntryCard?
    private(set) var composition = EntryComposition()
    private(set) var photos: [AtePhoto] = []
    private(set) var state: State = .pending
    /// Flips true once, on the first appearance after the receipt exists — the print-in.
    private(set) var hasPrinted = false
    var isCorrectingPlace = false
    var correcting: Correcting?
    var isSharing = false
    private(set) var shareImage: UIImage?

    private let route: EntryRoute
    private let services: AteServices
    private var handle = ""
    private var hasReportedPrint = false

    init(route: EntryRoute, services: AteServices) {
        self.route = route
        self.services = services
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
        guard let card = try? await services.entries.entry(id: route.entryID) else { return }
        apply(card, isStuck: await services.outbox.isStuck(entryID: route.entryID))
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
        let isFirstRead = self.card == nil
        self.card = card
        composition = EntryPresentation.composition(for: card)
        photos = card.photos.map { AtePhoto(url: URL(string: $0.url)) }
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
        #endif
        // The receipt prints in the first time it *arrives*: Done in the composer landed here, or
        // the sorter finished while the page was open. Opening an entry that was already sorted
        // shows a printed receipt, not a printing one — the theatre is the moment, not the screen.
        if isFirstRead && route.isFreshlyWritten == false {
            hasPrinted = true
        } else {
            withAnimation { hasPrinted = true }
        }
    }

    private func report(_ receipt: AteReceipt) {
        guard hasReportedPrint == false else { return }
        hasReportedPrint = true
        services.analytics(EntryEvents.receiptPrinted(
            itemCount: receipt.items.count,
            hasAverage: receipt.average != nil
        ))
    }

    /// The receipt, when there is one. The entry page's share button is off until there is — a
    /// receipt is the only thing this screen has to share.
    var receipt: AteReceipt? {
        if case .printed(let receipt) = state { return receipt }
        return nil
    }

    // MARK: - Actions

    /// Renders the receipt and opens the system share sheet. Rendered at the moment of sharing, from
    /// the same component the page draws, so the picture and the screen can never disagree.
    func share() {
        guard let receipt else { return }
        shareImage = ReceiptImage.render(receipt)
        guard shareImage != nil else { return }
        services.analytics(EntryEvents.receiptShared())
        isSharing = true
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

    func toggleVisibility() async {
        guard let card else { return }
        let next: EntryVisibility = card.visibility.isPublic ? .private : .public
        self.card = card.replacing(visibility: next)
        try? await services.entries.setVisibility(entryID: card.id, visibility: next)
        await reload()
    }

    /// The receipt's header: `correct_entry_place`. Re-resolves every line at the new place — or
    /// prints the parked plan, if the entry had none.
    func correctPlace(_ place: PlaceRef) async {
        isCorrectingPlace = false
        guard let id = place.id else { return }
        services.analytics(EntryEvents.corrected(.place))
        guard let updated = try? await services.entries.correctPlace(
            entryID: route.entryID, restaurantID: id
        ) else { return }
        apply(updated)
    }

    /// A line item: `correct_entry_dish`. A menu pick passes the id, "Add as a new dish" the name.
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async {
        correcting = nil
        services.analytics(EntryEvents.corrected(.dish))
        try? await services.entries.correctDish(
            reviewID: reviewID, dishID: dishID, dishName: dishName
        )
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
            guard let place = card.place else { return .pending }
            return .printed(AteReceipt(
                id: card.id,
                place: place.name,
                placeID: place.id,
                address: place.address,
                items: card.items.map {
                    AteReceipt.Item(id: $0.reviewID, name: $0.dishName, score: $0.score, note: $0.note)
                },
                orderNumber: card.orderNumber,
                date: card.createdAt,
                handle: card.author?.username ?? handle
            ))
        }
    }
}
