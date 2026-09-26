import Foundation
import Testing
@testable import AteKit

/// Records what an edit asked the server to do, in order.
private final class SortRecorder: EntryService, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var calls: [String] { lock.withLock { log } }
    private func add(_ call: String) { lock.withLock { log.append(call) } }

    func viewer() async throws -> ViewerProfile { .preview }
    func authorID() async throws -> UUID { UUID() }
    func create(_ entry: NewEntry) async throws -> EntryCard { throw URLError(.badURL) }
    func attach(photo: EntryPhotoUpload) async throws { add("upload \(photo.position)") }
    func attachExisting(entryID: UUID, position: Int, url: String) async throws { add("keep \(position)") }
    func removePhotos(entryID: UUID, fromPosition position: Int, removedURLs: [String]) async throws {
        add("remove from \(position)")
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        add("sort force=\(force)")
        return SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 1, restaurantID: nil, didAttachPlace: false
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
    func setTags(reviewID: UUID, tags: [DietTag]) async throws {
        add("tags \(tags.map(\.rawValue))")
    }
    func updateBody(entryID: UUID, body: String) async throws { add("body") }
}

/// QA, round 3: editing ANY tagged entry forced a re-sort, which rebuilds every uncorrected line —
/// a typo fix wiped hand corrections. Only a chip that is NEW to the edit may force one.
@Suite("Editing a tagged entry")
struct TaggedEditTests {
    private let dish = UUID()
    private let review = UUID()
    private let entryID = UUID()

    /// "Tiramisu V 3.0." — sorted, V a line tag, rebuilt into a chip as the edit opens.
    private var card: EntryCard {
        EntryCard(
            id: entryID, authorID: UUID(), body: "Tiramisu V 3.0.", orderNumber: 1, sortStatus: .sorted,
            createdAt: Date(),
            items: [EntryCard.Item(
                reviewID: review, dishID: dish, dishName: "Tiramisu", score: Rating(exactly: 3),
                note: nil, position: 1, tags: [.v]
            )]
        )
    }

    private func edit(
        _ opened: EntryComposition, _ now: EntryComposition, photos: [EntryEdit.Photo]? = nil
    ) -> EntryEdit {
        EntryEdit(
            entryID: entryID, body: now.plain, originalRestaurantID: nil, restaurantID: nil,
            tagTokens: now.tagTokens, originalPhotos: [EntryCard.Photo(url: "a", position: 0)], photos: photos,
            tags: EditTagDiff(original: opened, current: now, items: card.items)
        )
    }

    @Test("the edit opens with the line's chip in the words")
    func opensWithChip() {
        #expect(EntryBodyTokens.composition(for: card).tags == [.v])
    }

    @Test("a typo-only edit on a tagged entry does not force the sort")
    func typoOnly() async throws {
        let opened = EntryBodyTokens.composition(for: card)
        let typo = opened.applyingPlainEdit(replacing: TextSpan(location: 0, length: 8), with: "Tiramisù")
        #expect(typo.tags == [.v], "the chip survives the typo fix")
        let recorder = SortRecorder()
        let change = edit(opened, typo)
        try await change.save(to: recorder)
        await change.sort(on: recorder)
        #expect(recorder.calls == ["body", "sort force=false"])
    }

    @Test("a photo-only edit on a tagged entry does not force the sort")
    func photoOnly() async throws {
        let opened = EntryBodyTokens.composition(for: card)
        let recorder = SortRecorder()
        let change = edit(opened, opened, photos: [])
        try await change.save(to: recorder)
        await change.sort(on: recorder)
        #expect(recorder.calls == ["body", "remove from 0", "sort force=false"])
    }

    @Test("adding a new tag chip forces the sort")
    func newChip() async throws {
        let opened = EntryBodyTokens.composition(for: card)
        let caret = opened.displayString.utf16.count
        let chip = EntryToken(kind: .tag(DietTagMark(tag: .gf, text: "GF")))
        let (added, _) = opened.inserting(chip, atDisplayOffset: caret)
        let recorder = SortRecorder()
        let change = edit(opened, added)
        try await change.save(to: recorder)
        await change.sort(on: recorder)
        #expect(recorder.calls == ["body", "sort force=true"])
    }

    @Test("deleting a chip PATCHes its line's tags and does not force the sort")
    func removedChip() async throws {
        let opened = EntryBodyTokens.composition(for: card)
        let chip = try #require(opened.spans.first { $0.token.tag != nil })
        let removed = opened.removing(tokenID: chip.token.id)
        let recorder = SortRecorder()
        let change = edit(opened, removed)
        try await change.save(to: recorder)
        await change.sort(on: recorder)
        #expect(recorder.calls == ["body", "tags []", "sort force=false"])
    }
}
