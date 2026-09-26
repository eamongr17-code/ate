import Foundation
import Testing
@testable import AteKit

// Round 3's browse lane: deleting an entry, the Feed's area, thumbnails, and load failures.

private func card(
    _ minutesAgo: Double,
    id: UUID = UUID(),
    isMine: Bool = false,
    photos: [String] = [],
    city: String? = "Melbourne"
) -> EntryCard {
    let author = isMine ? ViewerProfile.preview.id : UUID()
    return EntryCard(
        id: id,
        authorID: author,
        body: "Tipo 00 was good.",
        orderNumber: 1,
        sortStatus: .sorted,
        createdAt: Date(timeIntervalSince1970: 1_789_776_000 - minutesAgo * 60),
        isMine: isMine,
        author: EntryCard.Author(id: author, username: "jessw"),
        place: EntryCard.Place(id: UUID(), name: "Tipo 00", city: city),
        photos: photos.enumerated().map { EntryCard.Photo(url: $1, position: $0) },
        items: [EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Prawn spaghetti",
                               score: Rating(rounding: 5), position: 1)]
    )
}

// MARK: - Photo addresses

@Suite("Photo addresses")
struct PhotoAddressTests {

    @Test("A thumbnail sits beside its photo: the extension becomes _t.jpg")
    func thumbnailPath() {
        #expect(PhotoAddress.thumbnailPath(for: "u/e-0.jpg") == "u/e-0_t.jpg")
        #expect(PhotoAddress.thumbnailPath(for: "u/e-0.jpeg") == "u/e-0_t.jpg")
        #expect(PhotoAddress.thumbnailPath(for: "u/e-0.HEIC") == "u/e-0_t.jpg")
        #expect(PhotoAddress.thumbnailPath(for: "e-0") == "e-0_t.jpg")
        // A dot in a folder is not an extension.
        #expect(PhotoAddress.thumbnailPath(for: "a.b/photo") == "a.b/photo_t.jpg")
    }

    @Test("A thumbnail has no thumbnail, and nothing has none")
    func noThumbnail() {
        #expect(PhotoAddress.thumbnailPath(for: "u/e-0_t.jpg") == nil)
        #expect(PhotoAddress.thumbnailPath(for: "") == nil)
        #expect(PhotoAddress.thumbnailPath(for: "u/") == nil)
        #expect(PhotoAddress.thumbnailPath(for: "u/.jpg") == nil)
    }

    @Test("A public URL's thumbnail keeps its host and query; a fixture has none")
    func thumbnailURL() throws {
        let url = try #require(URL(string:
            "https://x.supabase.co/storage/v1/object/public/review-photos/u/e-1.jpg?v=2"))
        #expect(PhotoAddress.thumbnailURL(for: url)?.absoluteString
            == "https://x.supabase.co/storage/v1/object/public/review-photos/u/e-1_t.jpg?v=2")
        #expect(PhotoAddress.thumbnailURL(for: try #require(URL(string: "asset://ragu"))) == nil)
        #expect(PhotoAddress.thumbnailURL(for: try #require(URL(string: "preview://abc/0"))) == nil)
    }

    @Test("A deleted entry's files: every photo and its thumbnail, once each")
    func withThumbnails() {
        #expect(PhotoAddress.withThumbnails(["u/e-0.jpg", "u/e-1.jpg", "u/e-0.jpg"])
            == ["u/e-0.jpg", "u/e-0_t.jpg", "u/e-1.jpg", "u/e-1_t.jpg"])
        #expect(PhotoAddress.withThumbnails([]) == [])
    }

    @Test("The same address is the same photo, every time; two addresses are two")
    func stableID() {
        let one = PhotoAddress.stableID(for: "https://x/a.jpg")
        #expect(one == PhotoAddress.stableID(for: "https://x/a.jpg"))
        #expect(one != PhotoAddress.stableID(for: "https://x/b.jpg"))
        #expect(PhotoAddress.cacheKey(for: "https://x/a.jpg").count == 64)
    }

    @Test("Prefetch warms the next entries' photos, in scroll order, three from each")
    func upcoming() {
        let entries = [
            card(1, photos: ["a0", "a1"]),
            card(2, photos: ["b0", "b1", "b2", "b3"]),
            card(3),
            card(4, photos: ["d0"])
        ]
        #expect(PhotoAddress.upcoming(in: entries, after: 0) == ["b0", "b1", "b2", "d0"])
        #expect(PhotoAddress.upcoming(in: entries, after: 0, lookahead: 1) == ["b0", "b1", "b2"])
        #expect(PhotoAddress.upcoming(in: entries, after: 3).isEmpty)
        #expect(PhotoAddress.upcoming(in: entries, after: -1, lookahead: 1) == ["a0", "a1"])
    }
}

