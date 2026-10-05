import Foundation
import Supabase
import Testing
@testable import AteKit

private let viewer = UUID(uuidString: "5C4B0D0E-0000-4000-8000-000000000001")!
private let jess = CompanionPerson(userID: UUID(uuidString: "11111111-0000-4000-8000-000000000003")!,
                                   handle: "jessw", name: "Jess W")
private let marco = CompanionPerson(userID: UUID(uuidString: "11111111-0000-4000-8000-000000000004")!,
                                    handle: "marco.eats", name: "Marco Bellini")
private let priya = CompanionPerson(userID: UUID(uuidString: "11111111-0000-4000-8000-000000000001")!,
                                    handle: "priya", name: "Priya Shah")

private func person(_ index: Int) -> CompanionPerson {
    CompanionPerson(userID: UUID(uuidString: String(format: "22222222-0000-4000-8000-%012d", index))!,
                    handle: "eater\(index)", name: "Eater \(index)")
}

@Suite("Ate with — entry_cards.companions decoding")
struct CompanionDecodingTests {
    private func card(_ companions: String?) throws -> EntryCard {
        let tail = companions.map { ", \"companions\": \($0)" } ?? ""
        let json = """
        {"id": "A7E00000-0000-4000-8000-000000000142", "author_id": "5C4B0D0E-0000-4000-8000-000000000001",
         "body": "", "visibility": "public", "order_number": 142, "sort_status": "sorted",
         "created_at": "2026-09-19T10:14:00.000000+00:00", "updated_at": "2026-09-19T10:14:00.000000+00:00",
         "is_mine": true, "photos": [], "photo_count": 0, "items": [], "dish_count": 0\(tail)}
        """
        return try PostgRESTDate.decoder.decode(EntryCard.self, from: Data(json.utf8))
    }

    @Test("companions decode: handle, name, status, the person's own entry")
    func decodes() throws {
        let decoded = try card("""
        [{"user_id": "11111111-0000-4000-8000-000000000003", "username": "jess", "name": "Jess Tran",
          "avatar_url": null, "status": "accepted", "entry_id": "E0000000-0000-4000-8000-000000000001"},
         {"user_id": "11111111-0000-4000-8000-000000000004", "username": "marco", "name": null,
          "avatar_url": null, "status": "pending", "entry_id": null}]
        """)
        #expect(decoded.companions.map(\.username) == ["jess", "marco"])
        #expect(decoded.companions[0].status == .accepted)
        #expect(decoded.companions[0].entryID == UUID(uuidString: "E0000000-0000-4000-8000-000000000001"))
        #expect(decoded.companions[1].status == .pending)
        #expect(decoded.companions[1].entryID == nil)
    }

    @Test("a row from before 0058, a null, or one malformed person still decodes")
    func tolerant() throws {
        #expect(try card(nil).companions.isEmpty)
        #expect(try card("null").companions.isEmpty)
        #expect(try card("\"nope\"").companions.isEmpty)
        let partial = try card("""
        [{"username": "nobody"},
         {"user_id": "11111111-0000-4000-8000-000000000003", "username": "jess", "status": "someday"}]
        """)
        #expect(partial.companions.map(\.username) == ["jess"])
        #expect(partial.companions[0].status == .pending)
    }

    @Test("replacing keeps the companions; the receipt line prints @jess, then @jess +1")
    func carries() {
        let card = EntryCard.previewSorted
        #expect(card.replacing(sortStatus: .sorted).companions == card.companions)
        #expect(CompanionLine.compact([]) == nil)
        #expect(CompanionLine.compact(["jess"]) == "@jess")
        #expect(CompanionLine.compact(["jess", "marco", "priya"]) == "@jess +2")
    }
}

/// The debounce is an hour in these tests: each calls `search()` itself, and a scheduled search
/// racing it would be testing the clock.
@Suite("Ate with — the picker")
@MainActor
struct CompanionPickerStoreTests {
    private func service(people: [CompanionPerson] = [jess, marco, priya], recents: [UUID] = [],
                         blocked: Set<UUID> = []) -> InMemoryCompanionTagging {
        InMemoryCompanionTagging(viewerID: viewer, people: people, recents: recents, blocked: blocked)
    }

