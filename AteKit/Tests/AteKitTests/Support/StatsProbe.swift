import Foundation
import Supabase
import Testing

@testable import AteKit

/// A restaurant of this run's own, and the entries written at it — so an aggregate test asserts on
/// rows it made rather than on whatever staging happens to hold.
///
/// Reading `restaurant_stats` and then `dish_stats` for a SHARED place is two reads of a database
/// other suites (and other CI runs) are writing to: a line landing between them made
/// `review_count 19 == 16` fail on 2026-09-26 with nothing wrong in either view. Nobody else writes
/// at a place minted a moment ago under a run-unique name, so both reads see the same rows.
///
/// Every write goes through the app's own paths — `add_manual_restaurant`, an `entries` insert and
/// `sort-entry` — as a seeded DEMO author that is not Eamon's (his real entries share his account).
/// Every body starts with ``marker``; the probe deletes exactly its own entries (their lines go with
/// them, `on delete cascade`), plus any a failed earlier run left under that author. The restaurant
/// and its dishes stay: RLS gives end users no delete on either, by design (0008, 0004).
struct StatsProbe: Sendable {
    static let marker = "Contract stats probe"
    static let author = (email: "marco@ate.test", password: "atedemo123")

    let client: AteAPIClient
    let entries: SupabaseEntryService
    let place: UUID

    /// Signs in the demo author, sweeps leftovers, mints the place, runs `body`, and deletes the
    /// entries whether or not `body` threw.
    static func run(_ body: @Sendable (StatsProbe) async throws -> Void) async throws {
        let supabase = StagingContract.makeClient()
        try await supabase.auth.signIn(email: author.email, password: author.password)
        let client = AteAPIClient(supabase: supabase)
        try await sweep(client)

        let run = UUID().uuidString.prefix(8).lowercased()
        let place = try await RestaurantSearchService(api: client)
            .addManual(name: "\(marker) \(run)", city: nil, cuisine: nil)
        let probe = StatsProbe(client: client, entries: SupabaseEntryService(api: client), place: place.id)
        do {
            try await body(probe)
        } catch {
            try? await sweep(client)
            throw error
        }
        try await sweep(client)
    }

    /// This author's marked entries, and nothing else.
    static func sweep(_ client: AteAPIClient) async throws {
        let me = try await client.requireCurrentUserID()
        try await client.supabase.from("entries").delete()
            .eq("author_id", value: me.uuidString.lowercased())
            .like("body", pattern: "\(marker)%")
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
    /// puts it there first and is then deleted (its line goes with it; the dish stays).
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
        let body = "\(Self.marker). \(words)"
        try await entries.create(NewEntry(id: id, authorID: me, body: body, restaurantID: place, createdAt: Date()))
        try await entries.sort(entryID: id, force: false)
        let card = try await entries.entry(id: id)
        try #require(card.restaurantID == place, "the sorter moved the probe entry off its place")
        return (id, card.items)
    }

    func dishStats() async throws -> [DishStats] {
        try await client.fetchAll(DishStats.self) { $0.eq("restaurant_id", value: place.uuidString.lowercased()) }
    }

    func restaurantStats() async throws -> RestaurantStats {
        try await client.fetchByID(RestaurantStats.self, id: place)
    }
}
