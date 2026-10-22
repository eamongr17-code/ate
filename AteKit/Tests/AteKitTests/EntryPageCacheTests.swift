import Foundation
import Testing
@testable import AteKit

/// A journal that answers once, with one page, or fails.
private final class OnePageEntryService: EntryService, TestFake, @unchecked Sendable {
    let page: [EntryCard]
    let error: (any Error)?

    init(page: [EntryCard], error: (any Error)? = nil) {
        self.page = page
        self.error = error
    }

    func authorID() async throws -> UUID { ViewerProfile.preview.id }
    @discardableResult
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        SortOutcome(entryID: entryID, status: .sorted, mode: "stub", itemCount: 0,
                    restaurantID: nil, didAttachPlace: false)
    }

    func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        if let error { throw error }
        return Page(items: cursor == nil ? page : [], requestedLimit: pageSize)
    }
}

@MainActor
@Suite("Entry page cache")
struct EntryPageCacheTests {

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ate-pages-\(UUID().uuidString)", isDirectory: true)
    private let owner = UUID()

    private func card(_ body: String, at seconds: Double = 1_789_776_000.123456) -> EntryCard {
        EntryCard(
            id: UUID(),
            authorID: owner,
            body: body,
            orderNumber: 7,
            sortStatus: .sorted,
            createdAt: Date(timeIntervalSince1970: seconds),
            author: EntryCard.Author(id: owner, username: "eamon"),
            place: EntryCard.Place(id: UUID(), name: "Tipo 00", locality: "Melbourne"),
            photos: [EntryCard.Photo(url: "https://example.com/a.jpg", position: 0)],
            items: [EntryCard.Item(
                reviewID: UUID(), dishID: UUID(), dishName: "Cacio e Pepe",
                score: Rating(exactly: 4.5), position: 1, tags: [.v]
            )],
            companions: [EntryCompanion(userID: UUID(), username: "jess")]
        )
    }

    private func cache() -> EntryPageCache {
        EntryPageCache(list: "journal", owner: owner, directory: directory)!
    }

    @Test("a page comes back exactly as it went in, dates to the microsecond")
    func roundTrips() {
        let cards = [card("Ragu"), card("Tiramisu", at: 1_789_700_000.000001)]
        cache().write(cards)
        EntryPageCache.flush()
        #expect(cache().read() == cards)
    }

    @Test("nobody signed in keeps nothing; each person has their own file")
    func perPerson() {
        #expect(EntryPageCache(list: "journal", owner: nil, directory: directory) == nil)
        cache().write([card("Mine")])
        EntryPageCache.flush()
        let someoneElse = EntryPageCache(list: "journal", owner: UUID(), directory: directory)!
        #expect(someoneElse.read() == nil)
    }

    @Test("clearing leaves nothing to read")
    func clears() {
        cache().write([card("Gone")])
        EntryPageCache.flush()
        EntryPageCache.clearAll(directory: directory)
        EntryPageCache.flush()
        #expect(cache().read() == nil)
    }

    @Test("a cold journal draws the cached page, and the read replaces it")
    func journalDrawsCachedThenFresh() async {
        let old = card("Last time")
        cache().write([old])
        EntryPageCache.flush()
        let fresh = card("Today", at: 1_789_800_000)
        let store = JournalStore(entries: OnePageEntryService(page: [fresh]), cache: cache())
        await store.loadIfNeeded()
        #expect(store.entries == [fresh])
        #expect(store.phase == .ready)
        EntryPageCache.flush()
        #expect(cache().read() == [fresh])
    }

    @Test("offline, the cached journal stays up with the error inline")
    func offlineKeepsCached() async {
        let old = card("Last time")
        cache().write([old])
        EntryPageCache.flush()
        let store = JournalStore(
            entries: OnePageEntryService(page: [], error: URLError(.notConnectedToInternet)),
            cache: cache()
        )
        await store.loadIfNeeded()
        #expect(store.entries == [old])
        #expect(store.phase == .ready)
        #expect(store.inlineErrorMessage == "You're offline.")
    }

    @Test("signed out, the cached journal is put away")
    func signedOutDropsCached() async {
        cache().write([card("Last time")])
        EntryPageCache.flush()
        let store = JournalStore(
            entries: OnePageEntryService(page: [], error: AteAPIError.notAuthenticated),
            cache: cache()
        )
        await store.loadIfNeeded()
        #expect(store.entries.isEmpty)
        #expect(store.phase == .signedOut)
    }

    @Test("a deleted entry leaves the cached page too")
    func deleteUpdatesCache() async {
        let kept = card("Kept")
        let deleted = card("Deleted", at: 1_789_700_000)
        let store = JournalStore(entries: OnePageEntryService(page: [kept, deleted]), cache: cache())
        await store.loadIfNeeded()
        store.remove(entryID: deleted.id)
        EntryPageCache.flush()
        #expect(cache().read() == [kept])
    }

    @Test("the feed's list draws its cached page, then the read")
    func listDrawsCachedThenFresh() async {
        let listCache = EntryPageCache(list: "feed", owner: owner, directory: directory)!
        let old = card("Someone's last time")
        listCache.write([old])
        EntryPageCache.flush()
        let fresh = card("Someone's today", at: 1_789_800_000)
        let store = EntryListStore(fallbackMessage: "Couldn't load the feed.") { cursor, size in
            Page(items: cursor == nil ? [fresh] : [], requestedLimit: size)
        }
        store.cache = listCache
        await store.loadIfNeeded()
        #expect(store.entries == [fresh])
        EntryPageCache.flush()
        #expect(listCache.read() == [fresh])
    }
}
