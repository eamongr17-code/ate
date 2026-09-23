import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **The feed, saves and profiles, against the real staging rows.**
///
/// Unit tests prove the client decodes a payload we wrote down; only this proves the RPC is still
/// called by that name, still takes those parameters, and still answers with that shape. Every one
/// of the calls below is a named-argument PostgREST invocation, which is exactly the kind of thing
/// that breaks silently on the client and loudly nowhere.
///
/// Opt-in (`ATE_CONTRACT_TESTS=1`), staging only, like its sibling. It **writes**: one save, then
/// its unsave — the smallest round trip that proves the whole loop, and it leaves staging as it
/// found it.
@Suite("Feed and saves contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct SocialContractTests {
    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    @Test("the feed walks other people's public entries, keyset, without repeating one")
    func feedPages() async throws {
        let client = try await client()
        let me = try await client.requireCurrentUserID()
        let feed = EntryFeedClient(api: client)

        var cursor: PageCursor?
        var seen: [EntryCard] = []
        var pages = 0
        while pages < 8 {
            let page = try await feed.feedPage(after: cursor, pageSize: 3, includeOwn: false)
            seen.append(contentsOf: page.items)
            pages += 1
            guard let next = page.nextCursor else { break }
            cursor = next
        }

        #expect(seen.isEmpty == false, "staging seeds other people's entries")
        #expect(Set(seen.map(\.id)).count == seen.count, "a keyset page must not serve a row twice")
        #expect(seen.allSatisfy { $0.visibility == .public }, "the feed is public entries only")
        // `p_include_own` defaults false: your own visits live in the journal.
        #expect(seen.allSatisfy { $0.authorID != me })
        #expect(seen.allSatisfy { $0.isMine == false })
        // Newest first, with the id tiebreak — the ordering the cursor depends on.
        let ordered = zip(seen, seen.dropFirst()).allSatisfy { first, second in
            (first.createdAt, first.id.uuidString) > (second.createdAt, second.id.uuidString)
        }
        #expect(ordered, "created_at DESC, id DESC")
    }

    @Test("a feed row carries the author, the place and the viewer's own save state")
    func feedRowShape() async throws {
        let client = try await client()
        let page = try await EntryFeedClient(api: client)
            .feedPage(after: nil, pageSize: 10, includeOwn: false)
        let card = try #require(page.items.first { $0.items.isEmpty == false && $0.place != nil })
        let author = try #require(card.author, "a feed slip needs a byline")
        #expect(author.username.isEmpty == false)
        #expect(card.dishCount == card.items.count)
        // `saved` is the viewer's own flag, and it has to decode — it is what draws the bookmark.
        _ = card.items.map(\.saved)
    }

    @Test("a profile's header and their entries come back for a real author")
    func profileSummaryAndEntries() async throws {
        let client = try await client()
        let page = try await EntryFeedClient(api: client)
            .feedPage(after: nil, pageSize: 5, includeOwn: false)
        let someoneElse = try #require(page.items.first?.authorID)
        let profiles = ProfileClient(api: client)

        let summary = try await profiles.profile(id: someoneElse)
        #expect(summary.userID == someoneElse)
        #expect(summary.username.isEmpty == false)
        #expect(summary.isMe == false)
        #expect(summary.orders >= 0 && summary.places >= 0 && summary.dishes >= 0)

        let theirs = try await profiles.entriesPage(authorID: someoneElse, after: nil, pageSize: 5)
        #expect(theirs.items.allSatisfy { $0.authorID == someoneElse })
        // RLS: a stranger's page is public entries only.
        #expect(theirs.items.allSatisfy { $0.visibility == .public })
    }

    /// The whole save loop in one round trip: save a dish off the feed, find it on the shelf with
    /// its provenance, then unsave it. Staging is left exactly as it was found.
    @Test("save_dish lands on my_saved_dishes with its provenance, and unsave_dish takes it off")
    func savingADishRoundTrips() async throws {
        let client = try await client()
        let saves = SaveClient(api: client)
        let page = try await EntryFeedClient(api: client)
            .feedPage(after: nil, pageSize: 20, includeOwn: false)
        // A dish the viewer has NOT already saved, so the assertions are about this call.
        let candidate = try #require(
            page.items.lazy.compactMap { card -> (EntryCard, EntryCard.Item)? in
                guard let item = card.items.first(where: { $0.saved == false }) else { return nil }
                return (card, item)
            }.first,
            "staging needs one unsaved dish in the feed"
        )
        let (entry, item) = candidate

        try await saves.save(dishID: item.dishID, sourceEntryID: entry.id)
        defer { Task { try? await saves.unsave(dishID: item.dishID) } }

        let shelf = try await saves.savedDishesPage(after: nil, pageSize: 200)
        let saved = try #require(shelf.items.first { $0.dishID == item.dishID },
                                 "a saved dish is on the shelf immediately")
        #expect(saved.dishName.isEmpty == false)
        #expect(saved.restaurantName.isEmpty == false)
        #expect(saved.sourceEntryID == entry.id, "first provenance wins, and it is this entry")
        #expect(saved.sourceUserID == entry.authorID)

        // Idempotent: saving again is not an error and does not move the provenance.
        try await saves.save(dishID: item.dishID, sourceEntryID: nil)
        let again = try await saves.savedDishesPage(after: nil, pageSize: 200)
        #expect(again.items.filter { $0.dishID == item.dishID }.count == 1)
        #expect(again.items.first { $0.dishID == item.dishID }?.sourceEntryID == entry.id)

        // …and the entry row the app re-reads agrees the viewer has it.
        let reread = try await SupabaseEntryService(api: client).entry(id: entry.id)
        #expect(reread.items.first { $0.dishID == item.dishID }?.saved == true)

        try await saves.unsave(dishID: item.dishID)
        let after = try await saves.savedDishesPage(after: nil, pageSize: 200)
        #expect(after.items.contains { $0.dishID == item.dishID } == false)
    }

    /// "Save this place": every line of one visit, provenance = that entry.
    @Test("save_entry_dishes saves the whole visit, and each line can be taken off again")
    func savingAWholeVisit() async throws {
        let client = try await client()
        let saves = SaveClient(api: client)
        let page = try await EntryFeedClient(api: client)
            .feedPage(after: nil, pageSize: 20, includeOwn: false)
        let entry = try #require(
            page.items.first { $0.items.count >= 2 && $0.items.contains { $0.saved == false } },
            "staging needs a multi-dish entry with something unsaved on it"
        )
        let alreadySaved = Set(entry.items.filter(\.saved).map(\.dishID))
        let mine = entry.items.map(\.dishID).filter { alreadySaved.contains($0) == false }

        let count = try await saves.saveEntryDishes(entryID: entry.id)
        defer {
            Task {
                for dishID in mine { try? await saves.unsave(dishID: dishID) }
            }
        }
        #expect(count >= 0, "the RPC answers with how many it saved")

        let reread = try await SupabaseEntryService(api: client).entry(id: entry.id)
        #expect(reread.isEveryDishSaved, "every line of the visit is on the shelf")

        for dishID in mine { try await saves.unsave(dishID: dishID) }
        let after = try await SupabaseEntryService(api: client).entry(id: entry.id)
        #expect(after.items.filter(\.saved).map(\.dishID).sorted() == alreadySaved.sorted(),
                "and taking them off leaves exactly what was there before")
    }

    /// The moderation calls the actions sheet makes. A report leaves a row for manual triage (which
    /// is what it is for); the block is undone in the same test, so staging keeps its cohort.
    @Test("report_profile and report_entry are accepted")
    func reporting() async throws {
        let client = try await client()
        let profiles = ProfileClient(api: client)
        let page = try await EntryFeedClient(api: client)
            .feedPage(after: nil, pageSize: 5, includeOwn: false)
        let entry = try #require(page.items.first)
        try await profiles.report(entryID: entry.id, reason: "contract-test", note: nil)
        try await profiles.report(profileID: entry.authorID, reason: "contract-test", note: nil)
    }

    @Test("block_user removes that person from every read, both ways, until they are unblocked")
    func blockingHidesThem() async throws {
        let client = try await client()
        let profiles = ProfileClient(api: client)
        let feed = EntryFeedClient(api: client)
        let before = try await feed.feedPage(after: nil, pageSize: 50, includeOwn: false)
        let victim = try #require(before.items.last?.authorID, "staging seeds other people")
        #expect(before.items.contains { $0.authorID == victim })

        try await profiles.block(userID: victim)
        // Unblocked whatever happens below: a staging cohort that loses a member to a failed
        // assertion is a worse bug than the one this test is looking for.
        defer {
            Task {
                try? await client.callRPC(
                    "unblock_user",
                    parameters: ["p_user_id": .string(victim.uuidString.lowercased())]
                )
            }
        }

        let during = try await feed.feedPage(after: nil, pageSize: 50, includeOwn: false)
        #expect(during.items.contains { $0.authorID == victim } == false,
                "a blocked person is gone from the feed — the client never filters, it refetches")
        await #expect(throws: (any Error).self) {
            _ = try await profiles.profile(id: victim)
        }
        let theirs = try await profiles.entriesPage(authorID: victim, after: nil, pageSize: 5)
        #expect(theirs.items.isEmpty)

        try await client.callRPC(
            "unblock_user",
            parameters: ["p_user_id": .string(victim.uuidString.lowercased())]
        )
        let after = try await feed.feedPage(after: nil, pageSize: 50, includeOwn: false)
        #expect(after.items.contains { $0.authorID == victim }, "and they come back")
    }

    @Test("the shelf pages on (saved_at, dish_id) without repeating a dish")
    func shelfPages() async throws {
        let client = try await client()
        let saves = SaveClient(api: client)
        var cursor: PageCursor?
        var seen: [SavedDish] = []
        var pages = 0
        while pages < 10 {
            let page = try await saves.savedDishesPage(after: cursor, pageSize: 2)
            seen.append(contentsOf: page.items)
            pages += 1
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        #expect(Set(seen.map(\.dishID)).count == seen.count, "no dish twice across pages")
        let ordered = zip(seen, seen.dropFirst()).allSatisfy { first, second in
            (first.savedAt, first.dishID.uuidString) > (second.savedAt, second.dishID.uuidString)
        }
        #expect(ordered, "saved_at DESC, dish_id DESC — the order the cursor walks")
    }
}
