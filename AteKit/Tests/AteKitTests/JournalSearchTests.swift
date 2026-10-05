import Foundation
import Supabase
import Testing
@testable import AteKit

/// A searcher that answers from a fixed list by the server's rule, counting what it was asked.
private final class CountingSearch: JournalSearching, @unchecked Sendable {
    private let lock = NSLock()
    private let cards: [EntryCard]
    private(set) var asked: [String] = []
    var fails = false

    init(_ cards: [EntryCard]) {
        self.cards = cards
    }

    func searchMyEntries(_ query: String, after cursor: PageCursor?, limit: Int) async throws -> Page<EntryCard> {
        lock.withLock { asked.append(query) }
        if fails { throw URLError(.notConnectedToInternet) }
        let needle = InMemoryLists.fold(query)
        let kept = cards
            .filter { InMemoryJournalSearch.matches($0, needle) }
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
            .filter { card in
                guard let cursor else { return true }
                return (card.createdAt, card.id.uuidString) < (cursor.createdAt, cursor.id.uuidString)
            }
        return Page(items: Array(kept.prefix(limit)), requestedLimit: limit)
    }
}

private func card(_ body: String, place: String = "Tipo 00", dishes: [String] = [], minutesAgo: Int) -> EntryCard {
    EntryCard(
        id: UUID(), authorID: UUID(), body: body, restaurantID: UUID(), restaurantSource: "user", orderNumber: 1,
        sortStatus: .sorted, sortedAt: nil,
        createdAt: Date(timeIntervalSince1970: 1_790_000_000 - Double(minutesAgo) * 60),
        isMine: true, author: nil, place: EntryCard.Place(id: UUID(), name: place),
        items: dishes.enumerated().map { offset, name in
            EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: name, position: offset + 1)
        }
    )
}

