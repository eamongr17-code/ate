import Foundation

/// A position in a newest-first stream, per data-model §5: the cursor is the composite
/// `(created_at, id)`, never an OFFSET.
///
/// `created_at` alone is not a cursor — the staging seed alone has three reviews sharing a
/// timestamp to the microsecond, and a `created_at`-only cursor either loops on them or skips them.
/// The `id` tiebreak is what makes the page boundary total.
public struct PageCursor: Sendable, Hashable, Codable {
    public let createdAt: Date
    public let id: UUID

    public init(createdAt: Date, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }

    /// The PostgREST `or=(…)` predicate for "strictly older than this cursor" in a descending
    /// `(created_at, id)` order — the client-side spelling of the SQL row comparison
    /// `(created_at, id) < (:cursor_created_at, :cursor_id)` that `get_feed` uses server-side.
    ///
    /// PostgREST has no row-value syntax, so it expands to
    /// `created_at.lt.C, and(created_at.eq.C, id.lt.I)`.
    ///
    /// - Parameter column: qualified column name, in case a query aliases the timestamp.
    func olderThanFilter(timestampColumn column: String = "created_at", idColumn: String = "id") -> String {
        let timestamp = PostgRESTTimestamp.string(from: createdAt)
        return "\(column).lt.\(timestamp),and(\(column).eq.\(timestamp),\(idColumn).lt.\(id.uuidString.lowercased()))"
    }
}

/// What to ask for: a page size and where to start. `nil` cursor = the first page.
public struct PageRequest: Sendable, Hashable {
    /// Matches the server's own clamp on `get_feed(page_size)` — `least(greatest(n,1),100)`.
    public static let maximumLimit = 100
    public static let defaultLimit = 30

    public let limit: Int
    public let cursor: PageCursor?

    public init(limit: Int = PageRequest.defaultLimit, after cursor: PageCursor? = nil) {
        self.limit = min(Self.maximumLimit, max(1, limit))
        self.cursor = cursor
    }

    /// The request for the page after `page`, keeping the same size. `nil` once the stream is
    /// exhausted, so `while let` paging terminates.
    public func next(after page: Page<some KeysetPaginated>) -> PageRequest? {
        guard let cursor = page.nextCursor else { return nil }
        return PageRequest(limit: limit, after: cursor)
    }
}

/// One page of a keyset-paginated stream.
public struct Page<Element: KeysetPaginated>: Sendable {
    public let items: [Element]
    /// Cursor for the following page, or `nil` when this was the last page.
    ///
    /// "Last page" is inferred from a short read (`items.count < limit`). That can cost one extra
    /// empty request when the total is an exact multiple of the page size — the price of not
    /// paying for a `count=exact` on every query.
    public let nextCursor: PageCursor?

    public init(items: [Element], nextCursor: PageCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    public var isEmpty: Bool { items.isEmpty }
    public var isLastPage: Bool { nextCursor == nil }

    init(items: [Element], requestedLimit: Int) {
        self.items = items
        self.nextCursor = items.count < requestedLimit ? nil : items.last?.pageCursor
    }
}
