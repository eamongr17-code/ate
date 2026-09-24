import Foundation
import Observation

/// **The statements**, and turning from one to the next.
///
/// It holds the months that *exist* (`statement_months`) and a cache of the ones that have been
/// read, so turning back to September after looking at August is instant and does not re-ask. The
/// walk is over months with something in them — September → July if nothing was written in
/// August — because a receipt is only printed where something was printed (design rule 4), and an
/// empty statement is a page that should never exist.
@MainActor
@Observable
public final class StatementStore {

    /// The month on screen.
    public private(set) var month: StatementMonth
    public private(set) var months = StatementMonths([])
    public private(set) var isLoading = true

    private var cache: [String: MonthlyStatement] = [:]
    private let stats: any StatsReading
    private let timeZone: TimeZone
    private var viewer: UUID?
    private var hasLoadedMonths = false

    public init(month: StatementMonth, stats: any StatsReading, timeZone: TimeZone = .current) {
        self.month = month
        self.stats = stats
        self.timeZone = timeZone
    }

    /// The statement on screen, once it has landed.
    public var statement: MonthlyStatement? { cache[month.key] }

    /// What a page turn can reach. `nil` at either end — there is no month before your first.
    public var older: StatementMonth? { months.older(than: month) }
    public var newer: StatementMonth? { months.newer(than: month) }

    /// Every month, newest first — what a pager lays out.
    public var all: [StatementMonth] { months.months }

    public func loadIfNeeded() async {
        guard hasLoadedMonths == false else { return }
        await loadMonths()
        await loadStatement(month)
    }

    /// Turn to a month. Silently refuses one that has no statement.
    public func show(_ next: StatementMonth) async {
        guard next != month else { return }
        guard months.isEmpty || months.contains(next) else { return }
        month = next
        await loadStatement(next)
    }

    public func statement(for month: StatementMonth) -> MonthlyStatement? { cache[month.key] }

    /// Reads one month ahead of the finger, so a page turn lands on a printed receipt rather than
    /// on blank paper. Cheap: it is a cache hit for anything already read.
    public func prepare(_ month: StatementMonth) async {
        await loadStatement(month)
    }

    private func loadMonths() async {
        guard let viewer = await viewerID() else {
            isLoading = false
            return
        }
        if let summaries = try? await stats.allMonths(userID: viewer, timeZone: timeZone) {
            months = StatementMonths(summaries: summaries)
            hasLoadedMonths = true
            // A statement row can outlive its month (the tab was open while the last entry was
            // deleted). Land on a month that exists rather than on an empty page.
            if months.isEmpty == false, months.contains(month) == false,
               let newest = months.newest {
                month = newest
            }
        }
    }

    private func loadStatement(_ wanted: StatementMonth) async {
        guard cache[wanted.key] == nil else {
            if wanted == month { isLoading = false }
            return
        }
        guard let viewer = await viewerID() else {
            isLoading = false
            return
        }
        if wanted == month { isLoading = true }
        if let statement = try? await stats.statement(
            userID: viewer, month: wanted, timeZone: timeZone
        ) {
            cache[wanted.key] = statement
        }
        if wanted == month { isLoading = false }
    }

    private func viewerID() async -> UUID? {
        if let viewer { return viewer }
        viewer = try? await stats.viewerID()
        return viewer
    }
}
