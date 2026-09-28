import Foundation
import Supabase
import Testing

@testable import AteKit

/// **Round 6 backend** (0050 date windows; 0051's menu order is pinned in `DetailRPCContractTests` and
/// `PlaceDishContractTests`), against staging. Read-only: it reads the round-6 staging dataset.
///
/// - Search (`search_places`, `search_dishes`, `nearby_places`) and Saved (`search_saved`) take
///   `p_from` / `p_to` / `p_tz` — inclusive calendar days, my_entries' rule. With a window, Search's
///   numbers are the window's lines only (never more than all-time) and a row with no line in the
///   window is not a result; Saved filters on the day the dish was saved.
@Suite("Round 6 — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct Round6ContractTests {
    static let zone = "Australia/Melbourne"

    struct Place: Decodable, Sendable {
        let restaurantID: UUID
        let reviewCount: Int
        let dishCount: Int
        enum CodingKeys: String, CodingKey {
            case restaurantID = "restaurant_id"
            case reviewCount = "review_count"
            case dishCount = "dish_count"
        }
    }

    struct DishRow: Decodable, Sendable {
        let dishID: UUID
        let reviewCount: Int
        let scoredCount: Int
        enum CodingKeys: String, CodingKey {
            case dishID = "dish_id"
            case reviewCount = "review_count"
            case scoredCount = "scored_count"
        }
    }

    struct Saved: Decodable, Sendable {
        let dishID: UUID
        let savedAt: Date
        enum CodingKeys: String, CodingKey {
            case dishID = "dish_id"
            case savedAt = "saved_at"
        }
    }

    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func window(_ from: Date?, _ to: Date?) -> [String: AnyJSON] {
        [
            "p_from": from.map { .string(day($0)) } ?? .null,
            "p_to": to.map { .string(day($0)) } ?? .null,
            "p_tz": .string(zone)
        ]
    }

    @Test("Search with a date window counts only the window's lines; a future window finds nothing")
    func searchWindow() async throws {
        let client = try await StagingContract.Backend.shared.client()
        let now = Date()
        let quarter = now.addingTimeInterval(-90 * 86_400)
        var recentRows = 0
        for query in ["ba", "ca", "ra"] {
            let base: [String: AnyJSON] = ["p_query": .string(query), "p_limit": .integer(50)]
            let allTime: [Place] = try await StagingRPC.rows(client, "search_places", base)
            let recent: [Place] = try await StagingRPC.rows(
                client, "search_places", base.merging(Self.window(quarter, now)) { $1 }
            )
            recentRows += recent.count
            let totals = Dictionary(allTime.map { ($0.restaurantID, $0.reviewCount) }, uniquingKeysWith: { a, _ in a })
            for row in recent {
                #expect(row.reviewCount > 0, "a place with no line in the window is not a result")
                if let total = totals[row.restaurantID] {
                    #expect(row.reviewCount <= total, "a window never counts more than all time")
                }
            }
            let future: [Place] = try await StagingRPC.rows(
                client, "search_places", base.merging(Self.window(now.addingTimeInterval(3 * 86_400), nil)) { $1 }
            )
            #expect(future.isEmpty, "nothing has been eaten after today")

            let dishes: [DishRow] = try await StagingRPC.rows(
                client, "search_dishes", base.merging(Self.window(quarter, now)) { $1 }
            )
            #expect(dishes.allSatisfy { $0.reviewCount > 0 && $0.scoredCount <= $0.reviewCount })
        }
        // Staging's seeded diners ate out all quarter: a window that finds nothing is the bug, not an answer.
        #expect(recentRows > 0, "the last 90 days found no place at all")
        let near: [Place] = try await StagingRPC.rows(client, "nearby_places", [
            "p_lat": .double(-37.8136), "p_lng": .double(144.9631), "p_radius_m": .double(20_000),
            "p_from": .string("2000-01-01"), "p_to": .string("2000-12-31"), "p_tz": .string(Self.zone)
        ])
        #expect(near.isEmpty, "no line was eaten in 2000")
    }

    @Test("Saved filters by the day the dish was saved")
    func savedWindow() async throws {
        let client = try await StagingContract.Backend.shared.client()
        let base: [String: AnyJSON] = ["p_query": .null, "p_limit": .integer(50)]
        let shelf: [Saved] = try await StagingRPC.rows(client, "search_saved", base)
        let newest = try #require(shelf.first, "the demo account's shelf is empty")
        let thatDay: [Saved] = try await StagingRPC.rows(
            client, "search_saved", base.merging(Self.window(newest.savedAt, newest.savedAt)) { $1 }
        )
        #expect(thatDay.contains { $0.dishID == newest.dishID }, "inclusive: the day it was saved is in")
        #expect(thatDay.allSatisfy { Self.day($0.savedAt) == Self.day(newest.savedAt) })
        let before: [Saved] = try await StagingRPC.rows(
            client, "search_saved", base.merging(Self.window(nil, Date(timeIntervalSince1970: 0))) { $1 }
        )
        #expect(before.isEmpty)
        let anon = AteAPIClient(supabase: StagingContract.makeClient())
        do {
            let _: [Saved] = try await StagingRPC.rows(anon, "search_saved", base)
            Issue.record("anon read a shelf")
        } catch {}
    }
}
