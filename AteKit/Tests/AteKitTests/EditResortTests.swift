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
            tagTokens: now.tagTokens, sixTokens: now.sixTokens,
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
        await change.sort(on: service)
        #expect(service.forced == [true])
        #expect(service.sortedBodies == ["Tiramisu 4.0 honestly"])
    }

    @Test("a photo-only edit makes no sort call")
    func photoOnly() async throws {
        let opened = EntryComposition(plain: "Tiramisu 3.5", spans: [score(3.5, at: 9)])
        let service = SixRecorder()
        let change = edit(from: opened, to: opened, photos: [])
        await change.sort(on: service)
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
        #expect(service.sixes == [[TagToken(offset: 9, length: 3)]])
        #expect(service.sortedBodies == ["Tiramisu 6.0"])
    }
}

/// Records the six tokens every sort was asked with.
final class SixRecorder: EntryService, TestFake, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[TagToken]] = []
    private var forces: [Bool] = []
    private var bodies: [String] = []
    var sixes: [[TagToken]] { lock.withLock { log } }
    var forced: [Bool] { lock.withLock { forces } }
    /// The body the server holds at each sort — what it sorts from.
    var sortedBodies: [String] { lock.withLock { bodies } }
    private var body = ""

    func entry(id: UUID) async throws -> EntryCard {
        EntryCard(id: id, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date())
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        try await sort(entryID: entryID, force: force, tagTokens: tagTokens, sixTokens: [])
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken], sixTokens: [TagToken]) async throws -> SortOutcome {
        lock.withLock {
            log.append(sixTokens)
            forces.append(force)
            bodies.append(body)
        }
        return SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 1, restaurantID: nil, didAttachPlace: false
        )
    }
    func updateBody(entryID: UUID, body: String) async throws { lock.withLock { self.body = body } }
}
