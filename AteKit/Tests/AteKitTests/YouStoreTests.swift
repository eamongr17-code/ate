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
}
