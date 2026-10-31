import Foundation
import PostgREST
import Supabase

/// The base API client every per-domain client is built on.
///
/// It owns three things and nothing else: **the session**, **typed reads** (single row, list, RPC),
/// and **keyset pagination**. Domain semantics (what a feed is, how a dish is created) belong in
/// the per-domain clients that wrap this one — this type must stay boring enough that they're all
/// thin.
///
/// **There is deliberately no `upsert` helper.** `dishes_identity_uq` is a *partial* unique index
/// (`WHERE merged_into_dish_id IS NULL`), and PostgREST's `on_conflict` can only target a TOTAL
/// unique constraint — pointing an upsert at it is what took dish logging down in 0014 (fixed in
/// 0016). Dish creation is select-then-insert: ``findRow(_:matching:)`` then ``insert(_:into:)``.
/// If a future call site wants an upsert, it should have to add it deliberately, next to a comment
/// explaining why that table's constraint is total.
public final class AteAPIClient: Sendable {
    /// Escape hatch for the seams this type doesn't cover yet (storage, realtime). Per-domain
    /// clients should prefer the helpers below so pagination and column lists stay in one place.
    public let supabase: SupabaseClient

    public init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    public convenience init(environment: AteEnvironment) {
        self.init(supabase: SupabaseClientProvider.make(environment: environment))
    }

    // MARK: - Session

    /// The signed-in user's id, or nil. Cheap and synchronous — safe to read on the main actor for
    /// a "signed in?" check. May be stale/expired; use ``requireCurrentUserID()`` before a request.
    public var currentUserID: UUID? { supabase.auth.currentSession?.user.id }

    public var isSignedIn: Bool { currentUserID != nil }

    /// The current session, refreshing it if it has expired.
    public func session() async throws -> Session {
        try await supabase.auth.session
    }

    /// The signed-in user's id, refreshing the session first, throwing ``AteAPIError/notAuthenticated``
    /// rather than letting an anon request come back as a confusing empty page.
    @discardableResult
    public func requireCurrentUserID() async throws -> UUID {
        guard let session = try? await supabase.auth.session else { throw AteAPIError.notAuthenticated }
        return session.user.id
    }

    // MARK: - Reads

    /// Several rows by primary key, in one round trip. Missing ids are simply absent from the
    /// result — this is the "hydrate the stats for the dishes I just listed" call, where a partial
    /// answer is correct.
    public func fetchByIDs<Record: AteRecord>(_ type: Record.Type, ids: [UUID]) async throws -> [Record] {
        guard !ids.isEmpty else { return [] }
        return try await supabase
            .from(Record.table)
            .select(Record.columns)
            .in(Record.primaryKeyColumn, values: ids.map(\.uuidString))
            .execute()
            .value
    }

    /// The first row matching a refinement, or nil. This is the "select" half of the
    /// select-then-insert path that dish creation must use.
    public func findRow<Record: AteRecord>(
        _ type: Record.Type,
        matching refine: @Sendable (PostgrestFilterBuilder) -> PostgrestFilterBuilder
    ) async throws -> Record? {
        let rows: [Record] = try await refine(supabase.from(Record.table).select(Record.columns))
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    // MARK: - Keyset pagination (data-model §5)

    /// One page of a newest-first stream, ordered `(created_at DESC, id DESC)` and cut with the
    /// composite cursor — never OFFSET, which double-serves and drops rows as new reviews land
    /// mid-scroll.
    ///
    /// `refine` applies the scoping filters (`.eq("dish_id", …)`, `.eq("reviewer_id", …)`); the
    /// cursor, order and limit are added afterwards so a caller can't accidentally reorder the
    /// stream out from under the cursor.
    public func page<Record: KeysetPaginated>(
        _ type: Record.Type,
        request: PageRequest = PageRequest(),
        refine: @Sendable (PostgrestFilterBuilder) -> PostgrestFilterBuilder = { $0 }
    ) async throws -> Page<Record> {
        var query = refine(supabase.from(Record.table).select(Record.columns))
        if let cursor = request.cursor {
            query = query.or(cursor.olderThanFilter())
        }
        let items: [Record] = try await query
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(request.limit)
            .execute()
            .value
        return Page(items: items, requestedLimit: request.limit)
    }

    // MARK: - RPC

    /// A typed RPC call. Server-side functions are how every controlled write happens here
    /// (`add_manual_restaurant`, `merge_dish`, `deactivate_account`) — the tables themselves are
    /// deny-by-default for those paths.
    public func rpc<Response: Decodable & Sendable>(
        _ function: String,
        parameters: [String: AnyJSON] = [:],
        decoding: Response.Type = Response.self
    ) async throws -> Response {
        try await supabase.rpc(function, params: parameters).execute().value
    }

    /// An RPC whose return value we don't need.
    public func callRPC(_ function: String, parameters: [String: AnyJSON] = [:]) async throws {
        _ = try await supabase.rpc(function, params: parameters).execute()
    }

    // MARK: - Writes

    /// Insert one row and return it as decoded by the server (defaults, triggers and the
    /// denormalised `reviews.restaurant_id` are all server-set, so we read back rather than guess).
    ///
    /// See the type-level note: there is no upsert counterpart on purpose.
    public func insert<Payload: Encodable & Sendable, Record: AteRecord>(
        _ payload: Payload,
        into type: Record.Type
    ) async throws -> Record {
        try await supabase
            .from(Record.table)
            .insert(payload, returning: .representation)
            .select(Record.columns)
            .single()
            .execute()
            .value
    }
}
