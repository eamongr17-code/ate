import Foundation
import Testing

@testable import AteKit

/// **Your ratings, on one page**: every scored dish, grouped by score from the top, and a bar that
/// scrolls to its group rather than filtering the list.
@Suite("Ratings — every dish, grouped by score")
@MainActor
struct RatingsStoreTests {

    /// Counts the pages asked for, and can be told to fail.
    private final class Recording: StatsReading, @unchecked Sendable {
        struct Nope: Error {}
        var failDishes = false
        private(set) var calls: [(score: Double, isFirst: Bool)] = []
        private let inner: InMemoryStatsService

        init(_ inner: InMemoryStatsService) { self.inner = inner }

        func viewerID() async throws -> UUID { try await inner.viewerID() }
        func summary(userID: UUID) async throws -> ProfileSummary { try await inner.summary(userID: userID) }
        func histogram(userID: UUID) async throws -> ScoreHistogram { try await inner.histogram(userID: userID) }
        func dishes(
            userID: UUID, score: Double, after cursor: PageCursor?, pageSize: Int
        ) async throws -> Page<ScoredDish> {
            calls.append((score, cursor == nil))
            if failDishes { throw Nope() }
            return try await inner.dishes(userID: userID, score: score, after: cursor, pageSize: pageSize)
        }
        func months(
            userID: UUID, timeZone: TimeZone, after cursor: StatementMonth?, limit: Int
        ) async throws -> [StatementMonthSummary] {
            try await inner.months(userID: userID, timeZone: timeZone, after: cursor, limit: limit)
        }
        func statement(userID: UUID, month: StatementMonth, timeZone: TimeZone) async throws -> MonthlyStatement {
            try await inner.statement(userID: userID, month: month, timeZone: timeZone)
        }
    }

    private static func dish(_ name: String, _ score: Double, daysAgo: Double) -> ScoredDish {
        ScoredDish(
            reviewID: UUID(), dishID: UUID(), dishName: name, restaurantName: "Somewhere",
            score: score, createdAt: Date(timeIntervalSince1970: 1_789_000_000 - daysAgo * 86_400)
        )
    }

    /// Three at 5.0, two at 4.0, one at 2.5 — and nothing at all at 4.5, so an empty bar sits
    /// between two full ones.
    private static func fixture() -> InMemoryStatsService {
        let dishes = [
            dish("A", 5, daysAgo: 1), dish("B", 5, daysAgo: 2), dish("C", 5, daysAgo: 3),
            dish("D", 4, daysAgo: 1), dish("E", 4, daysAgo: 4),
            dish("F", 2.5, daysAgo: 9)
        ]
        let buckets = ScoreHistogram.scores.map { score in
            let count = dishes.filter { $0.score == score }.count
            return ScoreBucket(score: score, dishCount: count, reviewCount: count)
        }
        return InMemoryStatsService(buckets: buckets, dishes: dishes)
    }

    @Test("Every scored dish is on the page, grouped highest score first")
    func groupsEverything() async {
        let store = RatingsStore(score: 5, stats: Self.fixture())
        await store.loadIfNeeded()
        while store.isExhausted == false { await store.loadNextPage() }

        #expect(store.groups.map(\.score) == [5, 4, 2.5])
        #expect(store.groups.map { $0.dishes.map(\.dishName) } == [["A", "B", "C"], ["D", "E"], ["F"]])
        let allComplete = store.groups.allSatisfy { $0.isComplete }
        #expect(allComplete)
        // The label is the histogram's dish count, not the rows'.
        #expect(store.group(at: 5)?.dishCount == 3)
        #expect(store.isLoading == false)
    }

    @Test("A group only starts once the one above it has been read to its end")
    func strictlyInOrder() async {
        let stats = Recording(Self.fixture())
        let store = RatingsStore(score: 5, stats: stats, pageSize: 2)
        await store.loadIfNeeded()

        // One page of 5.0 (two of its three rows): 4.0 must not be on the page yet.
        #expect(store.groups.map(\.score) == [5])
        #expect(store.group(at: 5)?.isComplete == false)

        await store.loadNextPage()
        #expect(store.group(at: 5)?.dishes.count == 3)
        #expect(store.group(at: 4) == nil)

        await store.loadNextPage()
        #expect(store.groups.map(\.score) == [5, 4])
        // Keyset pages, never offsets: every call after a group's first carries a cursor.
        #expect(stats.calls.map(\.score) == [5, 5, 4])
        #expect(stats.calls.map(\.isFirst) == [true, false, true])
    }

    @Test("Tapping a bar reads down to its group, lights it, and leaves the list whole above it")
    func barRevealsItsGroup() async {
        let store = RatingsStore(score: 5, stats: Self.fixture(), pageSize: 2)
        await store.loadIfNeeded()

        await store.select(2.5)
        #expect(store.score == 2.5)
        #expect(store.group(at: 2.5) != nil)
        // Everything above it is complete — nothing can grow and push the group down the screen.
        let aboveComplete = store.groups.dropLast().allSatisfy { $0.isComplete }
        #expect(aboveComplete)
        #expect(store.groups.map(\.score) == [5, 4, 2.5])
    }

