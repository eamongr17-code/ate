import Foundation
import Testing
@testable import AteKit

/// The pure parts of the 26 Sep design round: the edge's arithmetic, the letter tile, and the
/// Summary's watching.
@Suite("Edge B — the scallop fitted to the width")
struct WaveEdgeTests {
    @Test("the board's own widths fit a whole number of scallops", arguments: [
        (366.0, 30, 12.2),
        (350.0, 29, 12.068_965),
        (286.0, 24, 11.916_666)
    ])
    func fitted(width: Double, count: Int, period: Double) {
        #expect(WaveEdge.periodCount(forWidth: width) == count)
        #expect(abs(WaveEdge.period(forWidth: width) - period) < 0.001)
    }

    @Test("both ends land on a valley, and the middle of a period is the crest")
    func symmetrical() {
        let width = 366.0
        let period = WaveEdge.period(forWidth: width)
        #expect(abs(WaveEdge.depth(atX: 0, width: width) - WaveEdge.valley) < 0.0001)
        #expect(abs(WaveEdge.depth(atX: width, width: width) - WaveEdge.valley) < 0.0001)
        #expect(abs(WaveEdge.depth(atX: period / 2, width: width) - WaveEdge.crest) < 0.0001)
        // Mirror-symmetric about the centre of the card.
        #expect(abs(WaveEdge.depth(atX: 37, width: width) - WaveEdge.depth(atX: width - 37, width: width)) < 0.0001)
    }

    @Test("a sliver still gets one scallop, and nothing divides by zero")
    func degenerate() {
        #expect(WaveEdge.periodCount(forWidth: 3) == 1)
        #expect(WaveEdge.periodCount(forWidth: 0) == 1)
        #expect(WaveEdge.period(forWidth: 0) == WaveEdge.targetPeriod)
    }
}

@Suite("The letter tile — a photo-less dish is never a grey square")
struct LetterTileTests {
    @Test("the name's own first letter, capitalised")
    func initial() {
        #expect(DishTileIdentity.initial(for: "Tiramisu") == "T")
        #expect(DishTileIdentity.initial(for: "cheeseburger") == "C")
        #expect(DishTileIdentity.initial(for: "'nduja pizza") == "N")
        #expect(DishTileIdentity.initial(for: "The Big Breakfast") == "T")
        #expect(DishTileIdentity.initial(for: "  ") == DishTileIdentity.initialPlaceholder)
    }

    @Test("the colour is the dish's, not the row's: the same id always picks the same accent")
    func stableColour() throws {
        let id = try #require(UUID(uuidString: "D7E00000-0000-4000-8000-000000000002"))
        let first = DishTileIdentity.paletteIndex(for: id, count: 5)
        #expect((0..<20).allSatisfy { _ in DishTileIdentity.paletteIndex(for: id, count: 5) == first })
        #expect((0..<5).contains(first))
    }
}

@Suite("The Summary after Done")
@MainActor
struct EntrySummaryStoreTests {
    private func card(_ status: EntrySortStatus, id: UUID = UUID()) -> EntryCard {
        EntryCard(id: id, authorID: UUID(), body: "The ragù 4.5.", orderNumber: 142, sortStatus: status,
                  createdAt: Date(timeIntervalSince1970: 1_789_000_000))
    }

    /// Hands out the given rows in order, then keeps repeating the last.
    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [EntryCard?]
        private(set) var calls = 0
        init(_ rows: [EntryCard?]) { self.rows = rows }
        func next() throws -> EntryCard {
            try lock.withLock {
                calls += 1
                let row = rows.count > 1 ? rows.removeFirst() : rows.first.flatMap { $0 }
                guard let row else { throw AteAPIError.notFound(table: "entry_cards", id: UUID()) }
                return row
            }
        }
    }

    @Test("it prints the moment the sorter answers, and stops asking")
    func printsWhenSorted() async {
        let id = UUID()
        let replies = Replies([card(.pending, id: id), nil, card(.sorted, id: id), card(.sorted, id: id)])
        let store = EntrySummaryStore(card: card(.pending, id: id), pollInterval: .zero, maxPolls: 10) { _ in
            try replies.next()
        }
        #expect(store.phase == .sorting)
        await store.watch()
        #expect(store.phase == .printed)
        #expect(store.card.sortStatus == .sorted)
        #expect(replies.calls == 3, "a failed read is one more wait; the sorted row ends it")
    }

    @Test("a sorter that fails, or never answers, stalls rather than breathing forever")
    func stalls() async {
        let failed = EntrySummaryStore(card: card(.pending), pollInterval: .zero, maxPolls: 5) { _ in
            EntryCard(id: UUID(), authorID: UUID(), body: "", orderNumber: 1, sortStatus: .failed,
                      createdAt: Date())
        }
        await failed.watch()
        #expect(failed.phase == .stalled)

        let slow = EntrySummaryStore(card: card(.pending), pollInterval: .zero, maxPolls: 3) { _ in
            EntryCard(id: UUID(), authorID: UUID(), body: "", orderNumber: 1, sortStatus: .pending,
                      createdAt: Date())
        }
        await slow.watch()
        #expect(slow.phase == .stalled)
    }

    @Test("an entry already sorted opens printed and is never polled")
    func alreadySorted() async {
        let replies = Replies([])
        let store = EntrySummaryStore(card: card(.sorted), pollInterval: .zero) { _ in try replies.next() }
        await store.watch()
        #expect(store.phase == .printed)
        #expect(replies.calls == 0)
    }

    @Test("summary_shared and summary_done name their entry; Done says whether it had printed")
    func events() {
        let id = UUID()
        #expect(EntryEvents.summaryShared(entryID: id).name == "summary_shared")
        #expect(EntryEvents.summaryShared(entryID: id).parameters["entry_id"] == id.uuidString.lowercased())
        let done = EntryEvents.summaryDone(entryID: id, wasPrinted: false)
        #expect(done.name == "summary_done")
        #expect(done.parameters["printed"] == "false")
        #expect(EntryEvents.receiptShared(entryID: id, source: .summary).parameters["source"] == "summary")
    }
}
