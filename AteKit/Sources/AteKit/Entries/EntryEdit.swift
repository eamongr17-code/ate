import Foundation

/// **Saving an edit to an entry that already exists** — everything the composer's keys set, not
/// just the words.
///
/// Three steps, each only when it has something to do:
///
/// 1. **The words** — `entries.body`, the author's own hand.
/// 2. **The place**, when the Place key now holds a different one — `correct_entry_place`, which
///    re-resolves every line at it (and prints a parked plan).
/// 3. **The sort.** Tag chips typed during the edit go to a **forced** re-sort as `tag_tokens` —
///    the only way a chip reaches the server, and the database keeps every line's inherited tags
///    through it. With no new chips the sort is *not* forced: `apply_entry_sort` rebuilds every
///    line, and forcing it for a typo would throw away the dishes the person corrected by hand.
public struct EntryEdit: Sendable {
    public let entryID: UUID
    public let body: String
    /// The place the entry had when the composer opened on it.
    public let originalRestaurantID: UUID?
    /// The place on the Place key now.
    public let restaurantID: UUID?
    public let tagTokens: [TagToken]

    public init(entryID: UUID, body: String, originalRestaurantID: UUID?, restaurantID: UUID?, tagTokens: [TagToken]) {
        self.entryID = entryID
        self.body = body
        self.originalRestaurantID = originalRestaurantID
        self.restaurantID = restaurantID
        self.tagTokens = tagTokens
    }

    /// A place was picked that the entry does not already have. Clearing a place is not something
    /// the key does, so `nil` never counts as a change.
    public var changesPlace: Bool {
        guard let restaurantID else { return false }
        return restaurantID != originalRestaurantID
    }

    /// Steps one and two — the words, then the place — and the row as it now stands. The words are
    /// written first and alone; a failure there stops everything.
    public func saveWordsAndPlace(to entries: any EntryService) async throws -> EntryCard? {
        try await entries.updateBody(entryID: entryID, body: body)
        if changesPlace, let restaurantID {
            _ = try? await entries.correctPlace(entryID: entryID, restaurantID: restaurantID)
        }
        return try? await entries.entry(id: entryID)
    }

    /// Step three, after the composer has gone: forced with the chips, unforced without.
    public func sort(on entries: any EntryService) async {
        _ = try? await entries.sort(entryID: entryID, force: tagTokens.isEmpty == false, tagTokens: tagTokens)
    }
}
