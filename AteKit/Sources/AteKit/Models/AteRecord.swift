import Foundation

/// A row (or view row) we read from PostgREST.
///
/// Every model names its own table and its own explicit column list — we never `select("*")`.
/// Two reasons that matters here:
///  1. `restaurants.location` is a PostGIS `geography` column and comes back as a hex EWKB blob
///     (`"0101000020E6100000…"`) — useless to the client and pure payload weight.
///  2. An explicit list makes an additive server change (a new column) a no-op for the client, and
///     a *removed* column a loud, immediate 400 in the contract tests rather than a silent nil.
public protocol AteRecord: Decodable, Sendable, Identifiable {
    /// The table or view name in the `public` schema.
    static var table: String { get }
    /// The comma-separated PostgREST `select` list for this record.
    static var columns: String { get }
    /// The column a by-id lookup filters on. Tables use `id`; the stats *views* key on their
    /// subject (`dish_stats.dish_id`), which is why this is on the protocol rather than assumed.
    static var primaryKeyColumn: String { get }
}

extension AteRecord {
    public static var primaryKeyColumn: String { "id" }
}

/// A record that can be walked with the `(created_at, id)` keyset cursor (data-model §5).
///
/// Conformance is a promise about the *table*: it must expose both `created_at` and `id`, and the
/// natural read order is newest-first. Stats views deliberately do NOT conform — they are keyed
/// lookups, not streams.
public protocol KeysetPaginated: AteRecord {
    /// The cursor pointing *at* this row; the next page starts strictly after it.
    var pageCursor: PageCursor { get }
}
