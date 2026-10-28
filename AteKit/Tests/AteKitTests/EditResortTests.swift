import Foundation
import Testing
@testable import AteKit

@Suite("Editing the words reaches the server")
struct EditResortTests {
    private func score(_ value: Double, at location: Int) -> EntryTokenSpan {
        let token = EntryToken(kind: .score(Rating(exactly: value)!))
        return EntryTokenSpan(token: token, span: TextSpan(location: location, length: 3))
    }

    private func edit(
        from opened: EntryComposition, to now: EntryComposition, photos: [EntryEdit.Photo]? = nil
    ) -> EntryEdit {
        EntryEdit(
            entryID: UUID(), body: now.plain, originalRestaurantID: nil, restaurantID: nil,
            tagTokens: now.tagTokens, scoreTokens: now.scoreTokens,
            originalPhotos: [EntryCard.Photo(url: "a", position: 0)], photos: photos,
            tags: EditTagDiff(original: opened, current: now, items: []),
            originalBody: opened.plain
        )
    }

    @Test("a score changed in an edit (3.5 → 4.0) goes to a forced sort of the new words")
    func changedScore() async throws {
        let opened = EntryComposition(plain: "Tiramisu 3.5 honestly", spans: [score(3.5, at: 9)])
        let now = opened.replacing(tokenID: opened.spans[0].token.id, with: .score(Rating(exactly: 4)!))
        let service = SixRecorder()
        let change = edit(from: opened, to: now)
        try await change.save(to: service)
        let sorted = await change.sort(on: service)
        #expect(service.forced == [true])
        #expect(service.sortedBodies == ["Tiramisu 4.0 honestly"])
        // The entry as the sort left it comes back, so the page showing it can put the new lines up.
        #expect(sorted?.id == change.entryID)
    }

    @Test("a photo-only edit makes no sort call")
    func photoOnly() async throws {
        let opened = EntryComposition(plain: "Tiramisu 3.5", spans: [score(3.5, at: 9)])
        let service = SixRecorder()
        let change = edit(from: opened, to: opened, photos: [])
        #expect(await change.sort(on: service) == nil)
        #expect(service.forced.isEmpty)
        #expect(change.skipsSort)
    }

    @Test("a 6 given in an edit is sent as six_tokens on the forced sort")
    func sixAddedInAnEdit() async throws {
        let opened = EntryComposition(plain: "Tiramisu 4.0", spans: [score(4, at: 9)])
        let now = opened.replacing(tokenID: opened.spans[0].token.id, with: .score(.blownAway))
        let service = SixRecorder()
        let change = edit(from: opened, to: now)
        try await change.save(to: service)
        await change.sort(on: service)
        #expect(service.forced == [true])
        #expect(service.scores == [[TagToken(offset: 9, length: 3)]])
        #expect(service.sortedBodies == ["Tiramisu 6.0"])
    }
}

@Suite("New words' re-sort is owed until it lands (0097)")
struct OwedResortTests {
    private func edit(_ opened: String, _ now: String) -> EntryEdit {
        EntryEdit(
            entryID: UUID(), body: now, originalRestaurantID: nil, restaurantID: nil, tagTokens: [],
            originalBody: opened
        )
    }

    @Test("a re-sort that fails is left in the outbox, and the outbox's next run prints it")
    func failedResortIsOwed() async throws {
        let service = FlakySorter(failures: 1)
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let change = edit("Tiramisu 3.5", "Tiramisu 4.0")
        try await change.save(to: service)
        #expect(await change.sort(on: service, owing: outbox, authorID: UUID(), createdAt: Date()) == nil)
        let owed = try #require(await outbox.queued(entryID: change.entryID))
        #expect(owed.needsSort && owed.hasInserted, "owed a sort, never a second insert")

        #expect(await outbox.run() == [change.entryID])
        #expect(service.sorts == 2)
        #expect(service.inserts == 0)
        #expect(await outbox.queued(entryID: change.entryID) == nil)
    }

    @Test("a re-sort that lands leaves nothing owed; an edit with the same words owes nothing at all")
    func landedResortClears() async throws {
        let service = FlakySorter(failures: 0)
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let change = edit("Tiramisu 3.5", "Tiramisu 4.0")
        #expect(await change.sort(on: service, owing: outbox, authorID: UUID(), createdAt: Date()) != nil)
        #expect(await outbox.pendingCount == 0)

        let same = edit("Tiramisu 3.5", "Tiramisu 3.5")
        await same.sort(on: service, owing: outbox, authorID: UUID(), createdAt: Date())
        #expect(await outbox.pendingCount == 0)
    }
}

/// Fails its first `failures` sorts as a dropped connection would; counts every sort and insert.
private final class FlakySorter: EntryService, TestFake, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    private var sortCount = 0
    private var insertCount = 0
    var sorts: Int { lock.withLock { sortCount } }
    var inserts: Int { lock.withLock { insertCount } }

    init(failures: Int) { failuresLeft = failures }

    func updateBody(entryID: UUID, body: String) async throws {}
    func create(_ entry: NewEntry) async throws -> EntryCard {
        lock.withLock { insertCount += 1 }
        return EntryCard(id: entry.id, authorID: entry.authorID, body: entry.body, orderNumber: 1, createdAt: Date())
    }
    func entry(id: UUID) async throws -> EntryCard {
        EntryCard(id: id, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date())
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        try await sort(entryID: entryID, force: force, tagTokens: tagTokens, scoreTokens: nil)
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken], scoreTokens: [TagToken]?) async throws -> SortOutcome {
        let fails = lock.withLock {
            sortCount += 1
            guard failuresLeft > 0 else { return false }
            failuresLeft -= 1
            return true
        }
        if fails { throw URLError(.networkConnectionLost) }
        return SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 1, restaurantID: nil, didAttachPlace: false
        )
    }
}

/// Records the six tokens every sort was asked with.
final class SixRecorder: EntryService, TestFake, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[TagToken]] = []
    private var forces: [Bool] = []
    private var bodies: [String] = []
    var scores: [[TagToken]] { lock.withLock { log } }
    var forced: [Bool] { lock.withLock { forces } }
    /// The body the server holds at each sort — what it sorts from.
    var sortedBodies: [String] { lock.withLock { bodies } }
    private var body = ""

    func entry(id: UUID) async throws -> EntryCard {
        EntryCard(id: id, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date())
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        try await sort(entryID: entryID, force: force, tagTokens: tagTokens, scoreTokens: nil)
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken], scoreTokens: [TagToken]?) async throws -> SortOutcome {
        lock.withLock {
            log.append(scoreTokens ?? [])
            forces.append(force)
            bodies.append(body)
        }
        return SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 1, restaurantID: nil, didAttachPlace: false
        )
    }
    func updateBody(entryID: UUID, body: String) async throws { lock.withLock { self.body = body } }
}
