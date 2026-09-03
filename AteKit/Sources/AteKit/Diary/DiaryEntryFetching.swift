import Foundation

/// The one read the entry view needs that the diary's *pages* can't answer: a single review by id.
///
/// **Why it is a separate protocol from ``DiaryReading``.** The entry view is normally resolved with
/// no network at all — the ``FeedEntry`` is already on the diary's loaded page, so pushing an entry
/// is instant and cannot fail. This exists only for the other door: an entry reached from outside the
/// diary (a deep link, a restored navigation path, a page that has since been discarded), where the
/// screen has an id and nothing else. Keeping it off ``DiaryReading`` means the paging store is not
/// obliged to grow a by-id cache it would never use.
///
/// Row-level RLS is the access control: `reviews_select_all` makes every review readable, so this
/// deliberately does **not** filter on `reviewer_id`. The entry view is only ever *reached* with your
/// own review's id; scoping the query would turn a routing mistake into a silent "not found" instead
/// of something a crash report can explain.
public protocol DiaryEntryFetching: Sendable {
    /// The review, with its dish/restaurant/author display strings embedded — the same shape a diary
    /// page row has, so the entry view has exactly one model to render.
    ///
    /// Throws ``AteAPIError/notFound`` when no such review exists (or RLS hides it).
    func diaryEntry(reviewID: UUID) async throws -> FeedEntry
}

/// The PostgREST-backed single-entry read. A type of its own rather than an extension on
/// ``DiaryClient``: nothing about the two reads is shared beyond the API client, and separating them
/// keeps the paging client's surface exactly "one page of your reviews".
public struct DiaryEntryClient: DiaryEntryFetching {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func diaryEntry(reviewID: UUID) async throws -> FeedEntry {
        guard let entry = try await api.findRow(FeedEntry.self, matching: { query in
            query.eq("id", value: reviewID.uuidString.lowercased())
        }) else {
            throw AteAPIError.notFound(table: FeedEntry.table, id: reviewID)
        }
        return entry
    }
}
