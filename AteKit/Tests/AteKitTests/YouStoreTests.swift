import Foundation
import Testing

@testable import AteKit

/// **The You tab's five reads, and the four ways they are allowed to fail.**
///
/// The header is the only one that can empty the screen: a histogram that 500s should cost you the
/// chart, not your own name. Everything else degrades to absent, because design rule 1 forbids the
/// "couldn't load your ratings" line that would otherwise go there.
@Suite("You and ratings stores")
@MainActor
struct YouStoreTests {

    /// A stats seam that can be told to fail one call at a time.
    private final class Flaky: StatsReading, @unchecked Sendable {
        var failSummary = false
        var failHistogram = false
        var failDishes = false
        var failMonths = false
        var failViewer = false
        private(set) var dishCalls: [Double] = []
        private let inner: InMemoryStatsService

        init(inner: InMemoryStatsService = InMemoryStatsService()) {
            self.inner = inner
        }

        struct Nope: Error {}

        func viewerID() async throws -> UUID {
            if failViewer { throw Nope() }
            return try await inner.viewerID()
        }
        func summary(userID: UUID) async throws -> ProfileSummary {
            if failSummary { throw Nope() }
            return try await inner.summary(userID: userID)
        }
        func histogram(userID: UUID) async throws -> ScoreHistogram {
            if failHistogram { throw Nope() }
            return try await inner.histogram(userID: userID)
        }
        func dishes(
            userID: UUID, score: Double, after cursor: PageCursor?, pageSize: Int
        ) async throws -> Page<ScoredDish> {
            if cursor == nil { dishCalls.append(score) }
            if failDishes { throw Nope() }
            return try await inner.dishes(
                userID: userID, score: score, after: cursor, pageSize: pageSize
            )
        }
        func months(
            userID: UUID, timeZone: TimeZone, after cursor: StatementMonth?, limit: Int
        ) async throws -> [StatementMonthSummary] {
            if failMonths { throw Nope() }
            return try await inner.months(
                userID: userID, timeZone: timeZone, after: cursor, limit: limit
            )
        }
        func statement(
            userID: UUID, month: StatementMonth, timeZone: TimeZone
        ) async throws -> MonthlyStatement {
            try await inner.statement(userID: userID, month: month, timeZone: timeZone)
        }
    }

    @Test("Everything lands: the header, the chart, four 5.0s and the newest month")
    func loads() async {
        let stats = Flaky()
        let store = YouStore(stats: stats)
        await store.loadIfNeeded()

        #expect(store.summary?.username == "eamon")
        #expect(store.summary?.orders == 142)
        #expect(store.histogram.isEmpty == false)
        // "Your 5.0s" is four tiles, and only 5.0s.
        #expect(store.perfect.count == 4)
        #expect(store.perfect.allSatisfy { $0.score == 5 })
        #expect(stats.dishCalls == [5])
        #expect(store.month == StatementMonth(year: 2026, month: 9))
    }

    @Test("Loading twice reads once; a pull-to-refresh is the only thing that re-reads")
    func loadsOnce() async {
        let stats = Flaky()
        let store = YouStore(stats: stats)
        await store.loadIfNeeded()
        await store.loadIfNeeded()
        #expect(stats.dishCalls.count == 1)
        await store.refresh()
        #expect(stats.dishCalls.count == 2)
    }

    @Test("A chart that fails costs the chart, not the name")
    func histogramFailureIsSurvivable() async {
        let stats = Flaky()
        stats.failHistogram = true
        stats.failDishes = true
        stats.failMonths = true
        let store = YouStore(stats: stats)
        await store.loadIfNeeded()

        #expect(store.summary?.username == "eamon")
        #expect(store.histogram.isEmpty)
        #expect(store.perfect.isEmpty)
        #expect(store.month == nil)
    }

    @Test("No header is no page")
    func headerFailureEmptiesThePage() async {
        let stats = Flaky()
        stats.failSummary = true
        let store = YouStore(stats: stats)
        await store.loadIfNeeded()
        #expect(store.phase == .unavailable)
        #expect(store.summary == nil)
    }

    @Test("Signed out asks the server nothing")
    func signedOut() async {
        let stats = Flaky()
        stats.failViewer = true
        let store = YouStore(stats: stats)
        await store.loadIfNeeded()
        #expect(store.phase == .unavailable)
        #expect(stats.dishCalls.isEmpty)
    }

    // MARK: - Ratings

    @Test("A ratings page opens on its bar, with the histogram's own dish count")
    func ratingsLoads() async {
        let store = RatingsStore(score: 4.5, stats: InMemoryStatsService())
        await store.loadIfNeeded()
        #expect(store.score == 4.5)
        #expect(store.dishes.isEmpty == false)
        #expect(store.dishes.allSatisfy { $0.score == 4.5 })
        // The label counts DISHES (the histogram's number), not the rows, which are reviews.
        #expect(store.dishCount == 36)
        #expect(store.isLoading == false)
    }

    @Test("Tapping another bar moves the page; an empty bar is not a link")
    func ratingsSelects() async {
        // A histogram with a genuinely empty bucket at 2.0 — the case the tap has to refuse.
        let buckets = InMemoryStatsService.seededBuckets
            .map { $0.score == 2 ? ScoreBucket(score: 2, dishCount: 0, reviewCount: 0) : $0 }
        let stats = Flaky(inner: InMemoryStatsService(buckets: buckets))
        let store = RatingsStore(score: 4.5, stats: stats)
        await store.loadIfNeeded()

        await store.select(5)
        #expect(store.score == 5)
        #expect(store.dishes.allSatisfy { $0.score == 5 })

        // Nobody has ever given a 2.0, so there is nothing behind that bar to open.
        let calls = stats.dishCalls.count
        await store.select(2)
        #expect(store.score == 5)
        #expect(stats.dishCalls.count == calls)

        // The bar already lit is not re-read either.
        await store.select(5)
        #expect(stats.dishCalls.count == calls)
    }

