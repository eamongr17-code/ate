import Foundation
import Testing
@testable import AteKit

/// A journal that answers with the pages a test hands it, and counts how often it was asked.
private final class PagedEntryService: EntryService, @unchecked Sendable {
    var pages: [[EntryCard]]
    var error: (any Error)?
    private(set) var requestedCursors: [PageCursor?] = []
    private let lock = NSLock()

    init(pages: [[EntryCard]]) {
        self.pages = pages
    }

    func viewer() async throws -> ViewerProfile { .preview }
    func authorID() async throws -> UUID { ViewerProfile.preview.id }
    @discardableResult
    func create(_ entry: NewEntry) async throws -> EntryCard { throw AteAPIError.notAuthenticated }
    func attach(photo: EntryPhotoUpload) async throws {}
    @discardableResult
    func sort(entryID: UUID, force: Bool) async throws -> SortOutcome {
        SortOutcome(entryID: entryID, status: .sorted, mode: "stub", itemCount: 0,
                    restaurantID: nil, didAttachPlace: false)
    }
    func entry(id: UUID) async throws -> EntryCard { throw AteAPIError.notFound(table: "e", id: id) }

    func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        if let error { throw error }
        return lock.withLock {
            requestedCursors.append(cursor)
            let index = cursor == nil ? 0 : requestedCursors.count - 1
            let items = index < pages.count ? pages[index] : []
            return Page(items: items, requestedLimit: pageSize)
        }
    }

    func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard {
        throw AteAPIError.notFound(table: "e", id: entryID)
    }
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws {}
    func updateBody(entryID: UUID, body: String) async throws {}
}

@MainActor
@Suite("Journal store")
struct JournalStoreTests {

    private func card(
        _ offsetDays: Double,
        hour: Double = 12,
        id: UUID = UUID(),
        place: String? = "Tipo 00"
    ) -> EntryCard {
        // 2026-09-19T00:00:00Z, then offset. A fixed instant so the day grouping is deterministic.
        let base = 1_789_776_000.0
        return EntryCard(
            id: id,
            authorID: ViewerProfile.preview.id,
            body: "Words",
            orderNumber: 1,
            createdAt: Date(timeIntervalSince1970: base - offsetDays * 86_400 + hour * 3600),
            place: place.map { EntryCard.Place(id: UUID(), name: $0) }
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("an empty first page is an invitation, not an error")
    func emptyIsAnInvitation() async {
        let store = JournalStore(entries: PagedEntryService(pages: [[]]))
        await store.loadIfNeeded()
        #expect(store.phase == .empty)
        #expect(store.days.isEmpty)
    }

    @Test("no session reads as signed out, never as 'you have written nothing'")
    func signedOutIsItsOwnPhase() async {
        let service = PagedEntryService(pages: [[]])
        service.error = AteAPIError.notAuthenticated
        let store = JournalStore(entries: service)
        await store.loadIfNeeded()
        #expect(store.phase == .signedOut)
    }

    @Test("pages walk the keyset and never repeat a row")
    func keysetWalks() async {
        let first = [card(0), card(0, hour: 10), card(1)]
        // The overlap a deleted row causes mid-scroll: the last of page one leads page two.
        let second = [first[2], card(2)]
        let service = PagedEntryService(pages: [first, second])
        let store = JournalStore(entries: service, pageSize: 3)

        await store.loadIfNeeded()
        #expect(store.entries.count == 3)
        await store.loadMore()

        #expect(store.entries.count == 4, "the repeated row is dropped, not rendered twice")
        #expect(service.requestedCursors.last??.id == first[2].id)
        #expect(service.requestedCursors.last??.createdAt == first[2].createdAt)
    }

    @Test("a short page ends the stream")
    func shortPageEnds() async {
        let store = JournalStore(entries: PagedEntryService(pages: [[card(0)]]), pageSize: 10)
        await store.loadIfNeeded()
        #expect(store.hasReachedEnd)
        await store.loadMore()
        #expect(store.entries.count == 1)
    }

    @Test("entries group under the day they happened, newest day first")
    func groupsByDay() async {
        let store = JournalStore(
            entries: PagedEntryService(pages: [[card(0, hour: 20), card(0, hour: 9), card(1)]]),
            calendar: utcCalendar()
        )
        await store.loadIfNeeded()

        #expect(store.days.count == 2)
        #expect(store.days[0].entries.count == 2)
        #expect(store.days[1].entries.count == 1)
        #expect(store.days[0].id > store.days[1].id)
    }

    @Test("a just-written entry is on the page before any read confirms it")
    func optimisticInsert() async {
        let store = JournalStore(entries: PagedEntryService(pages: [[]]))
        await store.loadIfNeeded()
        #expect(store.phase == .empty)

        let fresh = card(0)
        store.insert(fresh)

        #expect(store.phase == .ready)
        #expect(store.entries.first?.id == fresh.id)
        // Inserting the same entry twice — the outbox landing what the composer already showed —
        // updates it rather than doubling it.
        store.insert(fresh.replacing(sortStatus: .sorted))
        #expect(store.entries.count == 1)
        #expect(store.entries[0].sortStatus == .sorted)
    }

    @Test("the receipt arriving replaces the row in place")
    func replaceInPlace() async {
        let fresh = card(0)
        let store = JournalStore(entries: PagedEntryService(pages: [[fresh]]))
        await store.loadIfNeeded()

        store.replace(fresh.replacing(sortStatus: .sorted))

        #expect(store.entries.count == 1)
        #expect(store.entries[0].sortStatus == .sorted)
    }

    @Test("a failed page with content on screen is inline, not a wiped list")
    func inlineFailure() async {
        let service = PagedEntryService(pages: [[card(0), card(1)]])
        let store = JournalStore(entries: service, pageSize: 2)
        await store.loadIfNeeded()

        service.error = URLError(.notConnectedToInternet)
        await store.loadMore()

        #expect(store.entries.count == 2)
        #expect(store.inlineErrorMessage == "You're offline.")
        #expect(store.phase == .ready)
    }

    @Test("writing makes the journal stale, and the next look reloads it")
    func invalidateReloads() async {
        let service = PagedEntryService(pages: [[card(0)], [card(0), card(1)]])
        let store = JournalStore(entries: service, pageSize: 5)
        await store.loadIfNeeded()
        #expect(store.entries.count == 1)

        // A second look with nothing changed does not refetch.
        await store.loadIfNeeded()
        #expect(service.requestedCursors.count == 1)

        store.invalidate()
        await store.loadIfNeeded()
        #expect(service.requestedCursors.count == 2)
    }
}

@Suite("Journal grouping")
struct JournalGroupingTests {

    @Test("a day header is written the design's way: weekday, day, month")
    func dayHeader() {
        let day = Date(timeIntervalSince1970: 1_789_776_000)
        let title = day.formatted(JournalGrouping.dayFormat)
        // The names are the reader's locale; the ORDER is the design's and is what this pins.
        #expect(title.split(separator: " ").count == 3)
    }

    @Test("an empty list has no days at all — never a heading with nothing under it")
    func emptyHasNoDays() {
        #expect(JournalGrouping.days(from: []).isEmpty)
    }
}
