import Foundation
import Supabase
import Testing

@testable import AteKit

/// A fixed test restaurant per aggregate test, and this run's entries at it — so the test asserts
/// on rows it can see whole rather than on whatever a shared place happens to hold.
///
/// Reading `restaurant_stats` and then `dish_stats` for a SHARED place is two reads of a database
/// other suites (and other CI runs) are writing to: a line landing between them made
/// `review_count 19 == 16` fail on 2026-09-26 with nothing wrong in either view.
///
/// The place is found-or-created once by a fixed, clearly-test name (`add_manual_restaurant`, no
/// coordinates, so it never surfaces in Nearby) and reused by every run; the oldest row of that
/// name wins, so two first runs that race converge on one. Only the entries are run-unique: every
/// body starts with ``marker`` and this run's tag, and the probe deletes them at the end (their
/// lines go with them, `on delete cascade`). The dishes are fixed names too, so nothing new is left
/// in search. Written through the app's own paths as a seeded DEMO author that is not Eamon's.
///
/// Another CI run can be writing at the same place, and a failed run can leave lines there, so the
/// assertions never assume the place holds only this run's rows: ``settled(_:)`` reads the raw
/// `reviews` at the place on both sides of the view reads, and the expected aggregates are derived
/// from that raw set.
struct StatsProbe: Sendable {
    static let marker = "Contract stats probe"
    static let author = (email: "marco@ate.test", password: "atedemo123")
    /// Entries this old under the marker are a failed run's; a live run's are seconds old.
    static let staleAfter: TimeInterval = 15 * 60

    let client: AteAPIClient
    let entries: SupabaseEntryService
    let place: UUID
    let run: String

    /// Signs in the demo author, finds the place, runs `body`, and deletes this run's entries
    /// whether or not `body` threw (plus any stale ones a failed run left).
    static func run(at placeName: String, _ body: @Sendable (StatsProbe) async throws -> Void) async throws {
        let supabase = StagingContract.makeClient()
        try await supabase.auth.signIn(email: author.email, password: author.password)
        let client = AteAPIClient(supabase: supabase)
        let probe = StatsProbe(
            client: client,
            entries: SupabaseEntryService(api: client),
            place: try await findOrCreate(placeName, client),
            run: String(UUID().uuidString.prefix(8)).lowercased()
        )
        try await probe.sweepStale()
        do {
            try await body(probe)
        } catch {
            try? await probe.sweepOwn()
            throw error
        }
        try await probe.sweepOwn()
    }

    static func findOrCreate(_ name: String, _ client: AteAPIClient) async throws -> UUID {
        struct Row: Decodable { let id: UUID }
        let found: [Row] = try await client.supabase.from(Restaurant.table).select("id")
            .eq("name", value: name).eq("source", value: RestaurantSource.manual.rawValue)
            .order("created_at").order("id").limit(1)
            .execute().value
        if let id = found.first?.id { return id }
        return try await RestaurantSearchService(api: client).addManual(name: name, city: nil, cuisine: nil).id
    }

    /// This run's entries, and nothing else.
    func sweepOwn() async throws {
        let me = try await client.requireCurrentUserID()
        try await client.supabase.from("entries").delete()
            .eq("author_id", value: me.uuidString.lowercased())
            .like("body", pattern: "\(Self.marker) \(run)%")
            .execute()
    }

    /// Marked entries a failed run left behind — old enough that no live run still owns them.
    func sweepStale() async throws {
        let me = try await client.requireCurrentUserID()
        try await client.supabase.from("entries").delete()
            .eq("author_id", value: me.uuidString.lowercased())
            .like("body", pattern: "\(Self.marker)%")
            .lt("created_at", value: PostgRESTTimestamp.string(from: Date().addingTimeInterval(-Self.staleAfter)))
            .execute()
    }

    /// Writes one entry at the probe's place, sorts it, and returns its receipt lines.
    @discardableResult
    func write(_ words: String) async throws -> [EntryCard.Item] {
        try await post(words).lines
    }

    /// An unscored line on `dish` — the normal case since 0018: they wrote about it, gave no number.
    ///
    /// The sorter only finds an unscored dish that is already on the place's menu, so a scored entry
    /// puts it there first (a no-op after the first run) and is then deleted with its line.
    func writeUnscored(_ dish: String) async throws -> EntryCard.Item {
        let menu = try await post("\(dish) 4")
        let seeded = try #require(menu.lines.first, "the sorter found no dish in \"\(dish) 4\"")
        try await client.supabase.from("entries").delete()
            .eq("id", value: menu.entry.uuidString.lowercased())
            .execute()

        let lines = try await write("The \(dish) looked the business.")
        let line = try #require(lines.first, "the sorter found no line for the known dish \(dish)")
        try #require(lines.count == 1 && line.dishID == seeded.dishID, "unexpected lines: \(lines)")
        try #require(line.score == nil, "a line with no number in it came back scored")
        return line
    }