    @Test("A score off the half-step grid snaps before it is asked for")
    func ratingsSnaps() async {
        let stats = Flaky()
        let store = RatingsStore(score: 4.3, stats: stats)
        #expect(store.score == 4.5)
        await store.loadIfNeeded()
        #expect(stats.dishCalls == [4.5])
    }

    // MARK: - Out of order

    /// A stats seam whose `dishes` call **parks** until the test lets it go, so two loads can be
    /// made to finish in the wrong order on purpose. Two taps in a row on a chart is not an edge
    /// case, and the slower answer arriving last is the normal shape of a flaky network.
    private actor Gated: StatsReading {
        private var waiting: [Double: CheckedContinuation<Void, Never>] = [:]
        private let inner: InMemoryStatsService

        init(inner: InMemoryStatsService) {
            self.inner = inner
        }

        func viewerID() async throws -> UUID { try await inner.viewerID() }

        func summary(userID: UUID) async throws -> ProfileSummary {
            try await inner.summary(userID: userID)
        }

        func histogram(userID: UUID) async throws -> ScoreHistogram {
            try await inner.histogram(userID: userID)
        }

        func dishes(
            userID: UUID, score: Double, after cursor: PageCursor?, pageSize: Int
        ) async throws -> Page<ScoredDish> {
            await withCheckedContinuation { waiting[score] = $0 }
            return try await inner.dishes(
                userID: userID, score: score, after: cursor, pageSize: pageSize
            )
        }

        func months(
            userID: UUID, timeZone: TimeZone, after cursor: StatementMonth?, limit: Int
        ) async throws -> [StatementMonthSummary] {
            try await inner.months(userID: userID, timeZone: timeZone, after: cursor, limit: limit)
        }

        func statement(
            userID: UUID, month: StatementMonth, timeZone: TimeZone
        ) async throws -> MonthlyStatement {
            try await inner.statement(userID: userID, month: month, timeZone: timeZone)
        }

        /// Lets one parked call finish.
        func release(_ score: Double) {
            waiting.removeValue(forKey: score)?.resume()
        }

        /// Waits until a call for `score` is actually parked — the actor is reentrant while it is
        /// suspended on its continuation, which is what makes this safe to poll.
        func waitUntilParked(_ score: Double) async {
            for _ in 0..<500 {
                if waiting[score] != nil { return }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    /// One dish at 4.0 so a stale page is detectable: an empty one would satisfy any assertion.
    private static func gatedFixture() -> InMemoryStatsService {
        InMemoryStatsService(dishes: InMemoryStatsService.seededDishes + [
            ScoredDish(
                reviewID: UUID(), dishID: UUID(), dishName: "Toast",
                restaurantName: "Home", score: 4,
                createdAt: Date(timeIntervalSince1970: 1_789_000_000)
            )
        ])
    }

    @Test("A bar you have left cannot land its rows on the bar you are looking at")
    func ratingsDropsAStaleLoad() async {
        let gated = Gated(inner: Self.gatedFixture())
        let store = RatingsStore(score: 4.5, stats: gated)

        let first = Task { await store.loadIfNeeded() }
        await gated.waitUntilParked(4.5)
        await gated.release(4.5)
        await first.value
        #expect(store.dishes.allSatisfy { $0.score == 4.5 })

        // Two taps. The second answers first; the first arrives late.
        let older = Task { await store.select(4) }
        await gated.waitUntilParked(4)
        let newer = Task { await store.select(5) }
        await gated.waitUntilParked(5)
        await gated.release(5)
        await newer.value
        await gated.release(4)
        await older.value

        #expect(store.score == 5)
        #expect(store.dishes.isEmpty == false)
        #expect(store.dishes.allSatisfy { $0.score == 5 },
                "the late 4.0 page must not land on a 5.0 bar")
        #expect(store.isLoading == false)
    }

    @Test("A prefetch started before a bar switch does not append to the new bar")
    func ratingsDropsAStalePrefetch() async {
        let gated = Gated(inner: Self.gatedFixture())
        // One row a page, so the first page leaves a cursor and a prefetch is possible.
        let store = RatingsStore(score: 4.5, stats: gated, pageSize: 1)

        let first = Task { await store.loadIfNeeded() }
        await gated.waitUntilParked(4.5)
        await gated.release(4.5)
        await first.value
        let onScreen = try? #require(store.dishes.first)

        // The list asks for its next page…
        let prefetch = Task { await store.loadMoreIfNeeded(after: onScreen!) }
        await gated.waitUntilParked(4.5)
        // …and the person taps another bar before it lands.
        let switched = Task { await store.select(5) }
        await gated.waitUntilParked(5)
        await gated.release(5)
        await switched.value
        await gated.release(4.5)
        await prefetch.value

        #expect(store.score == 5)
        #expect(store.dishes.isEmpty == false)
        #expect(store.dishes.allSatisfy { $0.score == 5 },
                "a 4.5 page in flight must not be appended to the 5.0 list")
    }
}