    @Test("before typing: recent companions, newest first; a picked person outside them leads")
    func recents() async {
        let store = CompanionPickerStore(service: service(recents: [marco.userID, jess.userID]),
                                         selected: [priya], debounce: .seconds(3600))
        await store.loadRecents()
        #expect(store.phase == .ready)
        #expect(store.rows.map(\.handle) == ["priya", "marco.eats", "jessw"])
    }

    @Test("typing two characters searches every handle; one filters the standing list")
    func search() async {
        let store = CompanionPickerStore(service: service(recents: [jess.userID]), debounce: .seconds(3600))
        await store.loadRecents()
        store.query = "p"
        #expect(store.isSearching == false)
        #expect(store.rows.isEmpty)
        store.query = "pri"
        await store.search()
        #expect(store.rows.map(\.handle) == ["priya"])
        store.query = "Bellini"
        await store.search()
        #expect(store.rows.map(\.handle) == ["marco.eats"])
    }

    @Test("nobody blocked, and never the viewer, in recents or search")
    func blocked() async {
        let me = CompanionPerson(userID: viewer, handle: "eamon")
        let store = CompanionPickerStore(
            service: service(people: [jess, marco, me], recents: [marco.userID, jess.userID],
                             blocked: [marco.userID]),
            debounce: .seconds(3600)
        )
        await store.loadRecents()
        #expect(store.rows.map(\.handle) == ["jessw"])
        store.query = "ea"
        await store.search()
        #expect(store.rows.contains { $0.userID == viewer || $0.userID == marco.userID } == false)
    }

    @Test("six at most: a seventh is refused and nothing changes")
    func cap() {
        let store = CompanionPickerStore(service: service())
        for index in 1...6 { #expect(store.toggle(person(index))) }
        #expect(store.isFull)
        #expect(store.toggle(person(7)) == false)
        #expect(store.selected.count == CompanionPickerStore.cap)
        #expect(store.toggle(person(3)))
        #expect(store.selected.count == 5)
        #expect(store.toggle(person(7)))
    }

    @Test("the pill counts: Add @jess, Add 2 people; everyone unticked from an edit is Remove")
    func commit() {
        let fresh = CompanionPickerStore(service: service())
        #expect(fresh.canCommit == false)
        fresh.toggle(jess)
        #expect(fresh.commitTitle == "Add @jessw")
        fresh.toggle(marco)
        #expect(fresh.commitTitle == "Add 2 people")
        let edit = CompanionPickerStore(service: service(), selected: [jess])
        edit.remove(jess)
        #expect(edit.canCommit)
        #expect(edit.commitTitle == "Remove @jessw")
    }

    @Test("search pages on the keyset cursor without repeating a row")
    func pages() async {
        let many = (1...5).map(person)
        let store = CompanionPickerStore(service: service(people: many), debounce: .seconds(3600), pageSize: 2)
        store.query = "eater"
        await store.search()
        #expect(store.rows.count == 2)
        #expect(store.hasMore)
        await store.loadMore()
        await store.loadMore()
        #expect(store.rows.map(\.handle) == many.map(\.handle))
        #expect(store.hasMore == false)
    }
}

@Suite("Ate with — tags sent with the post")
struct CompanionTagSyncTests {
    private let entry = UUID()

    @Test("posting with people tags each of them on the new entry")
    func tagsOnPost() async {
        let service = InMemoryCompanionTagging(viewerID: viewer, people: [jess, marco])
        let sync = CompanionTagSync(service: service)
        let added = await sync.apply(entryID: entry, from: [], to: [jess.userID, marco.userID])
        #expect(added == 2)
        #expect(service.tagged(on: entry) == [jess.userID: .pending, marco.userID: .pending])
        #expect(await sync.pending.isEmpty)
    }

    @Test("an edit sends only the difference: one added, one taken off")
    func editDiff() async {
        let service = InMemoryCompanionTagging(viewerID: viewer, people: [jess, marco, priya])
        let sync = CompanionTagSync(service: service)
        await sync.apply(entryID: entry, from: [], to: [jess.userID, marco.userID])
        let added = await sync.apply(entryID: entry, from: [jess.userID, marco.userID],
                                     to: [jess.userID, priya.userID])
        #expect(added == 1)
        #expect(Set(service.tagged(on: entry).keys) == [jess.userID, priya.userID])
        #expect(await sync.apply(entryID: entry, from: [jess.userID], to: [jess.userID]) == 0)
    }