    /// Every page takes a moment, so a second tap lands while the first tap's walk is mid-page.
    private final class Slow: StatsReading, @unchecked Sendable {
        private let inner: InMemoryStatsService
        init(_ inner: InMemoryStatsService) { self.inner = inner }
        func viewerID() async throws -> UUID { try await inner.viewerID() }
        func summary(userID: UUID) async throws -> ProfileSummary { try await inner.summary(userID: userID) }
        func histogram(userID: UUID) async throws -> ScoreHistogram { try await inner.histogram(userID: userID) }
        func dishes(
            userID: UUID, score: Double, after cursor: PageCursor?, pageSize: Int
        ) async throws -> Page<ScoredDish> {
            try await Task.sleep(for: .milliseconds(15))
            return try await inner.dishes(userID: userID, score: score, after: cursor, pageSize: pageSize)
        }
        func months(
            userID: UUID, timeZone: TimeZone, after cursor: StatementMonth?, limit: Int
        ) async throws -> [StatementMonthSummary] {
            try await inner.months(userID: userID, timeZone: timeZone, after: cursor, limit: limit)
        }
        func statement(userID: UUID, month: StatementMonth, timeZone: TimeZone) async throws -> MonthlyStatement {
            try await inner.statement(userID: userID, month: month, timeZone: timeZone)
        }
    }

    @Test("Two quick taps end on the second bar's group, and only the second counts as viewed")
    func latestTapWins() async throws {
        let store = RatingsStore(score: 5, stats: Slow(Self.fixture()), pageSize: 1)
        await store.loadIfNeeded()
        var viewed: [Double] = []
        // What the screen does with a tap: scroll and count only if it is still the lit bar.
        func tap(_ score: Double) async -> Bool {
            let current = await store.select(score)
            if current { viewed.append(score) }
            return current
        }

        // 2.5 sits behind every 5.0 and 4.0 page; 4.0 is tapped while the walk is mid-page.
        let first = Task { await tap(2.5) }
        try await Task.sleep(for: .milliseconds(5))
        let second = Task { await tap(4) }
        let secondIsCurrent = await second.value
        let firstIsCurrent = await first.value

        #expect(secondIsCurrent)
        #expect(firstIsCurrent == false)
        #expect(store.score == 4)
        #expect(store.group(at: 4) != nil, "the second tap's walk waited on the page in the air")
        #expect(viewed == [4])
    }

    @Test("A walk that finds a page in the air waits for it rather than giving up")
    func revealWaitsForTheInFlightPage() async {
        let store = RatingsStore(score: 5, stats: Slow(Self.fixture()), pageSize: 1)
        await store.loadIfNeeded()
        let prefetch = Task { await store.loadNextPage() }
        await Task.yield()
        let reached = await store.select(2.5)
        await prefetch.value
        #expect(reached)
        #expect(store.group(at: 2.5) != nil)
    }

    @Test("Opened on a bar, the page already holds that bar's group")
    func opensOnABar() async {
        let store = RatingsStore(score: 4, stats: Self.fixture(), pageSize: 1)
        await store.loadIfNeeded()
        #expect(store.score == 4)
        #expect(store.group(at: 4) != nil)
        #expect(store.group(at: 5)?.isComplete == true)
    }

    @Test("An empty bar is not a link, and a score off the grid snaps")
    func emptyBarAndSnapping() async {
        let stats = Recording(Self.fixture())
        let store = RatingsStore(score: 4.9, stats: stats)
        #expect(store.score == 5)
        await store.loadIfNeeded()

        let calls = stats.calls.count
        await store.select(4.5)
        #expect(store.score == 5)
        #expect(stats.calls.count == calls)
    }

    @Test("A page that fails stops the list where it is; a refresh starts it again")
    func failureStopsAndRefreshRecovers() async {
        let stats = Recording(Self.fixture())
        stats.failDishes = true
        let store = RatingsStore(score: 5, stats: stats)
        await store.loadIfNeeded()
        #expect(store.didFail)
        #expect(store.groups.isEmpty)

        stats.failDishes = false
        await store.refresh()
        #expect(store.didFail == false)
        #expect(store.groups.first?.score == 5)
    }

    @Test("\"Your ratings\" opens on the highest score anybody's been given, whatever is busiest")
    func highestScore() async throws {
        let histogram = try await Self.fixture().histogram(userID: UUID())
        #expect(histogram.highestScore == 5)
        #expect(ScoreHistogram.empty.highestScore == nil)
        let lowOnly = ScoreHistogram([ScoreBucket(score: 2, dishCount: 1, reviewCount: 1)])
        #expect(lowOnly.highestScore == 2)
    }

    @Test("Nothing scored is an empty page, not a spinner")
    func nothingScored() async {
        let store = RatingsStore(score: 5, stats: InMemoryStatsService(buckets: [], dishes: []))
        await store.loadIfNeeded()
        #expect(store.groups.isEmpty)
        #expect(store.isExhausted)
        #expect(store.isLoading == false)
    }

    @Test("The date carries its year only when it is not this year")
    func dateLabel() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        let locale = Locale(identifier: "en_US")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12))!
        func row(_ year: Int, _ month: Int, _ day: Int) -> ScoredDish {
            ScoredDish(
                reviewID: UUID(), dishID: UUID(), dishName: "X", score: 4,
                createdAt: calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
            )
        }
        #expect(row(2026, 9, 19).dateLabel(now: now, calendar: calendar, locale: locale) == "19 Sep")
        #expect(row(2025, 12, 2).dateLabel(now: now, calendar: calendar, locale: locale) == "2 Dec 2025")
    }
}
