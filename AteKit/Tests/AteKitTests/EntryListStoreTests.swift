import Foundation
import Testing
@testable import AteKit

/// A list that answers with the pages a test hands it, and remembers what it was asked for.
private final class PagedFeed: @unchecked Sendable {
    var pages: [[EntryCard]]
    var error: (any Error)?
    private(set) var cursors: [PageCursor?] = []
    private let lock = NSLock()

    init(pages: [[EntryCard]]) {
        self.pages = pages
    }

    var loader: EntryListStore.Loader {
        { [self] cursor, pageSize in
            if let error { throw error }
            return lock.withLock {
                cursors.append(cursor)
                let index = cursor == nil ? 0 : cursors.count - 1
                let items = index < pages.count ? pages[index] : []
                return Page(items: items, requestedLimit: pageSize)
            }
        }
    }
}

@MainActor
@Suite("Entry list store")
struct EntryListStoreTests {

    private let author = UUID()

    private func card(
        _ minutesAgo: Double,
        id: UUID = UUID(),
        author: UUID? = nil,
        dish: UUID = UUID(),
        saved: Bool = false
    ) -> EntryCard {
        let authorID = author ?? self.author
        return EntryCard(
            id: id,
            authorID: authorID,
            body: "Tipo 00 was good.",
            orderNumber: 1,
            sortStatus: .sorted,
            createdAt: Date(timeIntervalSince1970: 1_789_776_000 - minutesAgo * 60),
            isMine: false,
            author: EntryCard.Author(id: authorID, username: "jessw"),
            place: EntryCard.Place(id: UUID(), name: "Tipo 00"),
            items: [EntryCard.Item(reviewID: UUID(), dishID: dish, dishName: "Prawn spaghetti",
                                   score: Rating(rounding: 5), position: 1, saved: saved)]
        )
    }

    private func store(_ feed: PagedFeed, pageSize: Int = 2) -> EntryListStore {
        EntryListStore(pageSize: pageSize, fallbackMessage: "Couldn't load the feed.", loader: feed.loader)
    }

    @Test("A full first page is ready; a short one is the last page")
    func firstPage() async {
        let feed = PagedFeed(pages: [[card(1), card(2)]])
        let store = store(feed)
        await store.loadIfNeeded()
        #expect(store.phase == .ready)
        #expect(store.entries.count == 2)
        #expect(store.hasReachedEnd == false)
        #expect(store.pagesLoaded == 1)
    }

    @Test("Nothing to show is empty, not an error")
    func emptyFeed() async {
        let store = store(PagedFeed(pages: [[]]))
        await store.loadIfNeeded()
        #expect(store.phase == .empty)
        #expect(store.hasReachedEnd)
    }

    /// RLS hands an unauthenticated reader a successful empty page, so without this "signed out"
    /// and "nobody has written anything" would be the same screen.
    @Test("Not authenticated is its own state, never 'nothing here'")
    func signedOut() async {
        let feed = PagedFeed(pages: [[]])
        feed.error = AteAPIError.notAuthenticated
        let store = store(feed)
        await store.loadIfNeeded()
        #expect(store.phase == .signedOut)
    }

    @Test("The next page is asked for with the LAST row's cursor, and dedupes on arrival")
    func paging() async {
        let shared = card(2)
        let feed = PagedFeed(pages: [[card(1), shared], [shared, card(3)]])
        let store = store(feed)
        await store.loadIfNeeded()
        await store.loadMore()
        #expect(store.entries.count == 3, "the row both pages carried is kept once")
        #expect(feed.cursors.last??.id == shared.id)
        #expect(feed.cursors.last??.createdAt == shared.createdAt)
        #expect(store.pagesLoaded == 2)
    }

    @Test("Prefetch only fires near the end of the loaded rows")
    func prefetch() async {
        let rows = (1...10).map { card(Double($0)) }
        let feed = PagedFeed(pages: [rows, [card(11)]])
        let store = store(feed, pageSize: 10)
        await store.loadIfNeeded()
        await store.loadMoreIfNeeded(after: rows[0])
        #expect(feed.cursors.count == 1, "the top of the list asks for nothing")
        await store.loadMoreIfNeeded(after: rows[9])
        #expect(feed.cursors.count == 2)
    }

    @Test("A page that fails with rows on screen is inline, and keeps them")
    func inlineFailure() async {
        let feed = PagedFeed(pages: [[card(1), card(2)]])
        let store = store(feed)
        await store.loadIfNeeded()
        feed.error = URLError(.notConnectedToInternet)
        await store.loadMore()
        #expect(store.phase == .ready)
        #expect(store.entries.count == 2)
        #expect(store.inlineErrorMessage == "You're offline.")
    }

    @Test("A refresh replaces the list rather than appending to it")
    func refresh() async {
        let feed = PagedFeed(pages: [[card(1), card(2)], [card(3)]])
        let store = store(feed)
        await store.loadIfNeeded()
        feed.pages = [[card(4)]]
        await store.refresh()
        #expect(store.entries.count == 1)
        #expect(store.pagesLoaded == 1, "page numbering starts again")
    }

    /// The same dish saved from one entry is saved on every entry that serves it — a list that
    /// disagreed with itself would read as a broken bookmark.
    @Test("A save flips every line of that dish in the list")
    func saveIsPerDish() async {
        let dish = UUID()
        let feed = PagedFeed(pages: [[card(1, dish: dish), card(2, dish: dish), card(3)]])
        let store = store(feed, pageSize: 3)
        await store.loadIfNeeded()
        store.setSaved(dishID: dish, to: true)
        #expect(store.entries.prefix(2).allSatisfy { $0.items.allSatisfy(\.saved) })
        #expect(store.entries[2].items.allSatisfy { $0.saved == false })
        store.setSaved(dishID: dish, to: false)
        #expect(store.entries.allSatisfy { $0.items.allSatisfy { $0.saved == false } })
    }

    @Test("A block empties the list of that person immediately")
    func blocking() async {
        let blocked = UUID()
        let feed = PagedFeed(pages: [[card(1, author: blocked), card(2)]])
        let store = store(feed)
        await store.loadIfNeeded()
        store.removeAuthor(blocked)
        #expect(store.entries.count == 1)
        #expect(store.entries.allSatisfy { $0.authorID != blocked })
    }

    @Test("Blocking the only author left leaves an empty list, not a stale ready one")
    func blockingEverybody() async {
        let blocked = UUID()
        let feed = PagedFeed(pages: [[card(1, author: blocked)]])
        let store = store(feed)
        await store.loadIfNeeded()
        store.removeAuthor(blocked)
        #expect(store.phase == .empty)
    }
}
