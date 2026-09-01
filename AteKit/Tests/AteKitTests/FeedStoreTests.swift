import Foundation
import Testing

@testable import AteKit

// MARK: - Test doubles

/// A fake backend that pages exactly the way PostgREST does: total order on `(created_at, id)`
/// descending, cut by the keyset cursor. Testing the store against a *faithful* pager (rather than
/// a canned list of pages) is what makes "no dupes, no gaps across a timestamp tie" a real result.
private final class FakeFeed: FeedReading, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [FeedEntry]
    private var pendingError: (any Error)?
    private var persistentError: (any Error)?
    private var requests: [PageRequest] = []
    /// Extra rows served on top of the requested page, to simulate a keyset shift (a review
    /// deleted mid-scroll) re-serving a row we already have.
    private var overlapNextPageBy = 0

    init(rows: [FeedEntry]) {
        self.rows = rows
    }

    func feedPage(_ request: PageRequest) async throws -> Page<FeedEntry> {
        try lock.withLock {
            requests.append(request)
            if let error = pendingError {
                pendingError = nil
                throw error
            }
            if let persistentError { throw persistentError }

            let ordered = rows.sorted { lhs, rhs in
                if lhs.review.createdAt != rhs.review.createdAt {
                    return lhs.review.createdAt > rhs.review.createdAt
                }
                return lhs.id.uuidString > rhs.id.uuidString
            }
            var remaining = ordered
            if let cursor = request.cursor {
                let index = ordered.firstIndex { $0.id == cursor.id }
                remaining = index.map { Array(ordered[($0 + 1)...]) } ?? ordered
                if overlapNextPageBy > 0, let index {
                    let start = max(0, index + 1 - overlapNextPageBy)
                    remaining = Array(ordered[start...])
                }
            }
            return Page(items: Array(remaining.prefix(request.limit)), requestedLimit: request.limit)
        }
    }

    func failNextRequest(with error: any Error) { lock.withLock { pendingError = error } }
    func failEveryRequest(with error: any Error) { lock.withLock { persistentError = error } }
    func stopFailing() { lock.withLock { persistentError = nil; pendingError = nil } }
    func insert(_ entry: FeedEntry) { lock.withLock { rows.append(entry) } }
    func overlapPages(by count: Int) { lock.withLock { overlapNextPageBy = count } }
    var requestCount: Int { lock.withLock { requests.count } }
}

private final class RecordingAnalytics: FeedAnalyticsReporting, @unchecked Sendable {
    struct PageLoad: Equatable { let page: Int; let itemCount: Int }
    struct Tap: Equatable { let dishID: UUID; let position: Int }

    private let lock = NSLock()
    private var _views = 0
    private var _pages: [PageLoad] = []
    private var _taps: [Tap] = []

    func feedViewed() { lock.withLock { _views += 1 } }
    func feedPageLoaded(page: Int, itemCount: Int) {
        lock.withLock { _pages.append(PageLoad(page: page, itemCount: itemCount)) }
    }
    func feedDishTapped(dishID: UUID, position: Int) {
        lock.withLock { _taps.append(Tap(dishID: dishID, position: position)) }
    }

    var views: Int { lock.withLock { _views } }
    var pages: [PageLoad] { lock.withLock { _pages } }
    var taps: [Tap] { lock.withLock { _taps } }
}

// MARK: - Fixtures

private enum Fixture {
    static let epoch = Date(timeIntervalSince1970: 1_788_000_000)

    /// `count` entries newest-first, with every third row sharing a timestamp — the tie that a
    /// `created_at`-only cursor loops or skips on (the staging seed has nine such clusters).
    static func entries(count: Int) -> [FeedEntry] {
        (0..<count).map { index in
            entry(
                createdAt: epoch.addingTimeInterval(-Double(index / 3) * 3600),
                name: "Dish \(index)"
            )
        }
    }

    static func entry(
        id: UUID = UUID(),
        dishID: UUID = UUID(),
        mergedInto: UUID? = nil,
        createdAt: Date = epoch,
        name: String = "Cacio e Pepe",
        score: Double = 4.5
    ) -> FeedEntry {
        FeedEntry(
            review: Review(
                id: id,
                reviewerID: UUID(),
                dishID: dishID,
                restaurantID: UUID(),
                score: Rating(exactly: score)!,
                note: "Good.",
                createdAt: createdAt,
                updatedAt: createdAt
            ),
            dish: FeedEntry.DishSummary(id: dishID, name: name, mergedIntoDishID: mergedInto),
            restaurant: FeedEntry.RestaurantSummary(id: UUID(), name: "Tipo 00", city: "Melbourne"),
            author: FeedEntry.AuthorSummary(id: UUID(), username: "pastaindex", name: "Marco")
        )
    }
}