    @Test("offline, the tag waits and goes on the next run; the post was never blocked")
    func retriesOffline() async {
        let service = InMemoryCompanionTagging(viewerID: viewer, people: [jess])
        service.failNext(URLError(.notConnectedToInternet))
        let sync = CompanionTagSync(service: service)
        await sync.apply(entryID: entry, from: [], to: [jess.userID])
        #expect(service.tagged(on: entry).isEmpty)
        #expect(await sync.pending.map(\.attempts) == [1])
        await sync.run()
        #expect(service.tagged(on: entry) == [jess.userID: .pending])
        #expect(await sync.pending.isEmpty)
    }

    @Test("an entry still in the outbox (P0002) is retried; a refusal that cannot change is dropped")
    func classifies() async {
        #expect(CompanionTagFailure.of(PostgrestError(code: "P0002", message: "entry_not_found")) == .retry)
        #expect(CompanionTagFailure.of(PostgrestError(code: "54000", message: "ate_with_cap")) == .drop)
        #expect(CompanionTagFailure.of(PostgrestError(code: "42501", message: "blocked")) == .drop)
        let service = InMemoryCompanionTagging(viewerID: viewer, people: [jess, marco])
        service.failNext(CompanionTagError.limit)
        let sync = CompanionTagSync(service: service)
        await sync.apply(entryID: entry, from: [], to: [jess.userID, marco.userID])
        #expect(service.tagged(on: entry) == [marco.userID: .pending])
        #expect(await sync.pending.isEmpty)
    }

    @Test("a later change replaces one still waiting; and a tag never outlives its retries")
    func collapses() async {
        let service = InMemoryCompanionTagging(viewerID: viewer, people: [jess])
        let sync = CompanionTagSync(service: service)
        service.failNext(URLError(.notConnectedToInternet))
        await sync.apply(entryID: entry, from: [], to: [jess.userID])
        service.failNext(URLError(.notConnectedToInternet))
        await sync.apply(entryID: entry, from: [jess.userID], to: [])
        #expect(await sync.pending.map(\.kind) == [.untag])
        for _ in 0..<CompanionTagSync.maximumAttempts {
            service.failNext(URLError(.notConnectedToInternet))
            await sync.run()
        }
        #expect(await sync.pending.isEmpty)
    }

    @Test("the queue survives a relaunch")
    func persists() async throws {
        let url = URL.temporaryDirectory.appending(path: "tags-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let offline = InMemoryCompanionTagging(viewerID: viewer, people: [jess])
        offline.failNext(URLError(.notConnectedToInternet))
        await CompanionTagSync(service: offline, storeURL: url).apply(entryID: entry, from: [], to: [jess.userID])
        let online = InMemoryCompanionTagging(viewerID: viewer, people: [jess])
        let relaunched = CompanionTagSync(service: online, storeURL: url)
        #expect(await relaunched.pending.count == 1)
        await relaunched.run()
        #expect(online.tagged(on: entry) == [jess.userID: .pending])
        #expect(FileManager.default.fileExists(atPath: url.path()) == false)
    }
}

@Suite("Ate with — Remove me and the events")
struct CompanionRemoveMeTests {
    @Test("tagged on someone's entry, the viewer finds their tag and declines it")
    func removeMe() async throws {
        let entry = UUID()
        let service = InMemoryCompanionTagging(viewerID: viewer)
        #expect(try await service.myTag(onEntry: entry) == nil)
        service.tagViewer(onEntry: entry)
        let tag = try #require(try await service.myTag(onEntry: entry))
        try await service.decline(companionID: tag)
        #expect(try await service.myTag(onEntry: entry) == nil)
    }

    @Test("the three events, by name")
    func events() {
        #expect(CompanionEvents.pickerOpened().name == "ate_with_picker_opened")
        #expect(CompanionEvents.tagged(count: 2) == AnalyticsEvent(name: "ate_with_tagged", parameters: ["count": "2"]))
        #expect(CompanionEvents.removedSelf().name == "ate_with_removed_self")
    }
}
