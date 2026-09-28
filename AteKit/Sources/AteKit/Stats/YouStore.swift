import Foundation
import Observation

/// **The You tab's state**: who you are, what you gave, what you loved, and this month's statement.
///
/// Five reads, and they fail independently on purpose. The header is the only one that can empty the
/// screen — a histogram that 500s should cost you the chart, not your own name — so everything below
/// it degrades to absent. Design rule 1 forbids helper copy, and "couldn't load your ratings" is
/// exactly that; a band with nothing behind it is simply not drawn.
@MainActor
@Observable
public final class YouStore {

    public enum Phase: Sendable, Equatable {
        case loading
        case ready(ProfileSummary)
        /// Nobody is signed in, or the header could not be read.
        case unavailable
    }

    public private(set) var phase: Phase = .loading
    public private(set) var histogram = ScoreHistogram.empty
    /// "Your top dishes" (round 6) — the four the artboard draws: best score first, 4.0 and up
    /// (``TopDishes``).
    public private(set) var top: [ScoredDish] = []
    /// The newest month that has anything in it. `nil` before anything has been written — and then
    /// there is no statement row, because nothing has been printed (design rule 4).
    public private(set) var month: StatementMonth?

    private let stats: any StatsReading
    private let timeZone: TimeZone
    private var hasLoaded = false

    public init(stats: any StatsReading, timeZone: TimeZone = .current) {
        self.stats = stats
        self.timeZone = timeZone
    }

    /// The summary, once it is known.
    public var summary: ProfileSummary? {
        if case .ready(let summary) = phase { return summary }
        return nil
    }

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await load()
    }

    public func refresh() async {
        await load()
    }

    private func load() async {
        guard let viewer = try? await stats.viewerID() else {
            // Signed out — and **not** latched: a session can arrive late (a first-run sign-in, a
            // token refreshed on return to the app), and a tab that gave up once would stay empty
            // for the rest of the launch.
            phase = .unavailable
            return
        }
        async let header = try? await stats.summary(userID: viewer)
        async let chart = try? await stats.histogram(userID: viewer)
        // Only the newest month is drawn, so only the first page is read — the rest is `Recap`'s.
        async let calendar = try? await stats.months(
            userID: viewer, timeZone: timeZone, after: nil, limit: 1
        )

        let (summary, buckets, months) = await (header, chart, calendar)
        hasLoaded = true
        phase = summary.map(Phase.ready) ?? .unavailable
        if let buckets { histogram = buckets }
        if let months { month = StatementMonths(summaries: months).newest }
        // The chart says which scores hold a top dish, so only those are read, best first.
        let stats = stats
        let scores = TopDishes.scores(in: buckets)
        if let dishes = await TopDishes.read(scores: scores, page: { score in
            try await stats.dishes(userID: viewer, score: score, after: nil, pageSize: TopDishes.limit).items
        }) {
            top = dishes
        }
    }
}
