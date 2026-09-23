import Foundation
import Supabase

/// **The feed read**, as one seam: everyone else's public entries, newest first, keyset-paged.
///
/// Separate from ``EntryService`` on purpose — that protocol is the loop that writes an entry, and
/// the feed only ever reads. A protocol so the store's paging, dedup and state logic is testable
/// without a network, and so `-ate-preview-data` can drive the whole screen with no backend.
public protocol EntryFeedReading: Sendable {
    /// One page of the global feed.
    ///
    /// - Parameter includeOwn: `false` (the contract's own default) — your own visits live in the
    ///   journal, and a feed that shows them back to you is the journal with a byline on it.
    ///
    /// Throws ``AteAPIError/notAuthenticated`` when nobody is signed in rather than returning the
    /// empty page RLS would hand back: "signed out" and "nobody has written anything" are different
    /// screens and must never render as the same one.
    func feedPage(after cursor: PageCursor?, pageSize: Int, includeOwn: Bool) async throws -> Page<EntryCard>
}

public extension EntryFeedReading {
    func feedPage(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        try await feedPage(after: cursor, pageSize: pageSize, includeOwn: false)
    }
}

/// The live feed: `get_entry_feed(p_cursor_created_at, p_cursor_id, p_page_size, p_include_own)`.
///
/// Blocked people are already gone — the block filter lives once, in `blocked_with()`, and applies
/// inside the view (data-model §RLS). The client never filters anyone out itself; it refetches.
public struct EntryFeedClient: EntryFeedReading {
    /// The server clamps `get_entry_feed` at 50 (`least(greatest(p_page_size,1),50)`); asking for
    /// more would come back short and make `isLastPage` lie.
    public static let maximumPageSize = 50

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func feedPage(
        after cursor: PageCursor?,
        pageSize: Int,
        includeOwn: Bool
    ) async throws -> Page<EntryCard> {
        try await api.requireCurrentUserID()
        let limit = min(Self.maximumPageSize, max(1, pageSize))
        var parameters: [String: AnyJSON] = [
            "p_page_size": .integer(limit),
            "p_include_own": .bool(includeOwn)
        ]
        // First page → nulls. Next page → the LAST row's `created_at` AND `id` (contract, Reads).
        parameters["p_cursor_created_at"] = cursor
            .map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null
        parameters["p_cursor_id"] = cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null

        let data = try await api.supabase
            .rpc("get_entry_feed", params: parameters)
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
        return Page(items: rows, requestedLimit: limit)
    }
}
