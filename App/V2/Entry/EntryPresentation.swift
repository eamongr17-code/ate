import AteKit
import SwiftUI

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
            // still waiting, not printed. A place with nothing on it is an entry with nothing
            // scored: its words and photos, with no receipt and no retry that could change that.
            guard card.place != nil else { return .pending }
            guard card.items.isEmpty == false else { return .unscored }
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
            locality: card.place?.locality,
            items: card.items.map {
                AteReceipt.Item(
                    id: $0.reviewID, name: $0.dishName, score: $0.score,
                    dishID: $0.dishID, isSaved: $0.saved
                )
            },
            orderNumber: card.orderNumber,
            date: card.createdAt,
            handle: card.author?.username ?? handle,
            companions: card.companions.map(\.username)
        )
    }

    /// The page's dish rows: the same rows a slip draws, from the same fields.
    /// Your own entry never shows the codes your diet put on a dish; everyone else's does.
    static func dishes(for card: EntryCard) -> [AteSlip.Dish] {
        card.items.map {
            AteSlip.Dish(
                id: $0.reviewID, dishID: $0.dishID, name: $0.dishName,
                score: $0.score, isSaved: $0.saved, tags: $0.shownTags(isMine: card.isMine)
            )
        }
    }
}
