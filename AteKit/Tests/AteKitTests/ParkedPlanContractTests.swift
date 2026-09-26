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
/// only (rule 5). It writes as the contract account and removes only the entry it minted, by its own
/// id. The dish rows a sort mints outlive their entry, so they are kept out of everyone's way: every
/// run names its own dish (a run id in the name, never a real menu's) at **one dedicated test
/// restaurant** that no real menu shares.
@Suite(
    "Parked plan — staging contract",
    .enabled(if: StagingContract.isEnabled && StagingContract.environmentValue("ATE_STAGING_WRITES") != nil),
    .serialized
)
struct ParkedPlanContractTests {

    private struct RestaurantRow: Decodable {
        let id: UUID
    }

    /// The contract's own restaurant, found by name — or added once, the way the app adds a place.
    private static let kitchen = "Ate Contract Kitchen"

    private func kitchenID(_ client: AteAPIClient) async throws -> UUID {
        let found = try await client.supabase.from("restaurants").select("id")
            .eq("name", value: Self.kitchen).limit(1).execute().data
        if let row = try JSONDecoder().decode([RestaurantRow].self, from: found).first { return row.id }
        let added: RestaurantRow = try await client.supabase
            .rpc("add_manual_restaurant", params: ["p_name": Self.kitchen, "p_city": "Melbourne"])
            .execute().value
        return added.id
    }

    @Test("placeless sorts to nothing; attaching the place prints the parked dishes")
    func parkedPlanPrintsOnceAPlaceIsAttached() async throws {
        let client = try await StagingContract.Backend.shared.client()
        let entries = SupabaseEntryService(api: client)
        let id = UUID()
        let author = try await entries.authorID()
        // A dish no menu has, unique to this run.
        let run = String(id.uuidString.prefix(6)).lowercased()
        // Nothing in the words may name the kitchen, or the sorter attaches it from them and nothing parks.
        let body = "\(Self.marker) The zq\(run) dumpling 4.0 was lovely."
        func remove() async {
            _ = try? await client.supabase.from("entries").delete()
                .eq("id", value: id.uuidString.lowercased())
                .eq("author_id", value: author.uuidString.lowercased())
                .execute()
        }

        _ = try await entries.create(NewEntry(
            id: id, authorID: author, body: body, restaurantID: nil, createdAt: Date()
        ))
        _ = try await entries.sort(entryID: id, force: false)
        let parked = try await entries.entry(id: id)
        #expect(parked.sortStatus == .sorted)
        #expect(parked.place == nil)
        #expect(parked.items.isEmpty, "no place, no lines: the plan is parked")

        let kitchen = try await kitchenID(client)
        let printed = try await entries.correctPlace(entryID: id, restaurantID: kitchen)
        #expect(printed.place?.id == kitchen)
        #expect(printed.items.isEmpty == false, "the parked plan prints once the place is attached")

        await remove()
        let gone = try? await entries.entry(id: id)
        #expect(gone == nil, "the synthetic entry is removed")
    }

    private static let marker = "Parked plan probe."
}
