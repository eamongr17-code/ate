import Foundation

/// The read seam the diary is built on — a protocol so ``DiaryStore`` (paging, staleness, phases)
/// is testable without a network.
public protocol DiaryReading: Sendable {
    /// One page of the signed-in user's own reviews, newest first.
    ///
    /// Throws ``AteAPIError/notAuthenticated`` when nobody is signed in. That check is the whole
    /// difference between "you haven't logged anything" and "we don't know who you are": RLS is
    /// deny-by-default for `anon`, so a signed-out read *succeeds* with `[]` and would otherwise
    /// render the invitation empty state to a stranger.
    func diaryPage(_ request: PageRequest) async throws -> Page<FeedEntry>
}

extension DiaryReading {
    /// The first page, default size.
    public func diaryPage() async throws -> Page<FeedEntry> { try await diaryPage(PageRequest()) }
}

/// The diary: **your** reviews, reverse-chronological, keyset-paginated.
///
/// It is the global feed's query with one filter (`reviewer_id = auth.uid()`) and therefore reuses
/// ``FeedEntry`` wholesale rather than minting a parallel row type — the diary needs exactly the
/// same embedded display strings (dish name, restaurant name + suburb) through exactly the same
/// FK-hinted select. The author embed rides along unused; it costs one small object per row and
/// keeps a single decode path (and a single contract test) for "a review with its names".
///
/// The `reviewer_id` filter is belt-and-braces with RLS — `reviews_select_all` makes every review
/// readable, so this filter is what makes the query *the diary* rather than the feed. It is applied
/// through `page(_:request:refine:)`'s refine hook, so the cursor, order and limit are still added
/// by one place and can't be reordered out from under the keyset.
public struct DiaryClient: DiaryReading {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func diaryPage(_ request: PageRequest) async throws -> Page<FeedEntry> {
        let reviewerID = try await api.requireCurrentUserID().uuidString.lowercased()
        return try await api.page(FeedEntry.self, request: request) { query in
            query.eq("reviewer_id", value: reviewerID)
        }
    }
}
