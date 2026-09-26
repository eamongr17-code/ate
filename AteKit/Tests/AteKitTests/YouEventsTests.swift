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

    /// **The parameter is locale-invariant.** A dashboard groups on the string, so a reader on
    /// `de_DE` sending `4,5` would silently split one bar into two series — and the half of the
    /// answer that came from Europe would be the half nobody noticed was missing.
    @Test("A score is sent with a period, wherever the reader is")
    func ratingsAreLocaleInvariant() {
        let comma = Locale(identifier: "de_DE")
        // The premise: a comma-decimal locale really does write this number with a comma, and
        // `ScoreFormat` — a *display* formatter — is built on exactly this style.
        #expect(4.5.formatted(.number.precision(.fractionLength(1)).locale(comma)) == "4,5")
        // The event is not. Every bar on the chart, in the one spelling a dashboard can group on.
        let sent = ScoreHistogram.scores.map {
            YouEvents.ratingsViewed(score: $0).parameters["score"]
        }
        #expect(sent == ["0.5", "1.0", "1.5", "2.0", "2.5", "3.0", "3.5", "4.0", "4.5", "5.0"])
        #expect(YouEvents.invariant(4.5) == "4.5")
        #expect(YouEvents.invariant(0.5) == "0.5")
        #expect(YouEvents.invariant(5) == "5.0")
        // …and no thousands separator can creep in either.
        #expect(YouEvents.invariant(1234.5) == "1234.5")
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
        #expect(ReceiptShareSource.allCases.map(\.rawValue)
            == ["entry", "actions", "statement", "summary", "instagram_stories"])
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