// MARK: - Deleting an entry

@Suite("Entry deletion")
struct EntryDeletionTests {

    @Test("P0002 is already deleted — success; anything else is a refusal")
    func alreadyGone() {
        #expect(EntryDeletion.isAlreadyGone(code: "P0002"))
        #expect(EntryDeletion.isAlreadyGone(code: "42501") == false)
        #expect(EntryDeletion.isAlreadyGone(code: nil) == false)
    }

    @Test("delete_entry's answer decodes as an object, a row, or nothing")
    func decode() throws {
        let object = Data(#"{"photo_paths":["u/e-0.jpg","u/e-0_t.jpg"]}"#.utf8)
        #expect(try EntryDeletion.decode(object).photoPaths == ["u/e-0.jpg", "u/e-0_t.jpg"])
        // The server lists thumbnails already; they are not doubled.
        #expect(try EntryDeletion.decode(object).storageFiles == ["u/e-0.jpg", "u/e-0_t.jpg"])
        let rows = Data(#"[{"photo_paths":["u/e-0.jpg","u/e-1.jpg"]}]"#.utf8)
        #expect(try EntryDeletion.decode(rows).photoPaths == ["u/e-0.jpg", "u/e-1.jpg"])
        #expect(try EntryDeletion.decode(Data(#"{}"#.utf8)).photoPaths.isEmpty)
        #expect(try EntryDeletion.decode(Data("null".utf8)).photoPaths.isEmpty)
    }

    @Test("Storage files are bucket paths plus thumbnails, even when the server answers with URLs")
    func storageFiles() {
        let deletion = EntryDeletion(photoPaths: [
            "u/e-0.jpg",
            "https://x.supabase.co/storage/v1/object/public/review-photos/u/e-1.jpg",
            "/u/e-2.jpg"
        ])
        #expect(deletion.storageFiles == [
            "u/e-0.jpg", "u/e-0_t.jpg", "u/e-1.jpg", "u/e-1_t.jpg", "u/e-2.jpg", "u/e-2_t.jpg"
        ])
    }

    @MainActor
    @Test("A delete leaves the feed, the journal and a profile in the same turn")
    func broadcastEmptiesEveryList() async {
        let target = card(1, isMine: true)
        let other = card(2)
        let deletions = EntryDeletions()
        let feed = EntryListStore(fallbackMessage: "x") { _, size in
            Page(items: [target, other], requestedLimit: size)
        }
        feed.listen(to: deletions)
        let profile = ProfileStore(
            userID: target.authorID, profiles: InMemorySocialService(entries: [target]),
            deletions: deletions
        )
        let service = InMemoryEntryService(entries: [target])
        let journal = JournalStore(entries: service, deletions: deletions)
        await feed.loadIfNeeded()
        await journal.loadIfNeeded()
        await profile.load()
        #expect(profile.entries.entries.map(\.id) == [target.id])

        deletions.send(target.id)

        #expect(feed.entries.map(\.id) == [other.id])
        #expect(feed.phase == .ready)
        #expect(journal.entries.isEmpty)
        #expect(journal.phase == .empty)
        #expect(journal.days.isEmpty)
        #expect(profile.entries.entries.isEmpty)
        #expect(profile.entries.phase == .empty)
    }

    @MainActor
    @Test("A list that is gone stops listening")
    func weakObservers() {
        let deletions = EntryDeletions()
        do {
            let store = EntryListStore(fallbackMessage: "x") { _, size in Page(items: [], requestedLimit: size) }
            store.listen(to: deletions)
            #expect(deletions.observerCount == 1)
        }
        #expect(deletions.observerCount == 0)
    }

    @MainActor
    @Test("A delete removes nothing it does not hold, and never un-empties a failed list")
    func removeUnknown() async {
        let store = EntryListStore(fallbackMessage: "x") { _, size in
            Page(items: [card(1)], requestedLimit: size)
        }
        await store.loadIfNeeded()
        store.remove(entryID: UUID())
        #expect(store.entries.count == 1)
        #expect(store.phase == .ready)
    }