// MARK: - Tests

@Suite("Feed store")
@MainActor
struct FeedStoreTests {

    private func store(
        rows: [FeedEntry],
        pageSize: Int = 5,
        analytics: RecordingAnalytics = RecordingAnalytics()
    ) -> (FeedStore, FakeFeed, RecordingAnalytics) {
        let client = FakeFeed(rows: rows)
        return (FeedStore(client: client, analytics: analytics, pageSize: pageSize), client, analytics)
    }

    /// Drain the whole stream the way scrolling does.
    private func scrollToEnd(_ store: FeedStore) async {
        while !store.hasReachedEnd {
            let before = store.entries.count
            await store.loadMore()
            if store.entries.count == before { break }  // no progress: stop rather than spin
        }
    }

    @Test("paging walks every row exactly once, in order, across timestamp ties")
    func walksTheWholeStream() async {
        let (store, _, _) = store(rows: Fixture.entries(count: 46))

        await store.loadFirstPageIfNeeded()
        #expect(store.entries.count == 5)
        #expect(store.phase == .ready)

        await scrollToEnd(store)

        #expect(store.entries.count == 46)
        #expect(Set(store.entries.map(\.id)).count == 46)  // no row served twice
        #expect(store.hasReachedEnd)

        // Strictly descending on the composite key — the order the cursor relies on.
        for (newer, older) in zip(store.entries, store.entries.dropFirst()) {
            let descending = newer.review.createdAt > older.review.createdAt
                || (newer.review.createdAt == older.review.createdAt
                    && newer.id.uuidString > older.id.uuidString)
            #expect(descending)
        }
    }

    @Test("a row re-served after a keyset shift is dropped, not rendered twice")
    func deduplicatesOverlappingPages() async {
        let (store, client, _) = store(rows: Fixture.entries(count: 20))
        await store.loadFirstPageIfNeeded()
        client.overlapPages(by: 3)  // every later page repeats the previous three rows

        await scrollToEnd(store)

        #expect(store.entries.count == Set(store.entries.map(\.id)).count)
        #expect(store.entries.count == 20)
    }

    @Test("the end of the stream stops further requests")
    func stopsAtTheEnd() async {
        let (store, client, _) = store(rows: Fixture.entries(count: 7))
        await store.loadFirstPageIfNeeded()
        await scrollToEnd(store)
        let requestsAtEnd = client.requestCount

        await store.loadMore()
        await store.loadMoreIfNeeded(after: store.entries[store.entries.count - 1])

        #expect(client.requestCount == requestsAtEnd)
    }

    @Test("prefetch only fires near the end of the loaded list")
    func prefetchThreshold() async {
        let (store, client, _) = store(rows: Fixture.entries(count: 40), pageSize: 20)
        await store.loadFirstPageIfNeeded()
        let afterFirstPage = client.requestCount

        await store.loadMoreIfNeeded(after: store.entries[0])  // top of the list
        #expect(client.requestCount == afterFirstPage)

        await store.loadMoreIfNeeded(after: store.entries[19])  // last row
        #expect(client.requestCount == afterFirstPage + 1)
    }

    @Test("loading only happens once per appearance; refresh always refetches")
    func loadsOnceThenOnDemand() async {
        let (store, client, _) = store(rows: Fixture.entries(count: 10))

        await store.loadFirstPageIfNeeded()
        await store.loadFirstPageIfNeeded()
        #expect(client.requestCount == 1)

        await store.refresh()
        #expect(client.requestCount == 2)
    }

    @Test("pull-to-refresh puts a brand-new review at the top without duplicating the rest")
    func refreshFetchesTheNewest() async {
        let (store, client, _) = store(rows: Fixture.entries(count: 8))
        await store.loadFirstPageIfNeeded()
        await scrollToEnd(store)
        #expect(store.entries.count == 8)

        let newest = Fixture.entry(createdAt: Fixture.epoch.addingTimeInterval(3600), name: "Just posted")
        client.insert(newest)
        await store.refresh()

        #expect(store.entries.first?.id == newest.id)
        #expect(store.entries.count == 5)  // back to one page
        #expect(Set(store.entries.map(\.id)).count == store.entries.count)
        #expect(store.hasReachedEnd == false)

        await scrollToEnd(store)
        #expect(store.entries.count == 9)
        #expect(Set(store.entries.map(\.id)).count == 9)
    }

