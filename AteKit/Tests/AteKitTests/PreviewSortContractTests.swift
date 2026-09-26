import Foundation
import Supabase
import Testing

@testable import AteKit

/// **The early sort, against staging** (backend #66): `sort-entry {preview:true, body, tag_tokens,
/// restaurant_id}` plans without writing, and the real sort after Done reuses the cached plan when
/// the inputs match.
///
/// It writes one entry (to prove the reuse), so it is opt-in twice — `ATE_CONTRACT_TESTS=1` and
/// `ATE_STAGING_WRITES=1` — staging only, as a demo author, through ``StatsProbe``'s run-scoped
/// clean-up.
@Suite(
    "Preview sort — staging contract",
    .enabled(if: StagingContract.isEnabled && StagingContract.environmentValue("ATE_STAGING_WRITES") != nil),
    .serialized
)
struct PreviewSortContractTests {

    private struct Plan: Decodable {
        let preview: Bool?
        let cached: Bool?
        let mode: String?
        let items: [PlanItem]?
    }

    private struct PlanItem: Decodable {
        let dishName: String?
        enum CodingKeys: String, CodingKey { case dishName = "dish_name" }
    }

    private struct Sort: Encodable {
        let entryID: UUID
        let tagTokens: [TagToken]
        enum CodingKeys: String, CodingKey {
            case entryID = "entry_id"
            case tagTokens = "tag_tokens"
            case force
        }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(entryID.uuidString.lowercased(), forKey: .entryID)
            try container.encode(tagTokens, forKey: .tagTokens)
            try container.encode(false, forKey: .force)
        }
    }

    @Test("a preview plans and writes nothing; a repeat is cached; Done's sort still prints")
    func previewThenSortReusesThePlan() async throws {
        try await StatsProbe.run(at: "Contract preview probe") { probe in
            let body = "\(StatsProbe.marker) \(probe.run). The tiramisu GF 4.0 was lovely."
            let words = EntryComposition(plain: body, spans: [])
            let chip = try #require(body.range(of: "GF"))
            let tokens = [TagToken(
                offset: body.unicodeScalars.distance(
                    from: body.unicodeScalars.startIndex, to: chip.lowerBound
                ),
                length: 2
            )]
            let input = EarlySortInput(body: words.plain, tagTokens: tokens, restaurantID: probe.place)

            // The app's own call: no throw.
            try await probe.entries.previewSort(input)

            // The same request, read raw: a plan, flagged as a preview.
            let plan: Plan = try await probe.client.supabase.functions.invoke(
                "sort-entry",
                options: FunctionInvokeOptions(
                    method: .post, body: SupabaseEntryService.PreviewSortRequest(input)
                )
            )
            #expect(plan.preview == true)
            #expect(plan.items?.isEmpty == false, "the preview found the dish")

            // Nothing was written by either preview.
            let me = try await probe.client.requireCurrentUserID()
            struct Row: Decodable { let id: UUID }
            let written: [Row] = try await probe.client.supabase.from("entries").select("id")
                .eq("author_id", value: me.uuidString.lowercased())
                .eq("body", value: body)
                .execute().value
            #expect(written.isEmpty, "a preview persists nothing")

            // The same draft again: in model mode it is the cached plan (and free of the ration).
            let again: Plan = try await probe.client.supabase.functions.invoke(
                "sort-entry",
                options: FunctionInvokeOptions(
                    method: .post, body: SupabaseEntryService.PreviewSortRequest(input)
                )
            )
            if plan.mode == "model" { #expect(again.cached == true, "a repeated draft is served from cache") }

            // Done: the words land with the same inputs and the ordinary sort prints them. (Reuse is
            // recorded server-side in `entries.sort_meta.cache_hit`, model mode only.)
            let id = UUID()
            try await probe.entries.create(NewEntry(
                id: id, authorID: me, body: body, restaurantID: probe.place, createdAt: Date()
            ))
            _ = try await probe.client.supabase.functions.invoke(
                "sort-entry",
                options: FunctionInvokeOptions(method: .post, body: Sort(entryID: id, tagTokens: tokens))
            ) as Plan
            let card = try await probe.entries.entry(id: id)
            #expect(card.items.isEmpty == false)
            #expect(card.items.first?.tags == [.gf], "the chip reached the dish it follows")
        }
    }
}