    @MainActor
    @Test("The deleter: server first, then every list, then entry_deleted")
    func deleterSuccess() async {
        let target = card(1, isMine: true, photos: ["preview://a/0", "preview://a/1"])
        let service = InMemoryEntryService(entries: [target])
        let deletions = EntryDeletions()
        let journal = JournalStore(entries: service)
        deletions.add(journal)
        await journal.loadIfNeeded()
        let events = DeletionEventLog()
        let deleter = EntryDeleter(entries: service, deletions: deletions, analytics: events.record)

        #expect(await deleter.delete(target))

        #expect(journal.entries.isEmpty)
        #expect(events.events == [AnalyticsEvent(
            name: "entry_deleted", parameters: ["photo_count": "2", "dish_count": "1"]
        )])
        // And the server agrees: the entry is gone, not merely hidden.
        await #expect(throws: AteAPIError.self) { _ = try await service.entry(id: target.id) }
    }

    @MainActor
    @Test("A refused delete moves nothing and reports nothing")
    func deleterFailure() async {
        let theirs = card(1, isMine: false)
        let service = InMemoryEntryService(entries: [theirs])
        let deletions = EntryDeletions()
        let feed = EntryListStore(fallbackMessage: "x") { _, size in Page(items: [theirs], requestedLimit: size) }
        feed.listen(to: deletions)
        await feed.loadIfNeeded()
        let events = DeletionEventLog()
        let deleter = EntryDeleter(entries: service, deletions: deletions, analytics: events.record)

        #expect(await deleter.delete(theirs) == false)
        #expect(feed.entries.map(\.id) == [theirs.id])
        #expect(events.events.isEmpty)
    }

    @MainActor
    @Test("A journal page read before the delete cannot bring the entry back")
    func staleNextPage() async {
        let doomed = card(1, isMine: true)
        let service = InMemoryEntryService(entries: [doomed, card(2, isMine: true)])
        let journal = JournalStore(entries: service, pageSize: 1)
        await journal.loadIfNeeded()
        journal.remove(entryID: doomed.id)
        await journal.loadMore()
        #expect(journal.entries.contains { $0.id == doomed.id } == false)
    }
}

/// Collects what an ``AnalyticsRecorder`` was handed.
private final class DeletionEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AnalyticsEvent] = []

    var events: [AnalyticsEvent] { lock.withLock { recorded } }

    var record: AnalyticsRecorder {
        { [self] event in lock.withLock { recorded.append(event) } }
    }
}

// MARK: - The Feed's area

@Suite("Feed area")
struct FeedAreaTests {

