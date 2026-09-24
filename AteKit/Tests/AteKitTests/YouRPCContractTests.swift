import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **What Ate gives back, against staging** — `profile_summary`, `score_histogram`,
/// `dishes_by_score`, `statement_months`, `monthly_statement`, `get_entries_by_author`
/// (0023, revised 0029).
///
/// The regression these exist for: **You and Ratings used to disagree about the same person.**
/// `profile_summary` counted a user's dishes through `entries`, so a review written before entries
/// existed counted for nobody, while `score_histogram` counted it — staging printed "40 scored" next
/// to a chart summing to 60. Here the two are cross-checked against each other, and the histogram is
/// used to predict the profile's average, so the numbers cannot drift apart again silently.
///
/// The rest is the same discipline as the detail suite: paged reads are walked in small pages and
/// compared to the same read taken whole, and a `Rating` decode is how "every score is a half-step"
/// is asserted.
///
/// Opt-in: `ATE_CONTRACT_TESTS=1`, staging only, never prod (rule 5).
@Suite("You / Ratings / Recap RPCs — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct YouRPCContractTests {
    static let pageSize = 2

    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    func me(_ client: AteAPIClient) async throws -> UUID {
        try await client.requireCurrentUserID()
    }

    func profile(_ client: AteAPIClient, _ user: UUID) async throws -> ProfileSummary {
        let rows: [ProfileSummary] = try await StagingRPC.rows(
            client, "profile_summary", ["p_user_id": StagingRPC.id(user)]
        )
        return try #require(rows.first, "profile_summary returned no row for the signed-in viewer")
    }

    func histogram(_ client: AteAPIClient, _ user: UUID) async throws -> [HistogramRow] {
        try await StagingRPC.rows(client, "score_histogram", ["p_user_id": StagingRPC.id(user)])
    }

    // MARK: - profile_summary + score_histogram

    @Test("profile_summary and score_histogram count the same lines — the You/Ratings regression")
    func profileAgreesWithTheHistogram() async throws {
        let client = try await client()
        let user = try await me(client)
        let summary = try await profile(client, user)
        let buckets = try await histogram(client, user)

        #expect(summary.userID == user)
        #expect(summary.isMe)
        #expect(summary.username.isEmpty == false)
        #expect(summary.city != "", "an absent city is NULL, not an empty line under the handle")
        // Orders and Places are ENTRIES; Dishes are receipt LINES, so lines >= scored lines.
        #expect(summary.orders > 0, "the demo viewer must have entries or this proves nothing")
        #expect(summary.places <= summary.orders, "you cannot visit more places than you have visits")
        #expect(summary.dishes >= summary.scored)

        let scoredLines = buckets.reduce(0) { $0 + $1.reviewCount }
        #expect(summary.scored == scoredLines, "You says \(summary.scored) scored, Ratings says \(scoredLines)")

        // And the histogram predicts the average: same population, so the weighted mean must match.
        if scoredLines > 0 {
            let total = buckets.reduce(0.0) { $0 + $1.score.value * Double($1.reviewCount) }
            let mean = total / Double(scoredLines)
            #expect(abs((summary.avgScore ?? -1) - mean) <= 0.01, "avg_score is not the histogram's mean")
        } else {
            #expect(summary.avgScore == nil, "no scores is no average, not 0")
        }
    }

    @Test("score_histogram is ten half-step buckets with the zeros left in")
    func histogramIsTenBuckets() async throws {
        let client = try await client()
        let buckets = try await histogram(client, try await me(client))

        #expect(buckets.count == 10, "the chart draws ten bars and fills no gaps of its own")
        #expect(buckets.map(\.score) == buckets.map(\.score).sorted(), "buckets ascend 0.5 → 5.0")
        #expect(buckets.first?.score == Rating(exactly: 0.5))
        #expect(buckets.last?.score == Rating(exactly: 5.0))
        // A dish can be scored twice at the same value (sittings), never the other way round.
        #expect(buckets.allSatisfy { $0.dishCount <= $0.reviewCount })
        #expect(buckets.contains { $0.reviewCount == 0 }, "a zero bucket must still arrive as a row")
    }

    // MARK: - dishes_by_score

    @Test("dishes_by_score fills the bucket it was asked for, carries the tile, and pages")
    func dishesByScoreMatchesItsBucket() async throws {
        let client = try await client()
        let user = try await me(client)
        let fullest = try #require(
            try await histogram(client, user).max(by: { $0.reviewCount < $1.reviewCount }),
            "an empty histogram cannot be tapped"
        )
        #expect(fullest.reviewCount > 0, "the viewer has no scores at all — seed some")

        let whole = try await scoredPage(client, user, fullest.score, size: 500)
        #expect(whole.count == fullest.reviewCount, "the bar says \(fullest.reviewCount) lines")
        #expect(whole.allSatisfy { $0.score == fullest.score })
        #expect(whole.allSatisfy { $0.dishName.isEmpty == false && $0.restaurantName.isEmpty == false })
        #expect(whole.allSatisfy { $0.coverURL != "" })
        // Newest first: the list prints "19 Sep" down the right edge.
        for (newer, older) in zip(whole, whole.dropFirst()) {
            #expect(newer.createdAt >= older.createdAt)
        }
        // The tile draws a photo, so at least one row in the fullest bucket must have one.
        withKnownIssue(
            "no dish in this bucket has a photo yet — the tiles would draw empty",
            isIntermittent: true
        ) {
            #expect(whole.contains { $0.coverURL != nil })
        }

        var walked: [ScoredDishRow] = []
        var cursor: ScoredDishRow?
        var pages = 0
        repeat {
            let page = try await scoredPage(client, user, fullest.score, size: Self.pageSize, after: cursor)
            walked.append(contentsOf: page)
            cursor = page.count < Self.pageSize ? nil : page.last
            pages += 1
        } while cursor != nil && pages < 200
        let wholeAfter = try await scoredPage(client, user, fullest.score, size: 500)
        KeysetWalk.expectMatches(
            walked.map(\.reviewID), before: whole.map(\.reviewID), after: wholeAfter.map(\.reviewID),
            "dishes_by_score"
        )
    }

    func scoredPage(
        _ client: AteAPIClient, _ user: UUID, _ score: Rating, size: Int, after last: ScoredDishRow? = nil
    ) async throws -> [ScoredDishRow] {
        try await StagingRPC.rows(client, "dishes_by_score", [
            "p_user_id": StagingRPC.id(user),
            "p_score": .double(score.value),
            "p_limit": .integer(size),
            "p_cursor_created_at": StagingRPC.maybeAt(last?.createdAt),
            "p_cursor_id": StagingRPC.maybeID(last?.reviewID)
        ])
    }

    // MARK: - statement_months + monthly_statement

    @Test("statement_months pages newest-first and accounts for every entry")
    func statementMonthsPageAndSum() async throws {
        let client = try await client()
        let user = try await me(client)
        let whole = try await monthsPage(client, user, size: 240)
        #expect(whole.isEmpty == false, "a viewer with entries has at least one statement")
        #expect(whole.map(\.month) == whole.map(\.month).sorted(by: >), "newest month first")
        #expect(Set(whole.map(\.month)).count == whole.count, "a month cannot appear twice")
        #expect(whole.allSatisfy { $0.orders > 0 }, "a month with no entries is not a statement")

        // Every entry lands in exactly one month, so the months account for the profile's orders.
        let summary = try await profile(client, user)
        #expect(whole.reduce(0) { $0 + $1.orders } == summary.orders)

        var walked: [StatementMonthRow] = []
        var cursor: StatementMonthRow?
        var pages = 0
        repeat {
            let page = try await monthsPage(client, user, size: 1, after: cursor)
            walked.append(contentsOf: page)
            cursor = page.isEmpty ? nil : page.last
            pages += 1
        } while cursor != nil && pages < 240
        let wholeAfter = try await monthsPage(client, user, size: 240)
        KeysetWalk.expectMatches(
            walked.map(\.month), before: whole.map(\.month), after: wholeAfter.map(\.month),
            "statement_months"
        )
    }

    @Test("monthly_statement is the receipt design/v1/Recap prints, and never claims a habit of one")
    func monthlyStatementIsTheReceipt() async throws {
        let client = try await client()
        let user = try await me(client)
        let summary = try await profile(client, user)
        let newest = try #require(try await monthsPage(client, user, size: 1).first)

        let statement: MonthlyStatement = try await StagingRPC.value(client, "monthly_statement", [
            "p_user_id": StagingRPC.id(user),
            "p_month": .string(newest.month),
            "p_tz": .string("Australia/Melbourne")
        ])

        #expect(statement.month == newest.month, "the statement is the month that was asked for")
        #expect(statement.orders == newest.orders, "the picker and the receipt disagree about orders")
        #expect(statement.username == summary.username, "the handle under the month is the viewer's")
        // ENTRIES on the top three lines, LINES below them.
        #expect(statement.places <= statement.orders)
        #expect(statement.newPlaces <= statement.places)
        #expect(statement.dishes >= 0)
        #expect(statement.stars >= 0)
        if let average = statement.average {
            #expect(average >= 0.5 && average <= 5.0, "an average outside the scale is not an average")
            #expect(statement.dishes > 0)
        }
        // "Top of the month": at most three, best first.
        #expect(statement.topDishes.count <= 3)
        #expect(statement.topDishes.map(\.score) == statement.topDishes.map(\.score).sorted(by: >))
        #expect(statement.topDishes.allSatisfy { $0.restaurantName.isEmpty == false })
        // Once is not a habit (0029): "Most ordered … x1" prints nothing at all.
        #expect((statement.mostOrdered?.count ?? 2) >= 2)
        #expect((statement.mostVisited?.count ?? 2) >= 2)
    }

    func monthsPage(
        _ client: AteAPIClient, _ user: UUID, size: Int, after last: StatementMonthRow? = nil
    ) async throws -> [StatementMonthRow] {
        try await StagingRPC.rows(client, "statement_months", [
            "p_user_id": StagingRPC.id(user),
            "p_tz": .string("Australia/Melbourne"),
            "p_cursor_month": StagingRPC.text(last?.month),
            "p_limit": .integer(size)
        ])
    }

    // MARK: - get_entries_by_author

    @Test("get_entries_by_author is entry_cards for one author, private ones included when it is me")
    func entriesByAuthorAreEntryCards() async throws {
        let client = try await client()
        let user = try await me(client)
        let whole = try await authorPage(client, user, size: 50)
        #expect(whole.isEmpty == false, "the demo viewer's journal is empty")
        #expect(whole.allSatisfy { $0.authorID == user })
        #expect(whole.allSatisfy { $0.isMine })
        #expect(whole.allSatisfy { $0.dishCount == $0.items.count })
        // My own journal is the one place a private entry is visible; an entry I cannot see is not
        // "missing data" but the RLS contract working.
        #expect(whole.allSatisfy { $0.orderNumber > 0 })

        var walked: [EntryCard] = []
        var cursor: EntryCard?
        var pages = 0
        repeat {
            let page = try await authorPage(client, user, size: Self.pageSize, after: cursor)
            walked.append(contentsOf: page)
            cursor = page.count < Self.pageSize ? nil : page.last
            pages += 1
        } while cursor != nil && pages < 120
        let wholeAfter = try await authorPage(client, user, size: 50)
        KeysetWalk.expectMatches(
            walked.map(\.id), before: whole.map(\.id), after: wholeAfter.map(\.id), "journal"
        )
    }

    func authorPage(
        _ client: AteAPIClient, _ author: UUID, size: Int, after last: EntryCard? = nil
    ) async throws -> [EntryCard] {
        try await StagingRPC.rows(client, "get_entries_by_author", [
            "p_author_id": StagingRPC.id(author),
            "p_cursor_created_at": StagingRPC.maybeAt(last?.createdAt),
            "p_cursor_id": StagingRPC.maybeID(last?.id),
            "p_page_size": .integer(size)
        ])
    }
}
