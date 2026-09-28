import Foundation
import Testing
@testable import AteKit

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
        let target = BrowseFixtures.card(1, isMine: true)
        let other = BrowseFixtures.card(2)
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
            Page(items: [BrowseFixtures.card(1)], requestedLimit: size)
        }
        await store.loadIfNeeded()
        store.remove(entryID: UUID())
        #expect(store.entries.count == 1)
        #expect(store.phase == .ready)
    }

    @MainActor
    @Test("The deleter: server first, then every list, then entry_deleted")
    func deleterSuccess() async {
        let target = BrowseFixtures.card(1, isMine: true, photos: ["preview://a/0", "preview://a/1"])
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
        let theirs = BrowseFixtures.card(1, isMine: false)
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
        let doomed = BrowseFixtures.card(1, isMine: true)
        let service = InMemoryEntryService(entries: [doomed, BrowseFixtures.card(2, isMine: true)])
        let journal = JournalStore(entries: service, pageSize: 1)
        await journal.loadIfNeeded()
        journal.remove(entryID: doomed.id)
        await journal.loadMore()
        #expect(journal.entries.contains { $0.id == doomed.id } == false)
    }
}

/// Collects what an ``AnalyticsRecorder`` was handed.
final class DeletionEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AnalyticsEvent] = []

    var events: [AnalyticsEvent] { lock.withLock { recorded } }

    var record: AnalyticsRecorder {
        { [self] event in lock.withLock { recorded.append(event) } }
    }
}
