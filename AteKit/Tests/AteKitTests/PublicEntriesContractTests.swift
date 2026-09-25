import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **Every entry is public** (migration 0033, CEO decision 2026-09-25), against staging.
///
/// These replace the private-only cases the suites used to carry ("yours includes private, a
/// stranger's is public-only"). What they guard now:
///
/// - **The flip left nothing behind.** No row the viewer can read says `private` — including the
///   viewer's own, which RLS always showed them.
/// - **The journal and the feed are one set.** Everything in my journal is in the global feed read
///   with `p_include_own = true`. Before 0033 a private entry was in the first and not the second;
///   that gap IS the removed feature, so its absence is the test.
/// - **A shipped client does not break, and cannot make anything private.** TestFlight builds still
///   send the "Make private" PATCH (the current app no longer has it). It must succeed — a 23514 there is
///   a broken client — land public, and leave `updated_at` alone: `updated_at > sorted_at` is the
///   entry_cards "words edited after the sort" hint, and a bumped stamp would strip the entry's
///   inline score/place tokens.
///
/// Opt-in like its siblings: `ATE_CONTRACT_TESTS=1`, staging only, never prod (rule 5). The one write
/// is a PATCH on the demo viewer's own entry that changes nothing once 0033 is applied — and is put
/// back if it ever does (i.e. if this runs against a staging that has not had 0033 yet).
@Suite("Every entry is public — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct PublicEntriesContractTests {
    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    func journal(_ client: AteAPIClient, _ author: UUID, size: Int) async throws -> [EntryCard] {
        try await StagingRPC.rows(client, "get_entries_by_author", [
            "p_author_id": StagingRPC.id(author),
            "p_cursor_created_at": .null,
            "p_cursor_id": .null,
            "p_page_size": .integer(size)
        ])
    }

    @Test("no entry the viewer can read is private — mine included")
    func noPrivateEntryRemains() async throws {
        let client = try await client()
        let response = try await client.supabase.from("entries")
            .select("id", head: true, count: .exact)
            .neq("visibility", value: "public")
            .execute()
        let count = try #require(response.count, "PostgREST returned no count header")
        #expect(count == 0, "0033 flips every entry public; \(count) readable entries still are not")
    }

    @Test("everything in my journal is in the global feed")
    func journalIsInTheFeed() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let me = try await client.requireCurrentUserID()
            let mine = try await journal(client, me, size: 50)
            let oldest = try #require(mine.last?.createdAt, "the demo viewer's journal is empty")
            #expect(mine.allSatisfy { $0.visibility == .public })

            // Walk the feed (own entries included) until it passes my oldest journal entry.
            var inFeed = Set<UUID>()
            var cursor: EntryCard?
            for _ in 0..<40 {
                let page: [EntryCard] = try await StagingRPC.rows(client, "get_entry_feed", [
                    "p_cursor_created_at": StagingRPC.maybeAt(cursor?.createdAt),
                    "p_cursor_id": StagingRPC.maybeID(cursor?.id),
                    "p_page_size": .integer(50),
                    "p_include_own": .bool(true)
                ])
                inFeed.formUnion(page.map(\.id))
                guard page.count == 50, let last = page.last, last.createdAt >= oldest else { break }
                cursor = last
            }

            let missing = mine.filter { inFeed.contains($0.id) == false }.map(\.orderNumber)
            #expect(missing.isEmpty, "journal entries the feed does not serve (order #): \(missing)")
        }
    }

    @Test("a shipped client's \"Make private\" succeeds, lands public, and leaves updated_at alone")
    func makePrivateIsANoOp() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let me = try await client.requireCurrentUserID()
            let service = SupabaseEntryService(api: client)
            let entry = try #require(
                try await journal(client, me, size: 5).first,
                "the demo viewer's journal is empty"
            )

            // The exact PATCH a build that still has the toggle sends (the app's `setVisibility` is
            // gone since #53; shipped TestFlight builds still make this call). Must not throw.
            func patchVisibility(_ value: String) async throws {
                _ = try await client.supabase.from("entries")
                    .update(["visibility": value], returning: .minimal)
                    .eq("id", value: entry.id.uuidString.lowercased())
                    .execute()
            }
            try await patchVisibility("private")
            let after = try await service.entry(id: entry.id)

            if after.visibility != .public {
                // Staging has not had 0033: put the demo entry back before failing.
                try await patchVisibility("public")
            }
            #expect(after.visibility == .public, "the trigger pins every entry public")
            #expect(
                after.updatedAt == entry.updatedAt,
                "a PATCH that changes nothing must not bump updated_at (the stale-offsets hint)"
            )
        }
    }
}
