import Foundation
import Supabase
import Testing

@testable import AteKit

/// **A placeless entry, then a place — against staging** (QA 2026-09-26, defect 1). Written with no
/// place, the entry sorts with its plan parked: sorted, no lines, so the Summary must not print. The
/// place attached afterwards (`correct_entry_place`, exactly what the Summary's Place key calls)
/// applies the parked plan, and the receipt prints with its dishes.
///
/// This one WRITES, so it is opt-in twice: `ATE_CONTRACT_TESTS=1` and `ATE_STAGING_WRITES=1`, staging
/// only (rule 5). It writes as the contract account and deletes only the entry it minted, by its own id.
@Suite(
    "Parked plan — staging contract",
    .enabled(if: StagingContract.isEnabled && StagingContract.environmentValue("ATE_STAGING_WRITES") != nil),
    .serialized
)
struct ParkedPlanContractTests {

    private struct RestaurantRow: Decodable {
        let id: UUID
    }

    @Test("placeless sorts to nothing; attaching the place prints the parked dishes")
    func parkedPlanPrintsOnceAPlaceIsAttached() async throws {
        let client = try await StagingContract.Backend.shared.client()
        let entries = SupabaseEntryService(api: client)
        let id = UUID()
        let author = try await entries.authorID()
        // Provenance guard: only this account's rows carrying this exact synthetic body — a run that
        // died before its own clean-up is swept here, and nothing else can match.
        func sweep() async {
            _ = try? await client.supabase.from("entries").delete()
                .eq("author_id", value: author.uuidString.lowercased())
                .eq("body", value: Self.body)
                .execute()
        }
        await sweep()

        _ = try await entries.create(NewEntry(
            id: id, authorID: author, body: Self.body, restaurantID: nil, createdAt: Date()
        ))
        _ = try await entries.sort(entryID: id, force: false)
        let parked = try await entries.entry(id: id)
        #expect(parked.sortStatus == .sorted)
        #expect(parked.place == nil)
        #expect(parked.items.isEmpty, "no place, no lines: the plan is parked")

        let data = try await client.supabase.from("restaurants").select("id").limit(1).execute().data
        let restaurant = try #require(try JSONDecoder().decode([RestaurantRow].self, from: data).first)
        let printed = try await entries.correctPlace(entryID: id, restaurantID: restaurant.id)
        #expect(printed.place?.id == restaurant.id)
        #expect(printed.items.isEmpty == false, "the parked plan prints once the place is attached")

        await sweep()
        let gone = try? await entries.entry(id: id)
        #expect(gone == nil, "the synthetic entry is removed")
    }

    private static let body = "Contract check. The tiramisu 4.0 was lovely and the focaccia 3.5 was fine."
}
