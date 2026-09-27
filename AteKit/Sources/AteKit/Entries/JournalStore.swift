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
public final class JournalStore: EntryDeletionObserving {

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
    /// The order and filters the list is showing (round 4). The default is the journal itself and
    /// reads the plain journal path; anything else reads `my_entries`.
    public private(set) var query = JournalQuery()
    /// The place filter's choices, once asked for (``loadPlaces()``).
    public private(set) var places: [JournalPlace] = []
    /// Whether the place list has answered once — none is an answer too (round 5: read ahead, so the
    /// filter sheet opens full).
    public private(set) var hasLoadedPlaces = false
    private var placesFailed = false
    @ObservationIgnored private var placesRead: Task<Void, Never>?

    private let entryService: any EntryService
    private let querying: (any JournalQuerying)?
    private let pageSize: Int
    private let calendar: Calendar
    private var nextCursor: JournalCursor?
    /// Entries written while a filter was up, kept at the top of the journal read that replaces it.
    private var pinned: [EntryCard] = []
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
        calendar: Calendar = .autoupdatingCurrent,
        deletions: EntryDeletions? = nil,
        querying: (any JournalQuerying)? = nil
    ) {
        self.entryService = entries
        self.querying = querying
        cityList = AteCityList { try await querying?.myEntryCities() ?? [] }
        self.pageSize = pageSize
        self.calendar = calendar
        // An entry deleted anywhere leaves the journal in the same turn.
        deletions?.add(self)
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
            let page = try await fetch(after: cursor)
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
        // Only the load that is still current may say loading is over: a superseded one finishing
        // late must not clear the flag under the load that replaced it.
        defer { if generationAtStart == generation { isLoadingFirstPage = false } }

        if entries.isEmpty { phase = .loading }

        do {
            let page = try await fetch(after: nil)
            guard generationAtStart == generation else { return }
            hasLoadedOnce = true
            needsRefresh = false
            reset()
            append(page)
            keepPinned()
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
        // Writing lands on the journal itself: a filter that would hide the new entry — or an order
        // that would bury it — is put down, and the whole first page read again behind it.
        if query.isDefault == false {
            query = JournalQuery()
            reset()
            needsRefresh = true
            // The filtered page still in flight is superseded, exactly as `apply` does it — so it
            // cannot land over the journal and wipe the entry just written (QA a).
            generation += 1
            isLoadingFirstPage = false
            // …and the entry stays on top of the page read behind it, landed on the server or not.
            pinned.append(card)
            Task { await loadFirstPage() }
        }
        // A place the filter has never offered: its list is asked for again (QA b).
        // The old list stands until the new one lands, so an open sheet never empties under the thumb.
        if let place = card.place, hasLoadedPlaces, places.contains(where: { $0.id == place.id }) == false {
            hasLoadedPlaces = false
            Task { await loadPlaces() }
        }
        // The same for a city (round 5): an entry in a city the filter has never offered.
        if let slug = AteCity.slug(for: card.place?.city), cityList.hasLoaded,
           cityList.cities.contains(where: { $0.city == slug }) == false {
            Task { await cityList.load() }
        }
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

    /// An entry was deleted. It leaves the page now, keeps its id in `seenIDs` so a page read
    /// before the delete landed cannot put it back, and an emptied journal is the first-day one.
    public func remove(entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries.remove(at: index)
        if entries.isEmpty, phase == .ready { phase = .empty }
        regroup()
    }

    public func entryDeleted(_ entryID: UUID) {
        remove(entryID: entryID)
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

    private func append(_ page: JournalQueryPage) {
        let fresh = page.items.filter { seenIDs.insert($0.id).inserted }
        entries.append(contentsOf: fresh)
        nextCursor = page.nextCursor
        hasReachedEnd = page.nextCursor == nil
        regroup()
    }

    /// One page of whatever the list is showing: the plain journal for the default query, and
    /// `my_entries` for anything else.
    private func fetch(after cursor: JournalCursor?) async throws -> JournalQueryPage {
        guard query.isDefault == false, let querying else {
            let page = try await entryService.journal(after: cursor?.pageCursor, pageSize: pageSize)
            return JournalQueryPage(items: page.items, nextCursor: page.nextCursor.map {
                JournalCursor(createdAt: $0.createdAt, id: $0.id)
            })
        }
        return try await querying.myEntries(query, after: cursor, pageSize: pageSize)
    }

    /// The pinned entries the page did not bring back go on top, newest first; then they are done.
    private func keepPinned() {
        let missing = pinned.filter { seenIDs.insert($0.id).inserted }
        entries.insert(contentsOf: missing.sorted { $0.createdAt > $1.createdAt }, at: 0)
        pinned = []
        regroup()
    }

    // MARK: - Filter and sort (round 4)

    /// Shows the journal in another order, or filtered. The list is cleared to its skeleton and read
    /// again from the top — a filtered list is a different list, not a subset of the loaded one.
    public func apply(_ query: JournalQuery) async {
        guard query != self.query, querying != nil || query.isDefault else { return }
        self.query = query
        reset()
        phase = .loading
        inlineErrorMessage = nil
        // A page still arriving for the last query is superseded, not waited for: its generation
        // no longer matches, so whatever it brings is dropped.
        generation += 1
        isLoadingFirstPage = false
        await loadFirstPage()
    }

    /// The cities the filter offers (`my_entry_cities`), read ahead so the sheet rises full.
    @ObservationIgnored public let cityList: AteCityList
    public var cities: [AteCity] { cityList.cities }
    public var hasLoadedCities: Bool { cityList.hasLoaded }
    public func loadCities() async { await cityList.load() }
    public func loadCitiesIfNeeded() async { await cityList.loadIfNeeded() }

    /// The places the place filter offers — asked for once, when the filter is first opened.
    ///
    /// A read already on its way is joined, not repeated, so a sheet waiting on this waits for the
    /// places to actually land.
    public func loadPlaces() async {
        if let placesRead {
            await placesRead.value
            return
        }
        guard hasLoadedPlaces == false || placesFailed else { return }
        guard let querying else {
            hasLoadedPlaces = true
            return
        }
        let read = Task {
            // A failure is an answer for the sheet that is up (no still rows left standing), and
            // the next open asks again.
            let loaded = try? await querying.myEntryPlaces()
            placesFailed = loaded == nil
            if let loaded { places = loaded }
            hasLoadedPlaces = true
        }
        placesRead = read
        await read.value
        placesRead = nil
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
