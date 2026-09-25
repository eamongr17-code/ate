import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **`entry_cards.place.locality`** (migration 0035): the suburb the card foot line prints.
///
/// Decoded with a test-side row on purpose — the app's `EntryCard.Place` does not read the key yet,
/// and this suite is about what the server sends. Checked on the signed-in feed AND the signed-out
/// browse feed (the anon twins return the same view's rows), and against `place_summary.locality`,
/// so the card and the place header can never name two different suburbs.
///
/// Opt-in like its siblings: `ATE_CONTRACT_TESTS=1`, staging only. Read-only.
@Suite("Card place locality — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct CardLocalityContractTests {
    struct CardPlace: Decodable, Sendable {
        struct Place: Decodable, Sendable {
            let id: UUID
            let address: String?
            let locality: String?
        }
        let id: UUID
        let place: Place?
    }

    struct Header: Decodable, Sendable {
        let locality: String?
    }

    func feed(_ client: AteAPIClient) async throws -> [CardPlace] {
        try await StagingRPC.rows(client, "get_entry_feed", [
            "p_cursor_created_at": .null, "p_cursor_id": .null,
            "p_page_size": .integer(50), "p_include_own": .bool(true)
        ])
    }

    func check(_ client: AteAPIClient, _ label: String) async throws {
        let placed = try await feed(client).compactMap(\.place)
        #expect(placed.isEmpty == false, "\(label): the feed holds entries at a place")

        // An address with an AU state token always names a suburb; anything else may be null, but
        // never "" (absent is null on this contract).
        let tokens = [" VIC ", " NSW ", " QLD ", " SA ", " WA ", " TAS ", " NT ", " ACT "]
        for place in placed {
            #expect(place.locality != "", "\(label): locality is null or a suburb, never \"\"")
            if let address = place.address, tokens.contains(where: address.contains) {
                #expect(place.locality?.isEmpty == false, "\(label): \(address) names a suburb")
            }
        }

        // Same derivation as the place header.
        for place in placed.prefix(5) {
            let header: [Header] = try await StagingRPC.rows(
                client, "place_summary", ["p_restaurant_id": StagingRPC.id(place.id)]
            )
            #expect(header.first?.locality == place.locality, "\(label): card and header disagree")
        }
    }

    @Test("a signed-in card's place carries the suburb place_summary prints")
    func signedIn() async throws {
        try await check(StagingContract.Backend.shared.client(), "signed in")
    }

    @Test("a signed-out card's place carries it too (the browse twins return the same view)")
    func signedOut() async throws {
        try await check(AteAPIClient(supabase: StagingContract.makeClient()), "signed out")
    }
}
