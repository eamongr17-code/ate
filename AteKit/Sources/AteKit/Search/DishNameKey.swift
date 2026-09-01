import Foundation

/// The client-side dish identity key — the ported "search existing before you create" rule.
///
/// **Provenance.** The legacy TypeScript client is gone from this repo's history (the reboot commit
/// `4c0e6b9` carried over only `supabase/`), so this is ported from the surviving authority the
/// legacy code was written against: the schema itself. `dishes_identity_uq` is
/// `(restaurant_id, lower(name)) WHERE merged_into_dish_id IS NULL` (migration 0002) — dish identity
/// is **per-restaurant, case-insensitive, live-rows-only**.
///
/// **Why the client key is deliberately LOOSER than the index.** Postgres compares `lower(name)`
/// verbatim, so `"Pad Thai"` and `"Pad  Thai"` are two different live dishes to the DB. To a person
/// typing into the picker they are the same dish, and the legacy build's dedup normalised whitespace
/// for exactly that reason. Being looser is the safe direction:
///  - it only ever makes us *offer create less often* and *resolve to an existing row more often*;
///  - resolving to an existing row is always a legal outcome (§6.3: a name collision must silently
///    become the existing dish, never an "already exists" error);
///  - the inverse (a stricter client key) would push duplicate-looking dishes into the catalogue.
///
/// Whitespace is the only extra folding. No punctuation stripping, no diacritic folding: `"Marg's"`
/// vs `"Margs"` is a *merge* concern (server-side `merge_dish` + `merged_into_dish_id`), and §11.4 is
/// explicit that near-duplicates are not blocked client-side.
public struct DishNameKey: Hashable, Sendable, CustomStringConvertible {
    /// The normalised form: trimmed, internal whitespace collapsed to single spaces, lowercased.
    public let value: String

    public init(_ raw: String) {
        self.value = DishNameKey.normalize(raw)
    }

    /// Trim → collapse internal whitespace runs → lowercase.
    ///
    /// `lowercased()` (not `lowercased(with:)`) on purpose: Postgres `lower()` runs under the
    /// database collation, not the user's device locale. A Turkish-locale device must not decide
    /// that `"I"` and `"i"` are different dishes.
    public static func normalize(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// A name that is only whitespace can't identify anything — callers must not offer to create it.
    public var isEmpty: Bool { value.isEmpty }

    public var description: String { value }
}

/// The create-fallback gate and collision resolution for dishes (spec §11.4, §6.3).
///
/// Pure functions over an already-loaded candidate set. The network half (select-then-insert) lives
/// in ``DishSearchService`` and calls straight through to these, so the rule has exactly one spelling.
public enum DishDedup {
    /// Minimum query length before "Add '<query>' as a new dish" may appear (§11.4).
    public static let minimumCreateQueryLength = 2

    /// The live dish whose name collides with `name` under ``DishNameKey``, or nil.
    ///
    /// Tombstoned rows (`merged_into_dish_id != nil`) are skipped: the unique index excludes them,
    /// so a merged-away "Brisket" must not stop a live "Brisket" from being found — and must never
    /// be handed back as the resolution target. A caller that lands on a tombstone anyway should go
    /// through ``Dish/canonicalDishID``.
    public static func match(name: String, in dishes: some Sequence<Dish>) -> Dish? {
        let key = DishNameKey(name)
        guard !key.isEmpty else { return nil }
        return dishes.first { !$0.isTombstoned && DishNameKey($0.name) == key }
    }

    /// §11.4: the "Add '<query>' as a new dish" row appears only when the query is ≥2 characters
    /// AND nothing already loaded here matches it. Never above real results — that's the view's job.
    public static func shouldOfferCreate(query: String, in dishes: some Sequence<Dish>) -> Bool {
        let key = DishNameKey(query)
        guard key.value.count >= minimumCreateQueryLength else { return false }
        return match(name: query, in: dishes) == nil
    }

    /// The same gate, over names alone — what the view has once dishes have become row models.
    /// Because the filtered list is a server `ilike '%query%'`, any exact-name match is guaranteed
    /// to be inside it, so checking the rendered rows is sufficient (and needs no extra round-trip).
    public static func shouldOfferCreate(query: String, existingNames: some Sequence<String>) -> Bool {
        let key = DishNameKey(query)
        guard key.value.count >= minimumCreateQueryLength else { return false }
        return !existingNames.contains { DishNameKey($0) == key }
    }

    /// Whether two names are the same dish to a human filling in the picker.
    public static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
        let key = DishNameKey(lhs)
        return !key.isEmpty && key == DishNameKey(rhs)
    }
}
