import Foundation
import Observation

/// All the feed's behaviour — paging, dedup, refresh, and which state the screen is in — as one
/// `@Observable` the view merely renders. The view owns no logic beyond layout, and every rule
/// below is exercised by `FeedStoreTests` against a stubbed ``FeedReading``.
@MainActor
@Observable
public final class FeedStore {

    /// What the screen shows *instead of* content. Content is `entries`; this is the rest.
    public enum Phase: Sendable, Equatable {
        /// First load in flight — the view shows redacted placeholder rows, not a spinner.
        case loading
        /// At least one entry is loaded.
        case ready
        /// Loaded successfully, and nobody has posted anything.
        case empty
        /// No session. RLS hands `anon` a successful empty page, so without this the signed-out
        /// user would be told "no reviews yet" — a lie, and the bug ``AteAPIError`` warns about.
        case signedOut
        /// First load failed with nothing on screen. Recoverable via ``retry()``.
        case failed(message: String)
    }

    /// How close to the end of the list a row must be to trigger the next page.
    private static let prefetchDistance = 5

    // MARK: - Observable state

    public private(set) var entries: [FeedEntry] = []
    public private(set) var phase: Phase = .loading
    /// A page-load or refresh failed while content was already on screen. Shown inline near the
    /// content — never as an alert, which would interrupt scrolling to report a recoverable miss.
    public private(set) var inlineErrorMessage: String?
    public private(set) var isLoadingMore = false
    /// True once the stream is exhausted — the list stops asking and hides its footer.
    public private(set) var hasReachedEnd = false

    // MARK: - Private state

    private let client: any FeedReading
    private let analytics: any FeedAnalyticsReporting
    private let pageSize: Int
    private var nextCursor: PageCursor?
    /// Membership index for O(1) dedup. Two pages can overlap when a review is deleted mid-scroll
    /// and the keyset shifts; a repeated id must be dropped, never rendered twice (SwiftUI would
    /// also warn about duplicate `Identifiable` ids and drop rows unpredictably).
    private var seenIDs: Set<UUID> = []
    private var loadedPageCount = 0
    private var hasLoadedOnce = false
    /// Bumped on every refresh so a slow in-flight page can't append itself onto a fresher list.
    private var generation = 0
    private var isLoadingFirstPage = false

    public init(
        client: any FeedReading,
        analytics: any FeedAnalyticsReporting = NoOpFeedAnalytics(),
        pageSize: Int = PageRequest.defaultLimit
    ) {
        self.client = client
        self.analytics = analytics
        self.pageSize = pageSize
    }

    // MARK: - Loading

    /// The `.task` entry point: loads once and stays quiet on every later appearance, so switching
    /// tabs doesn't refetch and doesn't jump the scroll position.
    public func loadFirstPageIfNeeded() async {
        guard !hasLoadedOnce else { return }
        await loadFirstPage()
    }

    /// Pull-to-refresh, and the retry affordance on the error state. Existing entries stay on
    /// screen until the new first page arrives, so a refresh never flashes an empty list.
    public func refresh() async {
        await loadFirstPage()
    }

    /// Explicit retry from the failed/signed-out state.
    public func retry() async {
        await loadFirstPage()
    }

    /// Called as rows appear. Fires the next page once the visible row is within
    /// ``prefetchDistance`` of the end — the infinite-scroll trigger.
    public func loadMoreIfNeeded(after entry: FeedEntry) async {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        guard index >= entries.count - Self.prefetchDistance else { return }
        await loadMore()
    }

    /// The next page. Safe to call spuriously: it no-ops while one is in flight, at the end of the
    /// stream, or before the first page has landed.
    public func loadMore() async {
        guard !isLoadingMore, !isLoadingFirstPage, !hasReachedEnd, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let generationAtStart = generation
        do {
            let page = try await client.feedPage(PageRequest(limit: pageSize, after: cursor))
            guard generationAtStart == generation else { return }  // a refresh overtook us
            append(page)
            inlineErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            // Content is on screen; a failed *next* page is a footnote, not a takeover.
            inlineErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    // MARK: - Machinery

    private func loadFirstPage() async {
        guard !isLoadingFirstPage else { return }
        isLoadingFirstPage = true
        generation += 1
        let generationAtStart = generation
        defer { isLoadingFirstPage = false }

        if entries.isEmpty { phase = .loading }

        do {
            let page = try await client.feedPage(PageRequest(limit: pageSize))
            guard generationAtStart == generation else { return }
            hasLoadedOnce = true
            reset()
            append(page)
            phase = entries.isEmpty ? .empty : .ready
            inlineErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            hasLoadedOnce = true
            if entries.isEmpty {
                phase = Self.isNotAuthenticated(error)
                    ? .signedOut
                    : .failed(message: Self.userFacingMessage(for: error))
            } else if Self.isNotAuthenticated(error) {
                // Signed out mid-session: the stale list is no longer ours to show.
                reset()
                phase = .signedOut
            } else {
                inlineErrorMessage = Self.userFacingMessage(for: error)
            }
        }
    }

    private func reset() {
        entries = []
        seenIDs = []
        nextCursor = nil
        loadedPageCount = 0
        hasReachedEnd = false
    }

    private func append(_ page: Page<FeedEntry>) {
        let fresh = page.items.filter { seenIDs.insert($0.id).inserted }
        entries.append(contentsOf: fresh)
        nextCursor = page.nextCursor
        hasReachedEnd = page.isLastPage
        loadedPageCount += 1
        analytics.feedPageLoaded(page: loadedPageCount, itemCount: fresh.count)
    }

    // MARK: - Interaction

    /// Records the tap. Navigation itself is a pushed ``DishRoute`` value in the view — this only
    /// exists so the position (what people actually tap: top of feed vs page four) is measurable.
    public func recordTap(on entry: FeedEntry) {
        let position = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
        analytics.feedDishTapped(dishID: entry.dishRoute.dishID, position: position)
    }

    public func recordFeedViewed() {
        analytics.feedViewed()
    }

    // MARK: - Errors

    static func isNotAuthenticated(_ error: any Error) -> Bool {
        (error as? AteAPIError) == .notAuthenticated
    }

    /// One short, human sentence. Never the raw error: a PostgREST 400 body or a URLError code is
    /// noise to the reader and belongs in Sentry, which already has it.
    static func userFacingMessage(for error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "You're offline."
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "Couldn't reach Ate. Check your connection."
            default:
                return "Couldn't load the feed."
            }
        }
        if Self.isNotAuthenticated(error) { return "Sign in to see the feed." }
        return "Couldn't load the feed."
    }
}
