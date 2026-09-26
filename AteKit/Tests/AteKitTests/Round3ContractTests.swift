import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **Round 3 backend** (migrations 0037–0040 + `sort-entry` preview), against staging.
///
/// The contract the iOS lanes build to:
/// - **Delete entry:** `rpc delete_entry(p_entry_id)` → `{photo_paths: [String]}` — bucket-relative
///   `review-photos` names (`<uid>/<file>`, originals AND their `_t.jpg` thumbnails). Owner only (`42501`),
///   `P0002` once it is gone. The client then `storage.from("review-photos").remove(paths:)`.
/// - **Feed area:** `rpc feed_areas()` → `[{area, entry_count}]` busiest first; `get_entry_feed(…, p_area)`
///   keeps only entries whose `place.locality` is that area. Both answer signed out.
/// - **Early sort:** `sort-entry {preview: true, body, tag_tokens, restaurant_id}` returns a plan and writes
///   NO entry and NO line.
/// - **Place required:** an `entries` INSERT without `restaurant_id` is `23502` `place_required` — skipped
///   until 0040 is on staging (it waits for the place-required build).
/// - **Thumbnails:** `<path minus extension>_t.jpg` uploads under the owner's folder (no policy change).
///
/// Writes are staging-only synthetic rows under the seeded DEMO account `jess` (not Eamon's), every body
/// carries the `Contract round3 probe` marker, and the suite deletes exactly what it made (plus anything
/// a failed earlier run left, found by that marker under that author). Needs 0037–0040 applied to staging
/// AND this PR's `sort-entry` deployed there.
@Suite("Round 3 — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct Round3ContractTests {
    static let marker = "Contract round3 probe"
    static let author = (email: "jess@ate.test", password: "atedemo123")

    struct Deleted: Decodable, Sendable {
        let photoPaths: [String]
        enum CodingKeys: String, CodingKey { case photoPaths = "photo_paths" }
    }

    struct PhotoRow: Encodable, Sendable {
        let entryID: String
        let position: Int
        let photoURL: String
        enum CodingKeys: String, CodingKey {
            case position
            case entryID = "entry_id"
            case photoURL = "photo_url"
        }
    }

    struct Area: Decodable, Sendable {
        let area: String
        let entryCount: Int
        enum CodingKeys: String, CodingKey {
            case area
            case entryCount = "entry_count"
        }
    }

    struct FeedRow: Decodable, Sendable {
        struct Place: Decodable, Sendable { let locality: String? }
        let id: UUID
        let place: Place?
    }

    struct PreviewRequest: Encodable, Sendable {
        let preview = true
        let body: String
        let restaurantID: String
        let tagTokens: [TagToken]
        enum CodingKeys: String, CodingKey {
            case preview, body
            case restaurantID = "restaurant_id"
            case tagTokens = "tag_tokens"
        }
    }

    struct TagToken: Encodable, Sendable {
        let offset: Int
        let length: Int
    }

    struct PreviewItem: Decodable, Sendable {
        let dishName: String
        let tags: [String]?
        enum CodingKeys: String, CodingKey {
            case tags
            case dishName = "dish_name"
        }
    }

    struct PreviewReply: Decodable, Sendable {
        let ok: Bool?
        let preview: Bool?
        let cached: Bool?
        let mode: String?
        let entryID: String?
        let items: [PreviewItem]
        enum CodingKeys: String, CodingKey {
            case ok, preview, cached, mode, items
            case entryID = "entry_id"
        }
    }

    // MARK: - Staging plumbing

    func signIn() async throws -> AteAPIClient {
        let supabase = StagingContract.makeClient()
        try await supabase.auth.signIn(email: Self.author.email, password: Self.author.password)
        return AteAPIClient(supabase: supabase)
    }

    func somePlace(_ client: AteAPIClient) async throws -> UUID {
        struct Row: Decodable { let id: UUID }
        let rows: [Row] = try await client.supabase.from("restaurants").select("id").order("id").limit(1)
            .execute().value
        return try #require(rows.first?.id, "staging holds no restaurant")
    }

    func write(_ client: AteAPIClient, _ body: String, at place: UUID?) async throws -> UUID {
        let id = UUID()
        let me = try await client.requireCurrentUserID()
        let entry = NewEntry(id: id, authorID: me, body: body, restaurantID: place, createdAt: Date())
        try await client.supabase.from("entries").insert(entry, returning: .minimal).execute()
        return id
    }

    func count(_ client: AteAPIClient, _ table: String, _ column: String) async throws -> Int {
        let me = try await client.requireCurrentUserID()
        let response = try await client.supabase.from(table).select("id", head: true, count: .exact)
            .eq(column, value: me.uuidString.lowercased()).execute()
        return try #require(response.count, "PostgREST returned no count header")
    }

    func readable(_ client: AteAPIClient, _ entry: UUID) async throws -> Bool {
        struct Row: Decodable { let id: UUID }
        let rows: [Row] = try await client.supabase.from("entry_cards").select("id")
            .eq("id", value: entry.uuidString.lowercased()).execute().value
        return rows.isEmpty == false
    }

    /// Deletes this suite's own synthetic entries: the demo author's, carrying the marker. Nothing else.
    func sweep(_ client: AteAPIClient) async throws {
        let me = try await client.requireCurrentUserID()
        try await client.supabase.from("entries").delete()
            .eq("author_id", value: me.uuidString.lowercased())
            .like("body", pattern: "\(Self.marker)%")
            .execute()
    }

    func guarded(_ drive: @Sendable (AteAPIClient) async throws -> Void) async throws {
        try await StagingExclusive.shared.run {
            let jess = try await signIn()
            try await sweep(jess)
            do {
                try await drive(jess)
            } catch {
                try? await sweep(jess)
                throw error
            }
            try await sweep(jess)
        }
    }

    // MARK: - The contract

    @Test("delete_entry: owner only, returns the photo paths (+ thumbnails), and the entry is gone everywhere")
    func deleteEntry() async throws {
        try await guarded { jess in
            let place = try await somePlace(jess)
            let entry = try await write(jess, "\(Self.marker) tiramisu 4.0", at: place)
            _ = try? await jess.supabase.functions.invoke(
                "sort-entry",
                options: FunctionInvokeOptions(method: .post, body: ["entry_id": entry.uuidString.lowercased()])
            )

            // A real photo and its thumbnail, next to each other — the thumbnail proves the owner-path
            // storage policy admits `_t.jpg` (round 3, item 5).
            let me = try await jess.requireCurrentUserID().uuidString.lowercased()
            let original = "\(me)/\(entry.uuidString.lowercased())-0.jpg"
            let thumbnail = "\(me)/\(entry.uuidString.lowercased())-0_t.jpg"
            let bucket = jess.supabase.storage.from("review-photos")
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
            let jpegOptions = FileOptions(contentType: "image/jpeg", upsert: true)
            _ = try await bucket.upload(original, data: jpeg, options: jpegOptions)
            _ = try await bucket.upload(thumbnail, data: jpeg, options: jpegOptions)
            let url = try bucket.getPublicURL(path: original).absoluteString
            try await jess.supabase.from("entry_photos")
                .insert(PhotoRow(entryID: entry.uuidString.lowercased(), position: 0, photoURL: url),
                        returning: .minimal)
                .execute()

            // Owner only.
            let eamon = try await StagingContract.Backend.shared.client()
            do {
                _ = try await eamon.supabase.rpc("delete_entry", params: ["p_entry_id": StagingRPC.id(entry)]).execute()
                Issue.record("a stranger deleted the entry")
            } catch {
                #expect((error as? PostgrestError)?.code == "42501", "stranger delete: \(error)")
            }
            #expect(try await readable(jess, entry), "a refused delete must leave the entry")

            let target: [String: AnyJSON] = ["p_entry_id": StagingRPC.id(entry)]
            let deleted: Deleted = try await StagingRPC.value(jess, "delete_entry", target)
            #expect(Set(deleted.photoPaths) == [original, thumbnail], "photo_paths: \(deleted.photoPaths)")

            let removed = try await bucket.remove(paths: deleted.photoPaths)
            #expect(removed.count == 2, "the owner removes both files with the returned paths")

            #expect(try await readable(jess, entry) == false, "gone from entry_cards")
            #expect(try await readable(eamon, entry) == false, "gone for other viewers")
            let feed: [FeedRow] = try await StagingRPC.rows(eamon, "get_entry_feed", ["p_page_size": .integer(50)])
            #expect(feed.contains { $0.id == entry } == false, "gone from the feed")

            do {
                _ = try await jess.supabase.rpc("delete_entry", params: ["p_entry_id": StagingRPC.id(entry)]).execute()
                Issue.record("a second delete succeeded")
            } catch {
                #expect((error as? PostgrestError)?.code == "P0002", "already gone: \(error)")
            }
        }
    }

    @Test("feed_areas lists localities busiest first; get_entry_feed(p_area) keeps only that area, signed in and out")
    func feedAreas() async throws {
        let eamon = try await StagingContract.Backend.shared.client()
        let anon = AteAPIClient(supabase: StagingContract.makeClient())
        for viewer in [eamon, anon] {
            let areas: [Area] = try await StagingRPC.rows(viewer, "feed_areas")
            #expect(areas.map(\.entryCount) == areas.map(\.entryCount).sorted(by: >), "busiest first")
            #expect(areas.allSatisfy { $0.entryCount > 0 && $0.area.isEmpty == false })
            guard let top = areas.first else { continue }

            // Keyset: (entry_count desc, area asc) — page 2 starts right after page 1's last row.
            let pageOne: [Area] = try await StagingRPC.rows(viewer, "feed_areas", ["p_limit": .integer(1)])
            #expect(pageOne.first?.area == top.area)
            let pageTwo: [Area] = try await StagingRPC.rows(viewer, "feed_areas", [
                "p_limit": .integer(1),
                "p_cursor_entry_count": .integer(top.entryCount),
                "p_cursor_area": .string(top.area)
            ])
            #expect(pageTwo.first?.area == areas.dropFirst().first?.area, "the keyset skips nothing")

            let page: [FeedRow] = try await StagingRPC.rows(viewer, "get_entry_feed", [
                "p_page_size": .integer(50), "p_area": .string(top.area)
            ])
            #expect(page.isEmpty == false, "a listed area has a non-empty feed")
            #expect(page.count <= top.entryCount)
            #expect(page.allSatisfy { $0.place?.locality?.lowercased() == top.area.lowercased() },
                    "every row is in \(top.area)")
        }
        // No p_area → today's feed, unchanged in shape.
        let everywhere: [FeedRow] = try await StagingRPC.rows(eamon, "get_entry_feed", ["p_page_size": .integer(5)])
        #expect(everywhere.isEmpty == false)
    }

    @Test("a preview sort returns a plan and writes no entry and no line")
    func previewWritesNothing() async throws {
        try await guarded { jess in
            let place = try await somePlace(jess)
            let entriesBefore = try await count(jess, "entries", "author_id")
            let linesBefore = try await count(jess, "reviews", "reviewer_id")

            let body = "\(Self.marker) pasta 4.5 GF and the tiramisu 3.5"
            let gf = try #require(body.range(of: "GF"))
            let offset = body.unicodeScalars.distance(from: body.unicodeScalars.startIndex, to: gf.lowerBound)
            let reply: PreviewReply = try await jess.supabase.functions.invoke(
                "sort-entry",
                options: FunctionInvokeOptions(method: .post, body: PreviewRequest(
                    body: body, restaurantID: place.uuidString.lowercased(),
                    tagTokens: [TagToken(offset: offset, length: 2)]
                ))
            )
            #expect(reply.ok == true && reply.preview == true)
            #expect(reply.entryID == nil)
            #expect(reply.items.isEmpty == false, "the draft names two dishes")

            #expect(try await count(jess, "entries", "author_id") == entriesBefore, "a preview wrote an entry")
            #expect(try await count(jess, "reviews", "reviewer_id") == linesBefore, "a preview wrote a line")
        }
    }

    /// Is 0040 on staging? It is applied only once the place-required build ships, so its test SKIPS
    /// until then. The probe WRITES NOTHING: jess inserts a placeless entry in someone else's name.
    /// BEFORE triggers run before RLS's WITH CHECK, so with 0040 the place trigger answers `23502`;
    /// without it the row reaches RLS and is refused `42501`. Either way the statement rolls back.
    static func placeRequiredApplied() async throws -> Bool {
        guard StagingContract.isEnabled else { return false }
        let other = try await StagingContract.Backend.shared.client().requireCurrentUserID()
        let supabase = StagingContract.makeClient()
        try await supabase.auth.signIn(email: author.email, password: author.password)
        let probe = NewEntry(id: UUID(), authorID: other, body: "\(marker) 0040 probe", restaurantID: nil,
                             createdAt: Date())
        do {
            try await supabase.from("entries").insert(probe, returning: .minimal).execute()
            return false
        } catch {
            return (error as? PostgrestError)?.code == "23502"
        }
    }

    @Test(
        "a new entry without a place is refused: 23502 place_required",
        .enabled("migration 0040 is applied to staging") { try await Round3ContractTests.placeRequiredApplied() }
    )
    func placeRequired() async throws {
        try await guarded { jess in
            let id = UUID()
            do {
                let me = try await jess.requireCurrentUserID()
                let entry = NewEntry(id: id, authorID: me, body: "\(Self.marker) no place", restaurantID: nil,
                                     createdAt: Date())
                try await jess.supabase.from("entries").insert(entry, returning: .minimal).execute()
                Issue.record("a placeless entry landed")
            } catch {
                let postgrest = error as? PostgrestError
                #expect(postgrest?.code == "23502", "code: \(error)")
                #expect(postgrest?.message == "place_required", "message: \(error)")
            }
            let landed = try await readable(jess, id)
            #expect(landed == false)
        }
    }
}
