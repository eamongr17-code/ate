import Foundation
import Supabase

/// **What the You tab gives back**: the histogram, the dishes behind one bar, and the statements.
///
/// One seam for the `0023` stats RPCs, because they are one screen's worth of reading and they all
/// take the same `p_user_id`. `profile_summary` is here too even though ``ProfileReading`` also
/// calls it — You is a profile header with `is_me` true, and one tab reading through two seams is
/// how half a screen ends up pointed at a different person.
public protocol StatsReading: Sendable {
    /// Who "you" is. Every call below is `p_user_id`, and on this tab it is always the viewer.
    func viewerID() async throws -> UUID
    /// `profile_summary(p_user_id)` — the handle, the city and the three totals.
    func summary(userID: UUID) async throws -> ProfileSummary
    /// `score_histogram(p_user_id)` — ten half-step buckets, zeros included.
    func histogram(userID: UUID) async throws -> ScoreHistogram
    /// `dishes_by_score(p_user_id, p_score, cursor…, p_limit)` — newest first, one row per review,
    /// keyset-paged on `(created_at, id)` like every other list.
    func dishes(
        userID: UUID, score: Double, after cursor: PageCursor?, pageSize: Int
    ) async throws -> Page<ScoredDish>
    /// `statement_months(p_user_id, p_tz, p_cursor_month, p_limit)` — newest first, paged on the
    /// month itself (the rows are one per month, so the month IS the cursor).
    func months(
        userID: UUID, timeZone: TimeZone, after cursor: StatementMonth?, limit: Int
    ) async throws -> [StatementMonthSummary]
    /// `monthly_statement(p_user_id, p_month, p_tz)`.
    func statement(userID: UUID, month: StatementMonth, timeZone: TimeZone) async throws -> MonthlyStatement
}

public extension StatsReading {
    func dishes(
        userID: UUID, score: Double, pageSize: Int = StatsClient.defaultDishLimit
    ) async throws -> Page<ScoredDish> {
        try await dishes(userID: userID, score: score, after: nil, pageSize: pageSize)
    }

    func months(
        userID: UUID, timeZone: TimeZone = .current, limit: Int = StatsClient.defaultMonthLimit
    ) async throws -> [StatementMonthSummary] {
        try await months(userID: userID, timeZone: timeZone, after: nil, limit: limit)
    }

    /// Every month there is, walked. Bounded by the person's own history — a year of writing is
    /// twelve rows — but it is still a page loop rather than one unbounded read.
    func allMonths(userID: UUID, timeZone: TimeZone = .current) async throws -> [StatementMonthSummary] {
        var collected: [StatementMonthSummary] = []
        var cursor: StatementMonth?
        let size = StatsClient.defaultMonthLimit
        while true {
            let page = try await months(userID: userID, timeZone: timeZone, after: cursor, limit: size)
            collected.append(contentsOf: page)
            guard page.count == size, let last = page.last?.month, last != cursor else { break }
            cursor = last
        }
        return collected
    }

    func statement(userID: UUID, month: StatementMonth) async throws -> MonthlyStatement {
        try await statement(userID: userID, month: month, timeZone: .current)
    }
}

public struct StatsClient: StatsReading {
    /// A page of a Ratings list.
    public static let defaultDishLimit = 50
    /// The server's own ceiling (`least(greatest(p_limit,1),500)`).
    public static let maximumDishLimit = 500
    /// `statement_months` pages at 60 — five years of writing in one read.
    public static let defaultMonthLimit = 60
    /// How many "Your 5.0s" the You tab draws — four tiles, as the artboard sets them.
    public static let perfectLimit = 4

    private let api: AteAPIClient
    private let profiles: ProfileClient

    public init(api: AteAPIClient) {
        self.api = api
        self.profiles = ProfileClient(api: api)
    }

    public func viewerID() async throws -> UUID {
        try await api.requireCurrentUserID()
    }

    /// Through ``ProfileClient``, not a second copy of the call: the header on You and the header on
    /// somebody else's page are the same row, decoded by the same type.
    public func summary(userID: UUID) async throws -> ProfileSummary {
        try await profiles.profile(id: userID)
    }

    public func histogram(userID: UUID) async throws -> ScoreHistogram {
        let rows: [ScoreBucket] = try await decode(
            "score_histogram",
            parameters: ["p_user_id": .string(userID.uuidString.lowercased())]
        )
        return ScoreHistogram(rows)
    }

    /// Keyset-paged on `(created_at, id)`, the same contract the feed walks: pass the LAST row's
    /// pair back, never an offset.
    public func dishes(
        userID: UUID, score: Double, after cursor: PageCursor?, pageSize: Int
    ) async throws -> Page<ScoredDish> {
        let limit = min(Self.maximumDishLimit, max(1, pageSize))
        var parameters: [String: AnyJSON] = [
            "p_user_id": .string(userID.uuidString.lowercased()),
            "p_score": .double(ScoreHistogram.snapped(score)),
            "p_limit": .integer(limit)
        ]
        parameters["p_cursor_created_at"] = cursor
            .map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null
        parameters["p_cursor_id"] = cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null
        let rows: [ScoredDish] = try await decode("dishes_by_score", parameters: parameters)
        return Page(items: rows, requestedLimit: limit)
    }

    /// Paged on the month itself — one row per month, so the month IS the cursor, and it travels
    /// as the same `YYYY-MM-01` string `monthly_statement` takes.
    public func months(
        userID: UUID, timeZone: TimeZone, after cursor: StatementMonth?, limit: Int
    ) async throws -> [StatementMonthSummary] {
        var parameters: [String: AnyJSON] = [
            "p_user_id": .string(userID.uuidString.lowercased()),
            "p_tz": .string(timeZone.identifier),
            "p_limit": .integer(max(1, limit))
        ]
        parameters["p_cursor_month"] = cursor.map { .string($0.parameter) } ?? .null
        return try await decode("statement_months", parameters: parameters)
    }

    public func statement(
        userID: UUID,
        month: StatementMonth,
        timeZone: TimeZone
    ) async throws -> MonthlyStatement {
        try await decode("monthly_statement", parameters: [
            "p_user_id": .string(userID.uuidString.lowercased()),
            "p_month": .string(month.parameter),
            "p_tz": .string(timeZone.identifier)
        ])
    }

    /// One decoder for all four, so a `timestamptz` is read the same way it is everywhere else
    /// (``PostgRESTDate`` — PostgREST keeps microseconds and `ISO8601FormatStyle` does not).
    private func decode<Row: Decodable & Sendable>(
        _ function: String,
        parameters: [String: AnyJSON]
    ) async throws -> Row {
        let data = try await api.supabase.rpc(function, params: parameters).execute().data
        return try PostgRESTDate.decoder.decode(Row.self, from: data)
    }
}
