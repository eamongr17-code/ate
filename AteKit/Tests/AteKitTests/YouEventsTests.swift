import Foundation
import Testing

@testable import AteKit

/// The You tab's funnel and the north-star share event, pinned. A dashboard cannot tell you an event
/// was renamed — it just goes quiet — so the names live in one enum and are asserted here.
@Suite("You and share events")
struct YouEventsTests {

    @Test("The tab's own view")
    func viewed() {
        let event = YouEvents.youViewed()
        #expect(event.name == "you_viewed")
        #expect(event.parameters.isEmpty)
    }

    /// The score is the whole point: it answers "which of their own ratings do people go back and
    /// look at", and it has to read the same as every other score in the product — one decimal.
    @Test("A ratings page carries the bar it opened on, snapped to a half-step")
    func ratings() {
        let event = YouEvents.ratingsViewed(score: 4.5)
        #expect(event.name == "ratings_viewed")
        #expect(event.parameters == ["score": "4.5"])
        #expect(YouEvents.ratingsViewed(score: 4).parameters == ["score": "4.0"])
        #expect(YouEvents.ratingsViewed(score: 4.3).parameters == ["score": "4.5"])
    }

    /// `YYYY-MM`, so a month reads the same in every time zone — the same reason ``StatementMonth``
    /// is not a `Date`.
    @Test("A statement carries its month, not an instant")
    func statement() {
        let event = YouEvents.statementViewed(month: StatementMonth(year: 2026, month: 9))
        #expect(event.name == "statement_viewed")
        #expect(event.parameters == ["month": "2026-09"])
    }

    /// The north-star event. Both parameters earn their place: which receipt left, and from which
    /// surface — the share icon, an actions sheet and a statement are three different products.
    @Test("A shared receipt carries its entry and where the share started")
    func shared() {
        let id = UUID(uuidString: "7D9CA1E9-C846-4137-8803-F486EFE05557")!
        let fromEntry = EntryEvents.receiptShared(entryID: id, source: .entry)
        #expect(fromEntry.name == "receipt_shared")
        #expect(fromEntry.parameters == [
            "entry_id": "7d9ca1e9-c846-4137-8803-f486efe05557", "source": "entry"
        ])
        #expect(EntryEvents.receiptShared(entryID: id, source: .actions)
            .parameters["source"] == "actions")
        #expect(ReceiptShareSource.allCases.map(\.rawValue) == ["entry", "actions", "statement"])
    }

    /// A statement is a receipt with no entry behind it. An empty string would read as a real id in
    /// a query, so the key is simply absent.
    @Test("A statement's share carries no entry id at all")
    func sharedStatement() {
        let event = EntryEvents.receiptShared(entryID: nil, source: .statement)
        #expect(event.parameters == ["source": "statement"])
        #expect(event.parameters["entry_id"] == nil)
    }
}
