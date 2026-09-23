import Foundation
import Supabase

/// **Saving a dish** — the feed's one action (PRODUCT.md decision 7).
///
/// A save is always ONE dish. There is no "save this entry": an entry is somebody's visit, and what
/// you want back is the thing you would order. "Save this place" on the actions sheet is the same
/// action applied to every line of one entry, which is what `save_entry_dishes` does server-side.
public protocol DishSaving: Sendable {
    /// Idempotent; first provenance wins, so saving the same dish twice keeps the entry it came from.
    func save(dishID: UUID, sourceEntryID: UUID?) async throws
    func unsave(dishID: UUID) async throws
    /// Every line of an entry, provenance = that entry. Returns how many were saved.
    @discardableResult
    func saveEntryDishes(entryID: UUID) async throws -> Int
    /// The Saved shelf, keyset-paged on `(saved_at, dish_id)`.
    func savedDishesPage(after cursor: PageCursor?, pageSize: Int) async throws -> Page<SavedDish>
}

/// The live saves path: `save_dish` / `unsave_dish` / `save_entry_dishes`, and a plain select over
/// `my_saved_dishes` (which is already scoped to the caller by the view itself).
public struct SaveClient: DishSaving {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func save(dishID: UUID, sourceEntryID: UUID?) async throws {
        try await api.callRPC("save_dish", parameters: [
            "p_dish_id": .string(dishID.uuidString.lowercased()),
            "p_source_entry_id": sourceEntryID.map { .string($0.uuidString.lowercased()) } ?? .null
        ])
    }

    public func unsave(dishID: UUID) async throws {
        try await api.callRPC("unsave_dish", parameters: [
            "p_dish_id": .string(dishID.uuidString.lowercased())
        ])
    }

    @discardableResult
    public func saveEntryDishes(entryID: UUID) async throws -> Int {
        try await api.rpc("save_entry_dishes", parameters: [
            "p_entry_id": .string(entryID.uuidString.lowercased())
        ], decoding: Int.self)
    }

    /// **Ordered by when it was saved, newest first** — not by `restaurant_name` as the contract's
    /// example spells it.
    ///
    /// Two reasons, and both are the same reason: the list has to be pageable and the shelf is a
    /// shortlist. `(saved_at, dish_id)` is a total order the standard keyset cursor already walks,
    /// where `restaurant_name` needs a three-part cursor whose string half has to be quoted into a
    /// PostgREST `or=(…)` filter — an escaping problem waiting for a place with a comma in its name.
    /// And grouping is done on the client anyway, so the only thing the wire order decides is which
    /// place is at the top: the one you saved from last, which is the one you are still thinking
    /// about.
    public func savedDishesPage(after cursor: PageCursor?, pageSize: Int) async throws -> Page<SavedDish> {
        try await api.requireCurrentUserID()
        let limit = max(1, min(PageRequest.maximumLimit, pageSize))
        var query = api.supabase
            .from(SavedDish.table)
            .select(SavedDish.columns)
        if let cursor {
            query = query.or(cursor.olderThanFilter(timestampColumn: "saved_at", idColumn: "dish_id"))
        }
        let data = try await query
            .order("saved_at", ascending: false)
            .order("dish_id", ascending: false)
            .limit(limit)
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([SavedDish].self, from: data)
        return Page(items: rows, requestedLimit: limit)
    }
}
