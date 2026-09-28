import Foundation
import Testing
@testable import AteKit

@MainActor
@Suite("The entry page's refresh")
struct EntryRefreshTests {
    @Test("gone is gone even over the card the page was drawn from; other failures keep the card")
    func refreshFailures() {
        let gone = AteAPIError.notFound(table: "entry_cards", id: UUID())
        #expect(EntryRefreshFailure(gone, hasCard: true) == .gone)
        #expect(EntryRefreshFailure(gone, hasCard: false) == .gone)
        #expect(EntryRefreshFailure(URLError(.timedOut), hasCard: true) == .keepCardAndRetry)
        #expect(EntryRefreshFailure(URLError(.timedOut), hasCard: false) == .unreachable)
        #expect(EntryRefreshFailure(URLError(.cancelled), hasCard: true) == .ignore)
        #expect(EntryRefreshFailure(CancellationError(), hasCard: false) == .ignore)
    }

    @Test("a bookmark heard before the refresh answers survives the older row, tags and all")
    func saveEditsOutliveOlderReads() {
        let read = JournalFixtures.card(2026, 9, 1, tags: [.gf])
        let dish = read.items[0].dishID
        var edits = EntrySaveEdits()
        edits.note(dishID: dish, isSaved: true)
        let shown = edits.applied(to: read)
        #expect(shown.items[0].saved)
        #expect(shown.items[0].tags == [.gf], "a bookmark never strips a line's tags")
        #expect(EntrySaveEdits().applied(to: read) == read)
    }
}
