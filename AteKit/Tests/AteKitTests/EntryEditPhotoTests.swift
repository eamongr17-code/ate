import Foundation
import Testing
@testable import AteKit

private final class PhotoRecorder: EntryService, TestFake, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var failBody = false
    var calls: [String] { lock.withLock { log } }
    private func add(_ call: String) { lock.withLock { log.append(call) } }
    func authorID() async throws -> UUID { UUID() }
    func create(_ entry: NewEntry) async throws -> EntryCard { throw URLError(.badURL) }
    func attach(photo: EntryPhotoUpload) async throws {
        add("upload \(photo.position) \(photo.objectName().suffix(11))")
    }
    func attachExisting(entryID: UUID, position: Int, url: String) async throws { add("keep \(position) \(url)") }
    func removePhotos(entryID: UUID, fromPosition position: Int, removedURLs: [String]) async throws {
        add("remove from \(position) \(removedURLs)")
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 0, restaurantID: nil, didAttachPlace: false
        )
    }
    func entry(id: UUID) async throws -> EntryCard {
        EntryCard(id: id, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date())
    }
    func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        Page(items: [], requestedLimit: pageSize)
    }
    func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard { try await entry(id: entryID) }
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws {}
    func setTags(reviewID: UUID, tags: [DietTag]) async throws {}
    func updateBody(entryID: UUID, body: String) async throws {
        if failBody { throw URLError(.notConnectedToInternet) }
        add("body")
    }
}

@Suite("Editing an entry's photos")
struct EntryEditPhotoTests {
    private let original = [EntryCard.Photo(url: "a", position: 0), EntryCard.Photo(url: "b", position: 1)]

    private func stagedFile() throws -> String {
        let url = URL.temporaryDirectory.appending(path: "added01.jpg")
        try Data([0xFF]).write(to: url)
        return url.path()
    }

    @Test("untouched photos are not written at all")
    func untouched() async throws {
        let recorder = PhotoRecorder()
        let edit = EntryEdit(entryID: UUID(), body: "x", originalRestaurantID: nil, restaurantID: nil, tagTokens: [],
                             originalPhotos: original, photos: [.existing(url: "a"), .existing(url: "b")])
        #expect(edit.changesPhotos == false)
        try await edit.save(to: recorder)
        #expect(recorder.calls == ["body"])
    }

    @Test("remove the first, add one: the kept one moves up, the new one uploads under its own name")
    func removeAndAdd() async throws {
        let recorder = PhotoRecorder()
        let path = try stagedFile()
        let edit = EntryEdit(entryID: UUID(), body: "x", originalRestaurantID: nil, restaurantID: nil, tagTokens: [],
                             originalPhotos: original, photos: [.existing(url: "b"), .added(path: path)])
        try await edit.save(to: recorder)
        #expect(recorder.calls == ["body", "keep 0 b", "upload 1 added01.jpg", "remove from 2 [\"a\"]"])
    }

    @Test("removing the last photo drops its row")
    func removeLast() async throws {
        let recorder = PhotoRecorder()
        let edit = EntryEdit(entryID: UUID(), body: "x", originalRestaurantID: nil, restaurantID: nil, tagTokens: [],
                             originalPhotos: original, photos: [.existing(url: "a")])
        try await edit.save(to: recorder)
        #expect(recorder.calls == ["body", "remove from 1 [\"b\"]"])
    }

    @Test("a failed write throws — the composer keeps everything and offers Try again")
    func failureThrows() async {
        let recorder = PhotoRecorder()
        recorder.failBody = true
        let edit = EntryEdit(entryID: UUID(), body: "x", originalRestaurantID: nil, restaurantID: nil, tagTokens: [])
        await #expect(throws: (any Error).self) { try await edit.save(to: recorder) }
        #expect(recorder.calls.isEmpty)
    }
}