    @Test("an empty backend is the empty state, never a spinner that never ends")
    func emptyState() async {
        let (store, _, _) = store(rows: [])
        await store.loadFirstPageIfNeeded()
        #expect(store.phase == .empty)
        #expect(store.entries.isEmpty)
    }

    @Test("signed out is its own state — RLS hands anon an empty page, not an error")
    func signedOutState() async {
        let (store, client, _) = store(rows: Fixture.entries(count: 5))
        client.failEveryRequest(with: AteAPIError.notAuthenticated)

        await store.loadFirstPageIfNeeded()
        #expect(store.phase == .signedOut)

        // …and retry works once a session exists.
        client.stopFailing()
        await store.retry()
        #expect(store.phase == .ready)
    }

    @Test("losing the session mid-session drops the stale list")
    func signedOutMidSession() async {
        let (store, client, _) = store(rows: Fixture.entries(count: 5))
        await store.loadFirstPageIfNeeded()
        #expect(store.entries.isEmpty == false)

        client.failEveryRequest(with: AteAPIError.notAuthenticated)
        await store.refresh()

        #expect(store.phase == .signedOut)
        #expect(store.entries.isEmpty)
    }

    @Test("a failed first load is a recoverable error state, not a crash or a blank feed")
    func failedFirstLoad() async {
        let (store, client, _) = store(rows: Fixture.entries(count: 5))
        client.failNextRequest(with: URLError(.notConnectedToInternet))

        await store.loadFirstPageIfNeeded()
        #expect(store.phase == .failed(message: "You're offline."))

        await store.retry()
        #expect(store.phase == .ready)
        #expect(store.entries.count == 5)
    }

    @Test("a failed next page keeps the content and reports inline")
    func failedNextPage() async {
        let (store, client, _) = store(rows: Fixture.entries(count: 20))
        await store.loadFirstPageIfNeeded()
        client.failNextRequest(with: URLError(.timedOut))

        await store.loadMore()

        #expect(store.phase == .ready)
        #expect(store.entries.count == 5)  // nothing lost
        #expect(store.inlineErrorMessage == "Couldn't reach Ate. Check your connection.")

        await store.loadMore()
        #expect(store.entries.count == 10)
        #expect(store.inlineErrorMessage == nil)  // cleared once a page lands
    }

    @Test("page events are numbered from 1 and restart on refresh")
    func pageTelemetry() async {
        let analytics = RecordingAnalytics()
        let (store, _, _) = store(rows: Fixture.entries(count: 12), analytics: analytics)

        await store.loadFirstPageIfNeeded()
        await store.loadMore()
        #expect(analytics.pages == [.init(page: 1, itemCount: 5), .init(page: 2, itemCount: 5)])

        await store.refresh()
        #expect(analytics.pages.last == .init(page: 1, itemCount: 5))
        #expect(analytics.views == 0)  // the view fires this, not the store
    }

    @Test("a tap reports the dish it opens and where in the feed it was")
    func tapTelemetry() async {
        let analytics = RecordingAnalytics()
        let survivor = UUID()
        let rows = Fixture.entries(count: 3) + [
            Fixture.entry(
                mergedInto: survivor,
                createdAt: Fixture.epoch.addingTimeInterval(-100_000),
                name: "Merged away"
            )
        ]
        let (store, _, _) = store(rows: rows, pageSize: 10, analytics: analytics)
        await store.loadFirstPageIfNeeded()

        store.recordTap(on: store.entries[1])
        store.recordTap(on: store.entries[3])

        #expect(analytics.taps.first?.position == 1)
        #expect(analytics.taps.first?.dishID == store.entries[1].dish.id)
        // The tombstoned dish reports (and opens) its survivor.
        #expect(analytics.taps.last == .init(dishID: survivor, position: 3))
    }

    @Test("error copy is one human sentence, never the raw error")
    func errorCopy() {
        #expect(FeedStore.userFacingMessage(for: URLError(.notConnectedToInternet)) == "You're offline.")
        #expect(FeedStore.userFacingMessage(for: URLError(.networkConnectionLost)).contains("connection"))
        #expect(FeedStore.userFacingMessage(for: AteAPIError.notAuthenticated) == "Sign in to see the feed.")
        #expect(FeedStore.userFacingMessage(for: URLError(.badServerResponse)) == "Couldn't load the feed.")
    }
}
