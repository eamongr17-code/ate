import Foundation
import Observation

/// One day's worth of entries, with the heading the design prints above them ("Sat 19 Sep").
public struct JournalDay: Identifiable, Sendable, Hashable {
    /// The start of the day, in the reader's own calendar.
    public let id: Date
    public let title: String
    public let entries: [EntryCard]
}

/// **The journal**: your entries, newest first, keyset-paged, grouped by day.
///
/// The paging rules are the ones every list in this app follows — a composite `(created_at, id)`
/// cursor, dedup on arrival, a generation counter so a slow page cannot append itself onto a fresher
/// list. What is particular to the journal is that it must *become stale the moment you write*: a
/// list of your own entries that does not contain the one you just wrote is a bug, not a cache miss.
@MainActor
@Observable
public final class JournalStore {

    /// What the screen shows instead of entries.
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        /// Loaded, and you have not written anything. An invitation, not an error.
        case empty
        /// No session. RLS hands `anon` a successful empty page, so without this the signed-out
        /// reader would be told *they* had written nothing — a claim about a person we cannot name.
        case signedOut
        case failed(message: String)
    }

    public private(set) var entries: [EntryCard] = []
    public private(set) var days: [JournalDay] = []
    public private(set) var phase: Phase = .loading
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedEnd = false
    /// A page failed while content was already on screen. Shown inline, never as an alert.
    public private(set) var inlineErrorMessage: String?

    private let entryService: any EntryService
    private let pageSize: Int
    private let calendar: Calendar
    private var nextCursor: PageCursor?
    private var seenIDs: Set<UUID> = []
    private var hasLoadedOnce = false
    private var needsRefresh = false
    private var generation = 0
    private var isLoadingFirstPage = false

    /// How close to the end a row must be before the next page is asked for.
    private static let prefetchDistance = 5

    public init(
        entries: any EntryService,
        pageSize: Int = 30,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.entryService = entries
        self.pageSize = pageSize
        self.calendar = calendar
    }

    // MARK: - Loading

    public func loadIfNeeded() async {
        guard hasLoadedOnce == false || needsRefresh else { return }
        await loadFirstPage()
    }

    /// Pull to refresh. Existing entries stay on screen until the new first page arrives, so a
    /// refresh never flashes an empty list.
    public func refresh() async {
        await loadFirstPage()
    }

    /// Something happened that the loaded list cannot reflect — you wrote, or a session appeared.
    public func invalidate() {
        needsRefresh = true
    }

    public func loadMoreIfNeeded(after entry: EntryCard) async {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        guard index >= entries.count - Self.prefetchDistance else { return }
        await loadMore()
    }

    public func loadMore() async {
        guard isLoadingMore == false, isLoadingFirstPage == false,
              hasReachedEnd == false, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let generationAtStart = generation
        do {
            let page = try await entryService.journal(after: cursor, pageSize: pageSize)
            guard generationAtStart == generation else { return }
            append(page)
            inlineErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            inlineErrorMessage = Self.message(for: error)
        }
    }

    private func loadFirstPage() async {
        guard isLoadingFirstPage == false else { return }
        isLoadingFirstPage = true
        generation += 1
        let generationAtStart = generation
        defer { isLoadingFirstPage = false }

        if entries.isEmpty { phase = .loading }

        do {
            let page = try await entryService.journal(after: nil, pageSize: pageSize)
            guard generationAtStart == generation else { return }
            hasLoadedOnce = true
            needsRefresh = false
            reset()
            append(page)
            phase = entries.isEmpty ? .empty : .ready
            inlineErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            hasLoadedOnce = true
            if entries.isEmpty {
                phase = Self.isNotAuthenticated(error)
                    ? .signedOut
                    : .failed(message: Self.message(for: error))
            } else if Self.isNotAuthenticated(error) {
                reset()
                phase = .signedOut
            } else {
                inlineErrorMessage = Self.message(for: error)
            }
        }
    }

    // MARK: - Local changes

    /// Puts an entry on the page the moment it is written, before any read confirms it.
    ///
    /// This is what "your words are saved instantly" looks like on the journal: the entry is there,
    /// with its words, whether or not the sorter — or the network — has caught up.
    public func insert(_ card: EntryCard) {
        guard phase != .signedOut else { return }
        if let index = entries.firstIndex(where: { $0.id == card.id }) {
            entries[index] = card
        } else {
            guard seenIDs.insert(card.id).inserted else { return }
            entries.insert(card, at: 0)
        }
        phase = .ready
        regroup()
    }

    /// Replaces one entry in place — the receipt arriving, a correction landing, visibility flipping.
    public func replace(_ card: EntryCard) {
        guard let index = entries.firstIndex(where: { $0.id == card.id }) else { return }
        entries[index] = card
        regroup()
    }

    public func entry(id: UUID) -> EntryCard? {
        entries.first { $0.id == id }
    }

    // MARK: - Machinery

    private func reset() {
        entries = []
        seenIDs = []
        nextCursor = nil
        hasReachedEnd = false
        regroup()
    }

    private func append(_ page: Page<EntryCard>) {
        let fresh = page.items.filter { seenIDs.insert($0.id).inserted }
        entries.append(contentsOf: fresh)
        nextCursor = page.nextCursor
        hasReachedEnd = page.isLastPage
        regroup()
    }

    /// The one place `entries` is read back into shape. Every mutation ends here, so a day split
    /// across a page boundary regroups when the next page lands rather than staying split forever.
    private func regroup() {
        days = JournalGrouping.days(from: entries, calendar: calendar)
    }

    static func isNotAuthenticated(_ error: any Error) -> Bool {
        (error as? AteAPIError) == .notAuthenticated
    }

    /// One short sentence in the journal's own voice. Never the raw error: a PostgREST body is noise
    /// to the reader and Sentry already has it.
    static func message(for error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "You're offline."
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "Couldn't reach Ate."
            default:
                return "Couldn't load your journal."
            }
        }
        if isNotAuthenticated(error) { return "Sign in to see your journal." }
        return "Couldn't load your journal."
    }
}

/// Grouping entries into the day headings the design prints. Pure, so the boundary cases — midnight,
/// a timezone change, an entry backdated by an offline write — are testable without a store.
public enum JournalGrouping {
    /// "Sat 19 Sep". The ORDER is the design's and is fixed; the weekday and month names come from
    /// the reader's locale.
    public static let dayFormat = Date.VerbatimFormatStyle(
        format: "\(weekday: .abbreviated) \(day: .defaultDigits) \(month: .abbreviated)",
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent,
        calendar: .autoupdatingCurrent
    )

    public static func days(from entries: [EntryCard], calendar: Calendar = .autoupdatingCurrent) -> [JournalDay] {
        var order: [Date] = []
        var grouped: [Date: [EntryCard]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(entry)
        }
        return order.map { day in
            JournalDay(id: day, title: day.formatted(dayFormat), entries: grouped[day] ?? [])
        }
    }
}