    private func post(_ words: String) async throws -> (entry: UUID, lines: [EntryCard.Item]) {
        let me = try await client.requireCurrentUserID()
        let id = UUID()
        let body = "\(Self.marker) \(run). \(words)"
        try await entries.create(NewEntry(id: id, authorID: me, body: body, restaurantID: place, createdAt: Date()))
        try await entries.sort(entryID: id, force: false)
        let card = try await entries.entry(id: id)
        try #require(card.restaurantID == place, "the sorter moved the probe entry off its place")
        return (id, card.items)
    }

    // MARK: - Reads

    struct Line: Decodable, Hashable, Sendable {
        let id: UUID
        let dishID: UUID
        let score: Double?

        enum CodingKeys: String, CodingKey {
            case id, score
            case dishID = "dish_id"
        }
    }

    /// One consistent view of the place: the raw lines, and both views, read between two identical
    /// raw reads — so the views saw exactly `lines`.
    struct Snapshot: Sendable {
        let lines: Set<Line>
        let dishes: [DishStats]
        let restaurant: RestaurantStats
        /// The place's dishes as `score IS NULL` / `IS NOT NULL` find them, server-side.
        let nullDishes: Set<UUID>
        let scoredDishes: Set<UUID>

        func lines(of dish: UUID) -> [Line] { lines.filter { $0.dishID == dish } }

        /// What `dish_stats.score` must be: the mean of the dish's scores to one place, NULL when
        /// nobody scored it.
        func dishScore(_ dish: UUID) -> Decimal? {
            Self.mean(lines(of: dish).compactMap(\.score).map { Decimal($0) })
        }

        /// What `restaurant_stats.avg_rating` must be: the mean of the per-dish (rounded) scores,
        /// unrated dishes excluded — never the flat mean of the lines.
        var meanOfDishMeans: Decimal? {
            Self.mean(Set(lines.map(\.dishID)).compactMap(dishScore))
        }

        var flatMean: Decimal? {
            Self.mean(lines.compactMap(\.score).map { Decimal($0) })
        }

        /// `round(avg(x), 1)` as Postgres numeric does it: half away from zero, in decimal.
        static func mean(_ values: [Decimal]) -> Decimal? {
            guard values.isEmpty == false else { return nil }
            var average = values.reduce(0, +) / Decimal(values.count)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &average, 1, .plain)
            return rounded
        }

        /// A server numeric against the value derived in decimal; NULL matches only NULL.
        static func same(_ server: Double?, _ derived: Decimal?) -> Bool {
            server.flatMap { Decimal(string: "\($0)") } == derived
        }
    }

    /// A snapshot in which `shape` holds. Retries while another run's write lands mid-read or its
    /// transient rows break the shape; its entries live for seconds, so this settles quickly.
    func settled(_ shape: (Snapshot) -> Bool = { _ in true }) async throws -> Snapshot {
        let place = place.uuidString.lowercased()
        for _ in 0..<20 {
            let before = try await rawLines()
            let dishes = try await client.fetchAll(DishStats.self) { $0.eq("restaurant_id", value: place) }
            let restaurant = try await client.fetchByID(RestaurantStats.self, id: self.place)
            let null = try await client.fetchAll(DishStats.self) {
                $0.eq("restaurant_id", value: place).is("score", value: nil)
            }
            let scored = try await client.fetchAll(DishStats.self) {
                $0.eq("restaurant_id", value: place).not("score", operator: .is, value: "null")
            }
            let after = try await rawLines()
            let snapshot = Snapshot(
                lines: after, dishes: dishes, restaurant: restaurant,
                nullDishes: Set(null.map(\.dishID)), scoredDishes: Set(scored.map(\.dishID))
            )
            if before == after && shape(snapshot) { return snapshot }
            try await Task.sleep(for: .seconds(2))
        }
        Issue.record("the probe place never settled into the expected shape")
        throw AteAPIError.notFound(table: RestaurantStats.table, id: self.place)
    }

    private func rawLines() async throws -> Set<Line> {
        let rows: [Line] = try await client.supabase.from(Review.table).select("id,dish_id,score")
            .eq("restaurant_id", value: place.uuidString.lowercased())
            .range(from: 0, to: 999).execute().value
        try #require(rows.count < 1_000, "the probe place has grown past one read; sweep it")
        return Set(rows)
    }
}