    @Test("feed_areas decodes busiest first, ties by name, blanks and repeats dropped")
    func decode() throws {
        let data = Data(#"""
        [{"area":"Carlton","entry_count":3},{"area":"CBD","entry_count":12},
         {"area":"","entry_count":40},{"area":"Brunswick","entry_count":3},{"area":"CBD","entry_count":1},
         {"area":"Fitzroy","count":2}]
        """#.utf8)
        let areas = try FeedArea.decodeList(data)
        #expect(areas.map(\.area) == ["CBD", "Brunswick", "Carlton", "Fitzroy"])
        #expect(areas.map(\.count) == [12, 3, 3, 2])
    }

    @MainActor
    @Test("A choice is remembered per person, and Everywhere is nil")
    func perPerson() {
        let store = InMemoryKeyValueStore()
        let eamon = UUID()
        let jess = UUID()
        let owner = OwnerBox(eamon)
        let model = FeedAreaModel(
            reader: InMemorySocialService(), store: store, owner: { owner.value }
        )
        #expect(model.selected == nil)
        #expect(model.choose("Melbourne"))
        #expect(model.choose("Melbourne") == false)
        #expect(store.value(forKey: FeedAreaModel.key(for: eamon)) == "Melbourne")

        owner.value = jess
        model.reloadSelection()
        #expect(model.selected == nil)

        owner.value = eamon
        let again = FeedAreaModel(reader: InMemorySocialService(), store: store, owner: { owner.value })
        #expect(again.selected == "Melbourne")
        again.choose(nil)
        #expect(store.value(forKey: FeedAreaModel.key(for: eamon)) == nil)
    }

    @MainActor
    @Test("feed_area_changed names the area and its rank; Everywhere has no rank")
    func telemetry() async {
        let events = DeletionEventLog()
        let model = FeedAreaModel(
            reader: InMemorySocialService(), store: InMemoryKeyValueStore(), owner: { nil },
            analytics: events.record
        )
        await model.loadAreas()
        // The seed: most visits in the CBD, one in North Melbourne.
        #expect(model.areas.map(\.area) == ["CBD", "North Melbourne"])
        #expect(model.hasReachedEnd)
        model.choose("North Melbourne")
        model.choose(nil)
        #expect(events.events == [
            AnalyticsEvent(name: "feed_area_changed", parameters: ["area": "North Melbourne", "rank": "1"]),
            AnalyticsEvent(name: "feed_area_changed", parameters: ["area": "everywhere"])
        ])
    }

    @Test("The keyset: busier first, then by name — and a cursor pages strictly after itself")
    func keyset() {
        let cbd = FeedArea(area: "CBD", count: 5)
        #expect(FeedArea.isAfter(FeedArea(area: "Carlton", count: 3), cursor: cbd))
        #expect(FeedArea.isAfter(FeedArea(area: "Collingwood", count: 5), cursor: cbd))
        #expect(FeedArea.isAfter(FeedArea(area: "Abbotsford", count: 5), cursor: cbd) == false)
        #expect(FeedArea.isAfter(cbd, cursor: cbd) == false)
        #expect(FeedArea.clampedLimit(500) == 100)
        #expect(FeedArea.clampedLimit(0) == 1)
    }

    @MainActor
    @Test("The sheet pages feed_areas as it scrolls, deduped, until a short page")
    func paging() async {
        let areas = (1...5).map { FeedArea(area: "Area \($0)", count: 10 - $0) }
        let reader = PagedAreas(areas)
        let model = FeedAreaModel(
            reader: reader, store: InMemoryKeyValueStore(), owner: { nil }, pageSize: 2
        )
        await model.loadAreas()
        #expect(model.areas.map(\.area) == ["Area 1", "Area 2"])
        #expect(model.hasReachedEnd == false)
        await model.loadMoreAreasIfNeeded(after: model.areas[1])
        await model.loadMoreAreas()
        #expect(model.areas.map(\.area) == ["Area 1", "Area 2", "Area 3", "Area 4", "Area 5"])
        #expect(model.hasReachedEnd)
        #expect(reader.cursors == [nil, "Area 2", "Area 4"])
        // Reopening starts again from the top: counts move.
        await model.loadAreas()
        #expect(model.areas.count == 2)
    }

    @MainActor
    @Test("Changing area starts the list again from nothing, and reads the new area")
    func reloadForArea() async {
        let areas = AreaBox()
        let store = EntryListStore(fallbackMessage: "x") { _, size in
            let area = await areas.value
            return Page(items: area == nil ? [card(1), card(2)] : [card(3)], requestedLimit: size)
        }
        await store.loadIfNeeded()
        #expect(store.entries.count == 2)
        await areas.set("Carlton")
        await store.reload()
        #expect(store.entries.count == 1)
        #expect(store.phase == .ready)
        #expect(store.pagesLoaded == 1)
    }

    @Test("The in-memory feed filters by area, and everywhere is everything")
    func filter() async throws {
        let social = InMemorySocialService(entries: [card(1, city: "Melbourne"), card(2, city: "Sydney")])
        let everywhere = try await social.feedPage(after: nil, pageSize: 10, includeOwn: false, area: nil)
        let sydney = try await social.feedPage(after: nil, pageSize: 10, includeOwn: false, area: "Sydney")
        #expect(everywhere.items.count == 2)
        #expect(sydney.items.count == 1)
    }
}

/// `feed_areas`, paged the way the server pages it — and remembering the cursors it was handed.
private final class PagedAreas: EntryFeedReading, @unchecked Sendable {
    private let all: [FeedArea]
    private let lock = NSLock()
    private var asked: [String?] = []

    init(_ all: [FeedArea]) { self.all = all }

    var cursors: [String?] { lock.withLock { asked } }

    func feedPage(after cursor: PageCursor?, pageSize: Int, includeOwn: Bool, area: String?)
        async throws -> Page<EntryCard> { Page(items: [], requestedLimit: pageSize) }

    func feedAreas(after cursor: FeedArea?, limit: Int) async throws -> [FeedArea] {
        lock.withLock {
            asked.append(cursor?.area)
            let rest = cursor.map { cursor in all.filter { FeedArea.isAfter($0, cursor: cursor) } } ?? all
            return Array(rest.prefix(limit))
        }
    }
}

@MainActor
private final class AreaBox {
    var value: String?
    func set(_ area: String?) { value = area }
}

private final class OwnerBox: @unchecked Sendable {
    var value: UUID?
    init(_ value: UUID?) { self.value = value }
}

// MARK: - Load failures

@Suite("Load failure")
struct LoadFailureTests {

    @Test("No row is gone; everything else is couldn't-reach-Ate")
    func classify() {
        #expect(LoadFailure(AteAPIError.notFound(table: "entry_cards", id: UUID())) == .gone)
        #expect(LoadFailure(URLError(.notConnectedToInternet)) == .unreachable)
        #expect(LoadFailure(URLError(.timedOut)) == .unreachable)
        #expect(LoadFailure(AteAPIError.notAuthenticated) == .unreachable)
        #expect(LoadFailure(CocoaError(.fileReadCorruptFile)) == .unreachable)
    }
}
