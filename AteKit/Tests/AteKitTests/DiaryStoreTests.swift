import Foundation
import Testing

@testable import AteKit

// MARK: - Test doubles

/// A fake backend that pages exactly the way PostgREST does — total order on `(created_at, id)`
/// descending, cut by the keyset cursor — and that only ever serves rows belonging to `viewerID`,
/// the way the `reviewer_id` filter does.
private final class FakeDiary: DiaryReading, @unchecked Sendable {
    private let lock = NSLock()
    private let viewerID: UUID
    private var rows: [FeedEntry]
    private var pendingError: (any Error)?
    private var persistentError: (any Error)?
    private var requestCounter = 0
    /// Extra rows served on top of the requested page, to simulate a keyset shift (a review deleted
    /// mid-scroll) re-serving a row we already have.
    private var overlapNextPageBy = 0

    init(viewerID: UUID, rows: [FeedEntry]) {
        self.viewerID = viewerID
        self.rows = rows
    }

    func diaryPage(_ request: PageRequest) async throws -> Page<FeedEntry> {
        try lock.withLock {
            requestCounter += 1
            if let error = pendingError {
                pendingError = nil
                throw error
            }
            if let persistentError { throw persistentError }

            let ordered = rows
                .filter { $0.review.reviewerID == viewerID }
                .sorted { lhs, rhs in
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
    var requestCount: Int { lock.withLock { requestCounter } }
}

// MARK: - Fixtures

private enum DiaryFixture {
    static let epoch = Date(timeIntervalSince1970: 1_788_000_000)
    static let viewer = UUID()
    static let stranger = UUID()

    /// `count` of the viewer's entries, newest first, with every third row sharing a timestamp —
    /// the tie a `created_at`-only cursor loops or skips on.
    static func mine(count: Int) -> [FeedEntry] {
        (0..<count).map { index in
            entry(
                reviewerID: viewer,
                createdAt: epoch.addingTimeInterval(-Double(index / 3) * 3600),
                name: "Dish \(index)"
            )
        }
    }

    static func entry(
        id: UUID = UUID(),
        reviewerID: UUID = viewer,
        dishID: UUID = UUID(),
        mergedInto: UUID? = nil,
        createdAt: Date = epoch,
        name: String = "Cacio e Pepe"
    ) -> FeedEntry {
        FeedEntry(
            review: Review(
                id: id,
                reviewerID: reviewerID,
                dishID: dishID,
                restaurantID: UUID(),
                score: Rating(exactly: 4.5)!,
                note: "Good.",
                createdAt: createdAt,
                updatedAt: createdAt
            ),
            dish: FeedEntry.DishSummary(id: dishID, name: name, mergedIntoDishID: mergedInto),
            restaurant: FeedEntry.RestaurantSummary(id: UUID(), name: "Tipo 00", city: "Melbourne"),
            author: FeedEntry.AuthorSummary(id: reviewerID, username: "eamon", name: "Eamon")
        )
    }
}

/// Collects the events the store emits, in order.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AnalyticsEvent] = []

    var recorder: AnalyticsRecorder {
        { [self] event in lock.withLock { events.append(event) } }
    }

    var all: [AnalyticsEvent] { lock.withLock { events } }
    var names: [String] { all.map(\.name) }
}

// MARK: - Tests

@Suite("Diary store")
@MainActor
struct DiaryStoreTests {

    private func store(
        rows: [FeedEntry],
        pageSize: Int = 5,
        recorder: EventRecorder = EventRecorder()
    ) -> (DiaryStore, FakeDiary, EventRecorder) { // swiftlint:disable:this large_tuple
        let client = FakeDiary(viewerID: DiaryFixture.viewer, rows: rows)
        let store = DiaryStore(client: client, analytics: recorder.recorder, pageSize: pageSize)
        return (store, client, recorder)
    }

    private func scrollToEnd(_ store: DiaryStore) async {
        while !store.hasReachedEnd {
            let before = store.entries.count
            await store.loadMore()
            if store.entries.count == before { break }
        }
    }

    @Test("paging walks every one of my reviews exactly once, newest first, across timestamp ties")
    func walksTheWholeDiary() async {
        let (store, _, _) = store(rows: DiaryFixture.mine(count: 23))

        await store.loadIfNeeded()
        #expect(store.entries.count == 5)
        #expect(store.phase == .ready)

        await scrollToEnd(store)

        #expect(store.entries.count == 23)
        #expect(Set(store.entries.map(\.id)).count == 23)
        #expect(store.hasReachedEnd)

        for (newer, older) in zip(store.entries, store.entries.dropFirst()) {
            let descending = newer.review.createdAt > older.review.createdAt
                || (newer.review.createdAt == older.review.createdAt
                    && newer.id.uuidString > older.id.uuidString)
            #expect(descending)
        }
    }

    @Test("somebody else's review is never in my diary")
    func onlyMine() async {
        let rows = DiaryFixture.mine(count: 4) + [
            DiaryFixture.entry(reviewerID: DiaryFixture.stranger, name: "Not mine")
        ]
        let (store, _, _) = store(rows: rows, pageSize: 10)

        await store.loadIfNeeded()

        #expect(store.entries.count == 4)
        #expect(store.entries.allSatisfy { $0.review.reviewerID == DiaryFixture.viewer })
    }

    @Test("a row re-served after a keyset shift is dropped, not rendered twice")
    func deduplicatesOverlappingPages() async {
        let (store, client, _) = store(rows: DiaryFixture.mine(count: 20))
        await store.loadIfNeeded()
        client.overlapPages(by: 3)

        await scrollToEnd(store)

        #expect(store.entries.count == Set(store.entries.map(\.id)).count)
        #expect(store.entries.count == 20)
    }

    @Test("the end of the stream stops further requests")
    func stopsAtTheEnd() async {
        let (store, client, _) = store(rows: DiaryFixture.mine(count: 7))
        await store.loadIfNeeded()
        await scrollToEnd(store)
        let requestsAtEnd = client.requestCount

        await store.loadMore()
        await store.loadMoreIfNeeded(after: store.entries[store.entries.count - 1])

        #expect(client.requestCount == requestsAtEnd)
    }

    @Test("prefetch only fires near the end of the loaded list")
    func prefetchThreshold() async {
        let (store, client, _) = store(rows: DiaryFixture.mine(count: 40), pageSize: 20)
        await store.loadIfNeeded()
        let afterFirstPage = client.requestCount

        await store.loadMoreIfNeeded(after: store.entries[0])
        #expect(client.requestCount == afterFirstPage)

        await store.loadMoreIfNeeded(after: store.entries[19])
        #expect(client.requestCount == afterFirstPage + 1)
    }

    @Test("re-appearing doesn't refetch, but posting makes the next appearance reload")
    func staleAfterPosting() async {
        let (store, client, _) = store(rows: DiaryFixture.mine(count: 6))

        await store.loadIfNeeded()
        await store.loadIfNeeded()
        #expect(client.requestCount == 1)  // switching tabs doesn't refetch or jump the scroll

        // The Log sheet finishes: the diary now knows it is missing the newest review…
        let justPosted = DiaryFixture.entry(
            createdAt: DiaryFixture.epoch.addingTimeInterval(3600),
            name: "Son-in-law eggs"
        )
        client.insert(justPosted)
        store.reviewsWerePosted()
        #expect(client.requestCount == 1)  // …but doesn't fetch while the sheet is still up

        await store.loadIfNeeded()
        #expect(client.requestCount == 2)
        #expect(store.entries.first?.id == justPosted.id)

        // …and the staleness clears, so the appearance after that is quiet again.
        await store.loadIfNeeded()
        #expect(client.requestCount == 2)
    }

    @Test("pull-to-refresh always refetches and never duplicates what's already loaded")
    func refreshRefetches() async {
        let (store, client, _) = store(rows: DiaryFixture.mine(count: 8))
        await store.loadIfNeeded()
        await scrollToEnd(store)
        #expect(store.entries.count == 8)

        let newest = DiaryFixture.entry(
            createdAt: DiaryFixture.epoch.addingTimeInterval(3600),
            name: "Just posted"
        )
        client.insert(newest)
        await store.refresh()

        #expect(client.requestCount > 2)
        #expect(store.entries.first?.id == newest.id)
        #expect(store.entries.count == 5)  // back to one page
        #expect(store.hasReachedEnd == false)

        await scrollToEnd(store)
        #expect(store.entries.count == 9)
        #expect(Set(store.entries.map(\.id)).count == 9)
    }

    @Test("an empty diary is the invitation state, never a spinner that never ends")
    func emptyState() async {
        let (store, _, _) = store(rows: [])
        await store.loadIfNeeded()
        #expect(store.phase == .empty)
        #expect(store.entries.isEmpty)
    }

    @Test("signed out is its own state — RLS hands anon an empty page, not an error")
    func signedOutState() async {
        let (store, client, _) = store(rows: DiaryFixture.mine(count: 5))
        client.failEveryRequest(with: AteAPIError.notAuthenticated)

        await store.loadIfNeeded()
        #expect(store.phase == .signedOut)

        client.stopFailing()
        await store.retry()
        #expect(store.phase == .ready)
        #expect(store.entries.count == 5)
    }

    @Test("losing the session mid-session drops the stale list")
    func signedOutMidSession() async {
        let (store, client, _) = store(rows: DiaryFixture.mine(count: 5))
        await store.loadIfNeeded()
        #expect(store.entries.isEmpty == false)

        client.failEveryRequest(with: AteAPIError.notAuthenticated)
        await store.refresh()

        #expect(store.phase == .signedOut)
        #expect(store.entries.isEmpty)
    }

    @Test("a failed first load is a recoverable error state, not a blank diary")
    func failedFirstLoad() async {
        let (store, client, _) = store(rows: DiaryFixture.mine(count: 5))
        client.failNextRequest(with: URLError(.notConnectedToInternet))

        await store.loadIfNeeded()
        #expect(store.phase == .failed(message: "You're offline."))

        await store.retry()
        #expect(store.phase == .ready)
        #expect(store.entries.count == 5)
    }

    @Test("a failed next page keeps the content and reports inline")
    func failedNextPage() async {
        let (store, client, _) = store(rows: DiaryFixture.mine(count: 20))
        await store.loadIfNeeded()
        client.failNextRequest(with: URLError(.timedOut))

        await store.loadMore()

        #expect(store.phase == .ready)
        #expect(store.entries.count == 5)
        #expect(store.inlineErrorMessage == "Couldn't reach Ate. Check your connection.")

        await store.loadMore()
        #expect(store.entries.count == 10)
        #expect(store.inlineErrorMessage == nil)
    }

    @Test("the store emits the two diary funnel events, and nothing else")
    func telemetry() async {
        let recorder = EventRecorder()
        let survivor = UUID()
        let rows = DiaryFixture.mine(count: 3) + [
            DiaryFixture.entry(
                mergedInto: survivor,
                createdAt: DiaryFixture.epoch.addingTimeInterval(-100_000),
                name: "Merged away"
            )
        ]
        let (store, _, _) = store(rows: rows, pageSize: 10, recorder: recorder)

        store.recordDiaryViewed()
        await store.loadIfNeeded()
        #expect(recorder.names == ["diary_viewed"])  // loading a page is not an event

        store.recordTap(on: store.entries[3])
        #expect(recorder.names == ["diary_viewed", "diary_entry_tapped"])
        // The tombstoned dish reports (and opens) its survivor.
        #expect(recorder.all.last?.parameters == ["dish_id": survivor.uuidString.lowercased()])
    }

    @Test("error copy is one human sentence in the diary's first person")
    func errorCopy() {
        #expect(DiaryStore.userFacingMessage(for: URLError(.notConnectedToInternet)) == "You're offline.")
        #expect(DiaryStore.userFacingMessage(for: URLError(.networkConnectionLost)).contains("connection"))
        #expect(DiaryStore.userFacingMessage(for: AteAPIError.notAuthenticated) == "Sign in to see your diary.")
        #expect(DiaryStore.userFacingMessage(for: URLError(.badServerResponse)) == "Couldn't load your diary.")
    }
}
