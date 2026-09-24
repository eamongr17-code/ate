import Foundation
import Testing

@testable import AteKit

/// **Walking the statements.**
///
/// The walk is over months that *exist*, not over the calendar: `statement_months` only answers with
/// months that have entries, and turning to an empty one would print a receipt for a month where
/// nothing was ever printed (design rule 4).
@Suite("Statement months")
struct StatementMonthsTests {

    private func month(_ year: Int, _ month: Int) -> StatementMonth {
        StatementMonth(year: year, month: month)
    }

    @Test("Months are held newest first however they arrive, and duplicates collapse")
    func normalises() {
        let months = StatementMonths([month(2026, 8), month(2026, 9), month(2026, 8), month(2025, 12)])
        #expect(months.months == [month(2026, 9), month(2026, 8), month(2025, 12)])
        #expect(months.newest == month(2026, 9))
        #expect(months.isEmpty == false)
    }

    @Test("A gap in the record is stepped over, not through")
    func skipsEmptyMonths() {
        // Nothing was written in August.
        let months = StatementMonths([month(2026, 9), month(2026, 7), month(2026, 6)])
        #expect(months.older(than: month(2026, 9)) == month(2026, 7))
        #expect(months.newer(than: month(2026, 7)) == month(2026, 9))
    }

    @Test("There is nothing before your first month, or after your last")
    func ends() {
        let months = StatementMonths([month(2026, 9), month(2026, 7)])
        #expect(months.newer(than: month(2026, 9)) == nil)
        #expect(months.older(than: month(2026, 7)) == nil)
    }

    @Test("A month that is not in the record still knows its neighbours")
    func walkFromOutside() {
        let months = StatementMonths([month(2026, 9), month(2026, 7)])
        #expect(months.older(than: month(2026, 8)) == month(2026, 7))
        #expect(months.newer(than: month(2026, 8)) == month(2026, 9))
        #expect(months.contains(month(2026, 8)) == false)
    }

    @Test("A year boundary is a step like any other")
    func acrossAYear() {
        let months = StatementMonths([month(2026, 1), month(2025, 12)])
        #expect(months.older(than: month(2026, 1)) == month(2025, 12))
        #expect(months.newer(than: month(2025, 12)) == month(2026, 1))
        #expect(months.index(of: month(2025, 12)) == 1)
    }

    @Test("An empty record has nowhere to go")
    func empty() {
        let months = StatementMonths([])
        #expect(months.isEmpty)
        #expect(months.newest == nil)
        #expect(months.older(than: month(2026, 9)) == nil)
        #expect(months.newer(than: month(2026, 9)) == nil)
    }

    @Test("A month is read from an instant in the zone the reader is in")
    func containingAnInstant() {
        // 2026-09-01T00:30:00+10:00 — September in Melbourne, still August in UTC. The month the
        // server cuts on is the local one, so this is the one the client has to agree with.
        let melbourne = TimeZone(identifier: "Australia/Melbourne")!
        let instant = Date(timeIntervalSince1970: 1_788_186_600)
        #expect(StatementMonth(containing: instant, in: melbourne) == month(2026, 9))
        #expect(StatementMonth(containing: instant, in: TimeZone(identifier: "UTC")!) == month(2026, 8))
    }

    // MARK: - The store

    @MainActor
    @Test("The store lands on the month it was asked for and caches what it reads")
    func storeLoads() async {
        let stats = InMemoryStatsService()
        let store = StatementStore(
            month: StatementMonth(year: 2026, month: 9),
            stats: stats,
            timeZone: TimeZone(identifier: "Australia/Melbourne")!
        )
        await store.loadIfNeeded()

        #expect(store.month == month(2026, 9))
        #expect(store.statement?.orders == 9)
        #expect(store.all == [month(2026, 9), month(2026, 8)])
        #expect(store.older == month(2026, 8))
        #expect(store.newer == nil)

        await store.show(month(2026, 8))
        #expect(store.month == month(2026, 8))
        #expect(store.statement?.orders == 7)
        // September is still in hand — turning back does not re-ask.
        #expect(store.statement(for: month(2026, 9))?.orders == 9)
    }

    @MainActor
    @Test("A month with no statement is refused rather than shown blank")
    func storeRefusesAnEmptyMonth() async {
        let store = StatementStore(month: StatementMonth(year: 2026, month: 9), stats: InMemoryStatsService())
        await store.loadIfNeeded()
        await store.show(month(2026, 2))
        #expect(store.month == month(2026, 9))
    }

    @MainActor
    @Test("A statement row that outlived its month lands on one that exists")
    func storeRecovers() async {
        let store = StatementStore(month: StatementMonth(year: 2026, month: 4), stats: InMemoryStatsService())
        await store.loadIfNeeded()
        #expect(store.month == month(2026, 9))
        #expect(store.statement?.orders == 9)
    }
}
