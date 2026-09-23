import Foundation

public extension EntryCard {
    /// The card with this dish's bookmark flipped — what an optimistic save writes before the RPC
    /// answers, and what it writes back if the RPC refuses.
    ///
    /// Keyed on `dishID`, not on the review line, because a save is a save of the **dish**: the same
    /// dish can be a line on two entries in the same list, and both bookmarks have to agree.
    /// Returns `self` unchanged when nothing matches, so a list can map every row through this
    /// without minting new values for the rows it does not touch.
    func settingSaved(dishID: UUID, to isSaved: Bool) -> EntryCard {
        guard items.contains(where: { $0.dishID == dishID && $0.saved != isSaved }) else { return self }
        return replacing(items: items.map { item in
            guard item.dishID == dishID else { return item }
            return Item(
                reviewID: item.reviewID,
                dishID: item.dishID,
                dishName: item.dishName,
                score: item.score,
                note: item.note,
                position: item.position,
                saved: isSaved
            )
        })
    }

    /// Every line saved. What the top of someone else's entry and "Save this place" both ask about,
    /// and the reason an entry with no lines is never drawn as already-saved.
    var isEveryDishSaved: Bool {
        items.isEmpty == false && items.allSatisfy(\.saved)
    }
}
