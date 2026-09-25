import Foundation
import Testing

@testable import AteKit

/// **Nothing one person leaves on this phone reaches the next one.** Sign in as A, start an entry,
/// sign out, sign in as B: B's composer opens empty, and A's queued entry is never pushed as B.
@Suite("Per-user storage — the draft and the outbox", .serialized)
struct PerUserStorageTests {

    /// Who is "signed in", switchable mid-test.
    final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var user: UUID?
        var current: UUID? { lock.withLock { user } }
        func signIn(_ id: UUID?) { lock.withLock { user = id } }
    }

    func draft(_ words: String) -> EntryDraft {
        var draft = EntryDraft(id: UUID(), composition: EntryComposition(plain: words, spans: []), isPublic: true)
        draft.savedAt = Date()
        return draft
    }

    @Test("A's draft is never B's, and is still A's when A comes back")
    func draftsAreOwned() {
        let session = Session()
        let store = EntryDraftStore(containerName: "Tests-\(UUID().uuidString)", owner: { session.current })
        let alice = UUID()
        let bob = UUID()

        session.signIn(alice)
        store.save(draft("the cacio e pepe was a 4.5"))
        #expect(store.load() != nil)

        session.signIn(nil)
        #expect(store.load() == nil, "signed out, there is no draft")
        store.save(draft("nobody's words"))

        session.signIn(bob)
        #expect(store.load() == nil, "B inherited A's unposted draft")

        session.signIn(alice)
        #expect(store.load()?.composition.plain == "the cacio e pepe was a 4.5")
    }

    @Test("a deleted account's draft and photos are gone")
    func deletedAccountDraftIsGone() {
        let session = Session()
        let store = EntryDraftStore(containerName: "Tests-\(UUID().uuidString)", owner: { session.current })
        let alice = UUID()
        session.signIn(alice)
        let saved = draft("words")
        store.save(saved)
        let photos = store.photoDirectory(for: saved.id)
        try? Data([1]).write(to: photos.appending(path: "1.jpg"))
        store.discardDrafts(of: alice)
        #expect(store.load() == nil)
        #expect(FileManager.default.fileExists(atPath: photos.path(percentEncoded: false)) == false)
    }

    @Test("an unowned draft from before owners goes to the person signed in, and never to the next")
    func legacyDraft() throws {
        let container = "Tests-\(UUID().uuidString)"
        let legacy = EntryDraftStore(containerName: container)
        legacy.save(draft("written before this build"))

        let session = Session()
        let store = EntryDraftStore(containerName: container, owner: { session.current })
        let alice = UUID()
        session.signIn(alice)
        store.adoptUnownedDraft()
        #expect(store.load()?.composition.plain == "written before this build")
        #expect(legacy.load() == nil, "the unowned copy is gone once adopted")

        legacy.save(draft("left behind"))
        store.discardUnowned()
        session.signIn(UUID())
        store.adoptUnownedDraft()
        #expect(store.load() == nil)
    }

    @Test("the outbox pushes an entry only as its author, and a deleted author's entries go")
    func outboxIsOwned() async throws {
        let session = Session()
        let alice = UUID()
        let bob = UUID()
        let entries = InMemoryEntryService()
        let outbox = EntryOutbox(
            entries: entries, containerName: "Tests-\(UUID().uuidString)", owner: { session.current }
        )
        let entry = NewEntry(id: UUID(), authorID: alice, body: "queued offline",
                             restaurantID: nil, createdAt: Date())
        await outbox.enqueue(QueuedEntry(entry: QueuedInsert(entry), pendingPhotos: []))

        session.signIn(bob)
        #expect(await outbox.run().isEmpty, "A's entry was pushed as B")
        #expect(await outbox.isStuck(entryID: entry.id) == false, "and it must not be marked blocked")
        #expect(await outbox.pendingCount == 1)

        session.signIn(alice)
        #expect(await outbox.run() == [entry.id])

        await outbox.enqueue(QueuedEntry(entry: QueuedInsert(entry), pendingPhotos: []))
        await outbox.discard(authoredBy: alice)
        #expect(await outbox.pendingCount == 0)
    }
}
