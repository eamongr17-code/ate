import Foundation

/// The read seam the feed is built on. A protocol so ``FeedStore`` — where the paging, dedup and
/// state logic lives — is testable without a network, and so a future cache/mock slots in without
/// touching the store.
public protocol FeedReading: Sendable {
    /// One page of the global feed, newest first.
    ///
    /// Throws ``AteAPIError/notAuthenticated`` when nobody is signed in, rather than returning the
    /// empty page RLS would otherwise hand back.
    func feedPage(_ request: PageRequest) async throws -> Page<FeedEntry>
}

extension FeedReading {
    /// The first page, default size.
    public func feedPage() async throws -> Page<FeedEntry> { try await feedPage(PageRequest()) }
}

/// The V1 feed: **every** review by **every** user, reverse-chronological, keyset-paginated.
///
/// **This deliberately does not call `get_feed()`.** That RPC is follow-scoped V3 infrastructure —
/// it joins `follows` and excludes the viewer's own posts, which for V1 (no social graph, PRODUCT.md)
/// would render an empty feed for every new account and hide your own review the moment you posted
/// it. V1 is a plain keyset-paginated select over `reviews`: own posts appear like anyone else's,
/// ordered `(created_at DESC, id DESC)` off the `reviews_created_idx` index.
///
/// The sign-in check is deliberate too, and is the single most important line here: RLS is
/// deny-by-default for `anon`, so a signed-out read succeeds with `[]`. Without this, "signed out"
/// and "nobody has posted yet" are the same screen — the empty-feed trap ``AteAPIError`` warns about.
public struct GlobalFeedClient: FeedReading {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func feedPage(_ request: PageRequest) async throws -> Page<FeedEntry> {
        try await api.requireCurrentUserID()
        return try await api.page(FeedEntry.self, request: request)
    }
}
