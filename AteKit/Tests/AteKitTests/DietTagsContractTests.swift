import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **Dietary tags on the wire, against staging** (contract #61, migration 0036).
///
/// Read-only on purpose: the account these run as also holds real entries, so the suite proves the
/// row shape the app decodes — every line carries `tags`, an array, never null, of the five known
/// codes in order — and leaves writing to the unit tests of the request encoding. Tags are read from
/// `entry_cards` only, never from the sort reply (a forced re-sort answers `tags: []` while the
/// database keeps each line's inherited set).
///
/// Opt-in like the rest: `ATE_CONTRACT_TESTS=1`, staging only (rule 5).
@Suite("Dietary tags — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct DietTagsContractTests {

    @Test("every entry_cards line carries tags: an array, never null, of known codes")
    func linesCarryTags() async throws {
        let client = try await StagingContract.Backend.shared.client()
        let data = try await client.supabase
            .from(EntryCard.table)
            .select(EntryCard.columns)
            .order("created_at", ascending: false)
            .limit(50)
            .execute()
            .data

        // The raw shape first: the key is there on every line, and it is an array.
        let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let lines = rows.flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
        #expect(lines.isEmpty == false, "no lines on staging can't test the lines' shape")
        for line in lines {
            let tags = line["tags"]
            #expect(tags is [String], "tags: an array on every line, never null: \(String(describing: tags))")
            for code in (tags as? [String]) ?? [] {
                #expect(DietTag(rawValue: code) != nil, "\(code) is not one of gf, df, v, vg, nf")
            }
        }

        // …and the app's own decode agrees with it, order kept.
        let cards = try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
        let decoded = cards.flatMap(\.items).map { $0.tags.map(\.rawValue) }
        let raw = lines.map { ($0["tags"] as? [String]) ?? [] }
        #expect(decoded == raw)
    }
}
