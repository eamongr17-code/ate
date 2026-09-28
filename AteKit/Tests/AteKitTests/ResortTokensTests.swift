import Foundation
import Testing
@testable import AteKit

@Suite("Print it again carries the entry's 6s and chips")
struct ResortTokensTests {
    private let six = TagToken(offset: 9, length: 3)

    @Test("after a first sort that failed, the outbox's own tokens are sent")
    func fromTheOutbox() {
        let insert = QueuedInsert(NewEntry(
            id: UUID(), authorID: UUID(), body: "Tiramisu 6.0", restaurantID: nil, createdAt: Date()
        ))
        let queued = QueuedEntry(
            entry: insert, pendingPhotos: [], hasInserted: true,
            tagTokens: [TagToken(offset: 0, length: 2)], sixTokens: [six]
        )
        // The card has no lines yet — the sort failed — so only the outbox knows about the 6.
        let card = EntryCard(
            id: insert.id, authorID: insert.authorID, body: insert.body, orderNumber: 1, createdAt: Date()
        )
        let tokens = ResortTokens.resolve(queued: queued, card: card)
        #expect(tokens.sixes == [six])
        #expect(tokens.tags == [TagToken(offset: 0, length: 2)])
    }

    @Test("a sorted entry's 6 is rebuilt from its lines")
    func fromTheLines() {
        let card = EntryCard(
            id: UUID(), authorID: UUID(), body: "Tiramisu 6.0", orderNumber: 1, sortStatus: .sorted,
            createdAt: Date(),
            items: [EntryCard.Item(
                reviewID: UUID(), dishID: UUID(), dishName: "Tiramisu", score: .blownAway, position: 1,
                evidenceOffset: 9, evidenceLength: 3, mentionOffset: 0, mentionLength: 8
            )]
        )
        #expect(ResortTokens.resolve(queued: nil, card: card).sixes == [six])
    }

    @Test("nothing known, nothing sent")
    func empty() {
        #expect(ResortTokens.resolve(queued: nil, card: nil) == ResortTokens(tags: [], sixes: []))
    }
}
