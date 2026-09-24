import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **The You tab's RPCs, against the real staging rows.**
///
/// Unit tests prove the client decodes a payload we wrote down; only this proves the function is
/// still called by that name, still takes those parameters, and still answers with that shape.
/// `score_histogram`, `dishes_by_score`, `statement_months` and `monthly_statement` are all
/// named-argument PostgREST invocations, which is exactly the kind of thing that breaks silently on
/// the client and loudly nowhere.
///
/// Read-only, and opt-in (`ATE_CONTRACT_TESTS=1`), staging only, like its siblings.
@Suite("You and statements contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct StatsContractTests {
    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    @Test("profile_summary answers for the viewer, and says it is them")
    func viewerHeader() async throws {
        let stats = StatsClient(api: try await client())
        let me = try await stats.viewerID()
        let summary = try await stats.summary(userID: me)
        #expect(summary.userID == me)
        #expect(summary.username.isEmpty == false)
        #expect(summary.isMe, "the You tab's header is the viewer's own")
        #expect(summary.orders >= 0 && summary.places >= 0 && summary.dishes >= 0)
    }

    /// The RPC's contract is all ten buckets, zeros included, so the client never fills a gap.
    @Test("score_histogram is ten half-steps with the zeros in place")
    func histogram() async throws {
        let stats = StatsClient(api: try await client())
        let me = try await stats.viewerID()
        let histogram = try await stats.histogram(userID: me)

        #expect(histogram.buckets.count == 10)
        #expect(histogram.buckets.map(\.score) == ScoreHistogram.scores)
        #expect(histogram.buckets.allSatisfy { $0.dishCount >= 0 && $0.reviewCount >= 0 })
        // One dish scored twice is one dish and two reviews — never the other way round.
        #expect(histogram.buckets.allSatisfy { $0.reviewCount >= $0.dishCount })
        #expect(histogram.isEmpty == false, "the seeded viewer has scored something")

        // The header and the chart are the same population since 0029: both count by
        // `reviews.reviewer_id`, so a review with a null `entry_id` is in both. They disagreed
        // before that (40 vs 60 on staging), which is exactly the kind of drift this catches.
        let summary = try await stats.summary(userID: me)
        #expect(histogram.buckets.reduce(0) { $0 + $1.reviewCount } == summary.scored)
        #expect(histogram.buckets.reduce(0) { $0 + $1.reviewCount } <= summary.dishes)
    }

    @Test("dishes_by_score returns the bar's dishes, newest first, at that exact score")
    func dishesByScore() async throws {
        let stats = StatsClient(api: try await client())
        let me = try await stats.viewerID()
        let histogram = try await stats.histogram(userID: me)
        let score = try #require(histogram.busiestScore)

        let page = try await stats.dishes(userID: me, score: score, pageSize: 100)
        let dishes = page.items
        #expect(dishes.isEmpty == false)
        #expect(dishes.allSatisfy { ScoreHistogram.halfSteps($0.score) == ScoreHistogram.halfSteps(score) })
        #expect(dishes.allSatisfy { $0.dishName.isEmpty == false })
        // The label counts DISHES; the rows are reviews, so there are at least as many rows.
        #expect(dishes.count >= histogram.dishCount(at: score))
        #expect(Set(dishes.map(\ScoredDish.dishID)).count == histogram.dishCount(at: score))
        let ordered = zip(dishes, dishes.dropFirst()).allSatisfy { first, second in
            (first.createdAt, first.reviewID.uuidString) > (second.createdAt, second.reviewID.uuidString)
        }
        #expect(ordered, "created_at DESC, id DESC")
        // The tile and the row thumbnail: nullable, but the column has to be there to decode.
        _ = dishes.map(\ScoredDish.coverURL)
        // `entry_id` is genuinely optional on real rows (a review can predate `entries`), which is
        // why the row's tap target is the DISH and not the visit.
        _ = dishes.map(\ScoredDish.entryID)
    }

    /// The keyset, walked: no gaps, no repeats, and it stops. The same contract the feed keeps.
    @Test("dishes_by_score pages with the (created_at, id) cursor")
    func dishesByScorePages() async throws {
        let stats = StatsClient(api: try await client())
        let me = try await stats.viewerID()
        let histogram = try await stats.histogram(userID: me)
        let score = try #require(histogram.busiestScore)

        var cursor: PageCursor?
        var seen: [ScoredDish] = []
        var pages = 0
        while pages < 60 {
            let page = try await stats.dishes(userID: me, score: score, after: cursor, pageSize: 2)
            seen.append(contentsOf: page.items)
            pages += 1
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        #expect(seen.isEmpty == false)
        #expect(Set(seen.map(\ScoredDish.reviewID)).count == seen.count,
                "a keyset page must not serve a row twice")
        let whole = try await stats.dishes(userID: me, score: score, pageSize: 100)
        #expect(seen.map(\ScoredDish.reviewID) == whole.items.map(\ScoredDish.reviewID),
                "the walk and the single read agree, row for row")
    }

    @Test("A score nobody has given comes back empty rather than failing")
    func emptyBar() async throws {
        let stats = StatsClient(api: try await client())
        let me = try await stats.viewerID()
        let histogram = try await stats.histogram(userID: me)
        guard let empty = histogram.buckets.first(where: { $0.dishCount == 0 })?.score else { return }
        let page = try await stats.dishes(userID: me, score: empty, pageSize: 10)
        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
    }

    @Test("statement_months lists only months that have something in them, newest first")
    func months() async throws {
        let stats = StatsClient(api: try await client())
        let me = try await stats.viewerID()
        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        let rows = try await stats.allMonths(userID: me, timeZone: melbourne)

        #expect(rows.isEmpty == false)
        #expect(rows.allSatisfy { $0.orders > 0 }, "a month with no orders has no statement")
        let months = StatementMonths(summaries: rows)
        #expect(months.months == rows.map(\.month), "already newest first")
        // And the total is the viewer's own order count.
        let summary = try await stats.summary(userID: me)
        #expect(rows.reduce(0) { $0 + $1.orders } == summary.orders)

        // Paged on the month itself: one row at a time walks the same list, in the same order.
        var walked: [StatementMonthSummary] = []
        var cursor: StatementMonth?
        for _ in 0..<12 {
            let page = try await stats.months(
                userID: me, timeZone: melbourne, after: cursor, limit: 1
            )
            guard let row = page.first else { break }
            walked.append(row)
            cursor = row.month
        }
        #expect(walked.map(\StatementMonthSummary.month) == rows.map(\StatementMonthSummary.month))
    }

    @Test("monthly_statement fills every band of the receipt for a real month")
    func statement() async throws {
        let stats = StatsClient(api: try await client())
        let me = try await stats.viewerID()
        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        let months = StatementMonths(summaries: try await stats.allMonths(userID: me, timeZone: melbourne))
        let newest = try #require(months.newest)

        let statement = try await stats.statement(userID: me, month: newest, timeZone: melbourne)
        // The month it answers with is the month that was asked for — the client's label comes
        // from the payload, so a drift here would silently retitle the receipt.
        #expect(statement.month == newest)
        // …and the receipt is signed from the same payload, never a second call.
        #expect(statement.username == (try await stats.summary(userID: me)).username)
        #expect(statement.orders > 0)
        #expect(statement.places >= 0)
        #expect(statement.newPlaces <= statement.places)
        #expect(statement.dishes >= 0)
        #expect(statement.stars >= 0)
        #expect(statement.topDishes.count <= 3)
        #expect(statement.topDishes.allSatisfy { $0.dishName.isEmpty == false })
        // Top of the month is ranked, and every line prints a score.
        let scores = statement.topDishes.compactMap(\.score)
        #expect(scores.count == statement.topDishes.count)
        #expect(scores == scores.sorted(by: >))
        // A count of one is not a habit: the server sends null and the receipt prints nothing,
        // rather than "x1".
        if let ordered = statement.mostOrdered { #expect(ordered.count >= 2) }
        if let visited = statement.mostVisited {
            #expect(visited.restaurantName.isEmpty == false)
            #expect(visited.count >= 2)
        }
        // The average covers scored lines only, so it can never exceed the scale.
        if let average = statement.average { #expect(average > 0 && average <= 5) }
    }

    /// Month boundaries are local wall-clock. The same month asked for in two zones is a different
    /// slice of time, and the payload must say which month it answered for either way.
    @Test("A statement's month is the month it was asked for, in either zone")
    func statementIsLocal() async throws {
        let stats = StatsClient(api: try await client())
        let me = try await stats.viewerID()
        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        let months = StatementMonths(summaries: try await stats.allMonths(userID: me, timeZone: melbourne))
        let newest = try #require(months.newest)

        let here = try await stats.statement(userID: me, month: newest, timeZone: melbourne)
        let there = try await stats.statement(
            userID: me, month: newest, timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
        #expect(here.month == newest)
        #expect(there.month == newest)
    }
}
