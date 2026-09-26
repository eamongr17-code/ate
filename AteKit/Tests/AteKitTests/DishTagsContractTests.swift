import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **Dietary tags on dish lines** (migration 0036 + `sort-entry` `tag_tokens`), against staging.
///
/// The contract the iOS lane builds to:
/// - **Every** `entry_cards.items[]` carries `tags: [String]` — lowercase codes from `gf df v vg nf`,
///   deduped, in that order, `[]` (never null) when none. Signed out too: the browse twins return the
///   same view's rows.
/// - **Compose:** a tag chip prints its word in the body, and the client sends where it is in
///   `sort-entry`'s `tag_tokens: [{offset, length}]` (UNICODE SCALARS, like every offset here). The
///   sorter puts it on the dish it follows. The same word in prose, unmarked, tags nothing.
/// - **Per line, after the sort:** `PATCH /rest/v1/reviews?id=eq.<id> {"tags": [...]}` — the call that
///   sets a score. Canonicalised server-side; an unknown code is `23514`; owner only (RLS); NOT a
///   correction. A forced re-sort never removes a tag.
/// - **`dish_summary.tags`** = codes at least half the dish's lines carry (and at least one).
///
/// Writes are staging-only synthetic rows under a seeded DEMO account that is not Eamon's (`jess`),
/// every body carries the `Contract tag probe` marker, and the test deletes exactly the entries it
/// created (plus any a failed earlier run left, found by that marker under that author). Needs 0036
/// applied to staging AND this PR's `sort-entry` deployed there.
@Suite("Dish tags — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct DishTagsContractTests {
    static let marker = "Contract tag probe"
    static let author = (email: "jess@ate.test", password: "atedemo123")

    struct Line: Decodable, Sendable {
        let reviewID: UUID
        let dishID: UUID
        let dishName: String
        let tags: [String]
        let corrected: Bool

        enum CodingKeys: String, CodingKey {
            case tags, corrected
            case reviewID = "review_id"
            case dishID = "dish_id"
            case dishName = "dish_name"
        }
    }

    struct Card: Decodable, Sendable {
        let id: UUID
        let items: [Line]

        func line(_ dish: String) throws -> Line {
            try #require(items.first { $0.dishName.lowercased().contains(dish) }, "no \(dish) line in \(items)")
        }
    }

    struct Summary: Decodable, Sendable {
        let reviewCount: Int
        let tags: [String]

        enum CodingKeys: String, CodingKey {
            case tags
            case reviewCount = "review_count"
        }
    }

    struct TagToken: Encodable, Sendable {
        let offset: Int
        let length: Int
    }

    struct SortRequest: Encodable, Sendable {
        let entryID: UUID
        let force: Bool
        let tagTokens: [TagToken]

        enum CodingKeys: String, CodingKey {
            case force
            case entryID = "entry_id"
            case tagTokens = "tag_tokens"
        }
    }

    struct SortReply: Decodable, Sendable {
        let ok: Bool?
    }

    /// Where `word` sits inside the first occurrence of `context`, as the client must send it:
    /// UNICODE SCALARS, not UTF-16.
    static func token(_ word: String, in context: String, of body: String) throws -> TagToken {
        let outer = try #require(body.range(of: context), "\(context) is not in the body")
        let inner = try #require(body.range(of: word, range: outer), "\(word) is not in \(context)")
        let scalars = body.unicodeScalars
        return TagToken(
            offset: scalars.distance(from: scalars.startIndex, to: inner.lowerBound),
            length: word.unicodeScalars.count
        )
    }

    // MARK: - Staging plumbing

    func author() async throws -> AteAPIClient {
        let supabase = StagingContract.makeClient()
        try await supabase.auth.signIn(email: Self.author.email, password: Self.author.password)
        return AteAPIClient(supabase: supabase)
    }

    func write(_ client: AteAPIClient, _ body: String, at place: UUID) async throws -> UUID {
        let id = UUID()
        let me = try await client.requireCurrentUserID()
        let entry = NewEntry(id: id, authorID: me, body: body, restaurantID: place, createdAt: Date())
        try await client.supabase.from("entries").insert(entry, returning: .minimal).execute()
        return id
    }

    func sort(_ client: AteAPIClient, _ entry: UUID, force: Bool = false, tokens: [TagToken] = []) async throws {
        let reply: SortReply = try await client.supabase.functions.invoke(
            "sort-entry",
            options: FunctionInvokeOptions(
                method: .post, body: SortRequest(entryID: entry, force: force, tagTokens: tokens)
            )
        )
        #expect(reply.ok == true, "sort-entry did not sort \(entry)")
    }

    func card(_ client: AteAPIClient, _ entry: UUID) async throws -> Card {
        let rows: [Card] = try await client.supabase.from("entry_cards").select("id,items")
            .eq("id", value: entry.uuidString.lowercased()).execute().value
        return try #require(rows.first, "entry \(entry) is not readable")
    }

    func patchTags(_ client: AteAPIClient, _ review: UUID, _ tags: [String]) async throws {
        try await client.supabase.from("reviews").update(["tags": tags], returning: .minimal)
            .eq("id", value: review.uuidString.lowercased()).execute()
    }

    func summary(_ client: AteAPIClient, _ dish: UUID) async throws -> Summary {
        let rows: [Summary] = try await StagingRPC.rows(client, "dish_summary", ["p_dish_id": StagingRPC.id(dish)])
        return try #require(rows.first)
    }

    /// Deletes this suite's own synthetic entries: the demo author's, carrying the marker. Nothing else.
    func sweep(_ client: AteAPIClient) async throws {
        let me = try await client.requireCurrentUserID()
        try await client.supabase.from("entries").delete()
            .eq("author_id", value: me.uuidString.lowercased())
            .like("body", pattern: "\(Self.marker)%")
            .execute()
    }

    func somePlace(_ client: AteAPIClient) async throws -> UUID {
        struct Row: Decodable { let id: UUID }
        let rows: [Row] = try await client.supabase.from("restaurants").select("id").order("id").limit(1)
            .execute().value
        return try #require(rows.first?.id, "staging holds no restaurant")
    }

    // MARK: - The contract

    @Test("marked tokens tag the dish they follow; prose never tags; PATCH is canonical, owner-only, and survives")
    func tagsEndToEnd() async throws {
        try await StagingExclusive.shared.run {
            let jess = try await author()
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

    func drive(_ jess: AteAPIClient) async throws {
        let place = try await somePlace(jess)
        let body = "\(Self.marker) pasta 4.5 GF V. The waiter said the salad was gluten free. "
            + "\(Self.marker) salad 3.5"
        let first = try await write(jess, body, at: place)
        try await sort(jess, first, tokens: [
            try Self.token("GF", in: "4.5 GF V.", of: body),
            try Self.token("V", in: "GF V.", of: body)
        ])

        var card = try await card(jess, first)
        #expect(try card.line("pasta").tags == ["gf", "v"], "the marked GF and V land on the pasta")
        #expect(try card.line("salad").tags == [], "\"gluten free\" in prose is not a tag")

        // The per-line write: canonicalised, not a correction.
        let salad = try card.line("salad")
        try await patchTags(jess, salad.reviewID, ["VG", "gf", "gf"])
        card = try await self.card(jess, first)
        #expect(try card.line("salad").tags == ["gf", "vg"])
        #expect(try card.line("salad").corrected == false, "a tag is not a correction")

        await #expect(throws: (any Error).self, "a code outside the closed set is 23514") {
            try await patchTags(jess, salad.reviewID, ["keto"])
        }

        // Owner only: another signed-in user's PATCH matches no row.
        let eamon = try await StagingContract.Backend.shared.client()
        try? await patchTags(eamon, salad.reviewID, ["nf"])
        #expect(try await self.card(jess, first).line("salad").tags == ["gf", "vg"], "RLS let a stranger tag")

        // A forced re-sort without tokens removes nothing.
        try await sort(jess, first, force: true)
        card = try await self.card(jess, first)
        #expect(try card.line("pasta").tags == ["gf", "v"])
        #expect(try card.line("salad").tags == ["gf", "vg"])

        try await consensus(jess, pasta: try card.line("pasta").dishID, place: place)
        try await signedOut(jess, entry: first)
    }

    /// `dish_summary.tags`: at least half the lines, and at least one.
    func consensus(_ jess: AteAPIClient, pasta: UUID, place: UUID) async throws {
        var dish = try await summary(jess, pasta)
        try #require(dish.reviewCount == 1, "another run is writing the probe dish; retry (\(dish.reviewCount) lines)")
        #expect(dish.tags == ["gf", "v"], "one line, tagged: that is the consensus")

        let second = try await write(jess, "\(Self.marker) pasta 4", at: place)
        try await sort(jess, second)
        dish = try await summary(jess, pasta)
        #expect(dish.reviewCount == 2)
        #expect(dish.tags == ["gf", "v"], "1 of 2 is half: still listed")

        let third = try await write(jess, "\(Self.marker) pasta 3.5", at: place)
        try await sort(jess, third)
        dish = try await summary(jess, pasta)
        #expect(dish.reviewCount == 3)
        #expect(dish.tags == [], "1 of 3 is not half")
    }

    /// The browse twins return the view's rows, so the signed-out reads carry the same tags.
    func signedOut(_ jess: AteAPIClient, entry: UUID) async throws {
        let me = try await jess.requireCurrentUserID()
        let anon = AteAPIClient(supabase: StagingContract.makeClient())
        let rows: [Card] = try await StagingRPC.rows(anon, "get_entries_by_author", [
            "p_author_id": StagingRPC.id(me), "p_cursor_created_at": .null, "p_cursor_id": .null,
            "p_page_size": .integer(20)
        ])
        let card = try #require(rows.first { $0.id == entry }, "the signed-out journal read lacks the entry")
        #expect(try card.line("pasta").tags == ["gf", "v"])
        #expect(try card.line("salad").tags == ["gf", "vg"])
        #expect(rows.allSatisfy { $0.items.allSatisfy { $0.tags.allSatisfy(["gf", "df", "v", "vg", "nf"].contains) } })

        let pasta = try card.line("pasta").dishID
        let signedIn = try await summary(jess, pasta)
        let browse = try await summary(anon, pasta)
        #expect(browse.tags == signedIn.tags, "signed-out dish_summary disagrees on tags")
    }
}