private func defaults() -> UserDefaults {
    let name = "journal.search.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
@Suite("Journal search")
struct JournalSearchTests {
    private let owner = UUID()

    private func store(
        _ service: CountingSearch, pageSize: Int = 20, log: EventLog = EventLog(), store: UserDefaults = defaults()
    ) -> JournalSearchStore {
        JournalSearchStore(
            service: service, recents: JournalSearchStore.recents(owner: owner, defaults: store),
            analytics: log.recorder, pageSize: pageSize, debounce: .milliseconds(20)
        )
    }

    @Test("debounced: three keystrokes are one read; under two characters is no read and the recents show")
    func debounce() async {
        let service = CountingSearch([
            card("Smash burger, perfect", minutesAgo: 1), card("Pho", place: "Burger Project", minutesAgo: 2),
            card("Ragu", dishes: ["Cheeseburger"], minutesAgo: 3), card("Nothing here", minutesAgo: 4)
        ])
        let log = EventLog()
        let search = store(service, log: log)
        search.opened()
        search.setQuery("b")
        #expect(search.phase == .idle)
        search.setQuery("bu")
        search.setQuery("BURG")
        await search.pending?.value
        #expect(service.asked == ["BURG"])
        #expect(search.results.count == 3, "words, place name and dish name all match")
        #expect(search.phase == .ready)
        #expect(log.names == ["journal_search_opened", "journal_searched"])
        #expect(log.first(named: "journal_searched")?.parameters == ["query_length": "4", "result_count": "2-5"])
        search.setQuery("b")
        #expect(search.results.isEmpty && search.phase == .idle)
    }

    @Test("pages on the journal keyset with nothing twice")
    func paging() async {
        let cards = (0..<45).map { card("burger \($0)", minutesAgo: $0) }
        let search = store(CountingSearch(cards), pageSize: 20)
        search.setQuery("burger")
        await search.pending?.value
        #expect(search.results.count == 20)
        await search.loadMore()
        await search.loadMore()
        #expect(search.results.count == 45 && search.hasReachedEnd)
        #expect(search.results.map(\.id) == cards.map(\.id))
    }

    @Test("nothing found is empty, not a failure; a failure clears the last query's rows")
    func emptyAndFailed() async {
        let service = CountingSearch([card("Ragu", minutesAgo: 1)])
        let search = store(service)
        search.setQuery("lobster roll")
        await search.pending?.value
        #expect(search.phase == .empty)
        search.setQuery("ragu")
        await search.pending?.value
        #expect(search.results.count == 1)
        service.fails = true
        search.setQuery("ragu!")
        await search.pending?.value
        #expect(search.phase == .failed && search.results.isEmpty)
    }

    @Test("a search is remembered when used — a result opened or Search pressed — newest first, per person")
    func recents() async {
        let shared = defaults()
        let log = EventLog()
        let search = store(CountingSearch([card("Ragu", minutesAgo: 1), card("Burger", minutesAgo: 2)]),
                           log: log, store: shared)
        search.setQuery("rag")
        await search.pending?.value
        #expect(search.recents.items.isEmpty, "typing is not a search")
        search.opened(search.results[0])
        #expect(search.recents.items.map(\.text) == ["rag"])
        #expect(log.first(named: "journal_search_result_opened")?.parameters["position"] == "1")
        search.setQuery("burger")
        await search.submit()
        #expect(search.recents.items.map(\.text) == ["burger", "rag"])
        await search.select(RecentSearch(text: "rag"))
        #expect(search.query == "rag" && search.results.count == 1)
        #expect(search.recents.items.map(\.text) == ["rag", "burger"])
        #expect(JournalSearchStore.recents(owner: owner, defaults: shared).items.map(\.text) == ["rag", "burger"])
        #expect(JournalSearchStore.recents(owner: UUID(), defaults: shared).items.isEmpty)
    }

    @Test("the in-memory search reads the preview journal by words, place and dish, accent-blind")
    func inMemory() async throws {
        let entries = InMemoryEntryService.seeded()
        let search = InMemoryJournalSearch(entries: entries)
        #expect(try await search.searchMyEntries("ragu", after: nil, limit: 20).items.map(\.id)
            == [EntryCard.previewSorted.id])
        #expect(try await search.searchMyEntries("lune", after: nil, limit: 20).items.map(\.id)
            == [EntryCard.previewCroissant.id])
        #expect(try await search.searchMyEntries("r", after: nil, limit: 20).items.isEmpty)
    }

    @Test("the wire: both cursor halves or neither")
    func wire() {
        let first = JournalSearchClient.parameters(query: "burger", after: nil, limit: 20)
        #expect(first["p_cursor_created_at"] == .null && first["p_cursor_id"] == .null)
        let cursor = PageCursor(createdAt: Date(timeIntervalSince1970: 1_789_812_840.5), id: UUID())
        let next = JournalSearchClient.parameters(query: "burger", after: cursor, limit: 20)
        #expect(next["p_cursor_created_at"] == .string("2026-09-19T10:14:00.500000Z"))
        #expect(next["p_cursor_id"] == .string(cursor.id.uuidString.lowercased()))
    }
}

@MainActor
@Suite("Journal — the one inbox count")
struct JournalInboxCountTests {
    @Test("tags plus photo sittings; never below zero")
    func sums() {
        #expect(JournalInboxCount(ateWith: 2, photos: 5).total == 7)
        #expect(JournalInboxCount(ateWith: -1, photos: 3).total == 3)
        #expect(JournalInboxCount.zero.isEmpty)
        #expect(JournalInboxCount(ateWith: 1, photos: 0).with(photos: 4).total == 5)
        #expect(JournalInboxCount(ateWith: 3, photos: 4).with(ateWith: 0).total == 4)
    }

    @Test("the photo half is the photos control's own count: recent photos less what was dismissed")
    func photosFromDismissals() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let items = (0..<3).map {
            PhotoSuggestionItem(id: "p\($0)", createdAt: now.addingTimeInterval(Double(-$0 * 60)))
        }
        let older = (0..<2).map {
            PhotoSuggestionItem(id: "q\($0)", createdAt: now.addingTimeInterval(-86_400 + Double(-$0 * 60)))
        }
        let dismissals = PhotoSuggestionDismissals(store: InMemoryKeyValueStore(), owner: UUID(), now: { now })
        let all = items + older
        #expect(JournalInboxCount(ateWith: 1, recentPhotos: all, dismissals: dismissals).total == 6)
        dismissals.dismiss(try #require(dismissals.clusters(all).first { $0.items.contains { $0.id == "q0" } }))
        let count = JournalInboxCount(ateWith: 1, recentPhotos: all, dismissals: dismissals)
        #expect(count.photos == dismissals.count(all) && count.photos == 3)
        #expect(count.total == 4)
    }
}
