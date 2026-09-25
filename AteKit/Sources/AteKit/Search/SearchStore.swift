import Foundation
import Observation

/// **The Search tab, as state.** One query, four scopes, one debounce, one page at a time.
///
/// It is here rather than in the view for the three things that are genuinely hard and genuinely
/// invisible: that a keystroke does not fire a request until the typing stops, that a result which
/// arrives after the query moved on is dropped rather than drawn, and that switching scopes does not
/// throw away a page that was already paid for.
///
/// **Per-scope state is kept.** Tapping Dishes and then Places again shows the places that were
/// already there, instantly, and re-reads nothing: the segments are four views of one query, not
/// four screens. A new query invalidates all four at once, because they are all answers to it.
@MainActor
@Observable
public final class SearchStore {

    public enum Phase: Sendable, Equatable {
        /// Nothing has been asked yet. The field is the whole screen (design rule 1).
        case idle
        case loading
        case ready
        /// A query long enough to run, that found nothing.
        case empty
        case failed(message: String)
    }

    // MARK: - What the screen reads

    public private(set) var scope: SearchScope
    public private(set) var rows: SearchRows
    public private(set) var phase: Phase = .idle
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedEnd = false

    /// What is in the field. Setting it schedules a search; it never searches on the keystroke.
    public var query: String {
        didSet {
            guard query != oldValue else { return }
            schedule()
        }
    }

    /// True while the Places scope is showing the standing `Nearby` list rather than a search —
    /// the one section label the artboard draws.
    public private(set) var isShowingNearby = false

    /// Whether what is in the field is long enough to be a search in this scope. Below it, the scope
    /// shows its standing list or nothing — and an empty shelf is "nothing saved", not "nothing found".
    public var isSearching: Bool { isBelowMinimumLength == false }

    // MARK: - Machinery

    private let service: any SearchReading
    private let analytics: AnalyticsRecorder
    private let pageSize: Int
    private let debounce: Duration

    /// Where the phone is, if it ever said. `nil` is not an error: it is a `Nearby` list that simply
    /// is not there (design rule 8 — a location ranks a list, it never attaches a place).
    private var origin: SearchOrigin?

    private struct ScopeState {
        var rows: SearchRows
        var phase: Phase = .idle
        var query = ""
        var next: SearchCursor?
        var hasReachedEnd = false
        var isNearby = false
        /// Whether this scope has ever answered the query it is holding.
        var isLoaded = false
    }

    private var states: [SearchScope: ScopeState] = [:]
    private var pending: Task<Void, Never>?
    /// Bumped on every query or scope change; a page that arrives with a stale generation is dropped.
    private var generation = 0

    private static let prefetchDistance = 6

    public init(
        service: any SearchReading,
        scope: SearchScope = .places,
        query: String = "",
        pageSize: Int = SearchClient.defaultPageSize,
        debounce: Duration = SearchQueryPolicy.debounce,
        analytics: @escaping AnalyticsRecorder = { _ in },
        savedDishes: SavedDishBroadcast? = nil
    ) {
        self.service = service
        self.scope = scope
        self.query = query
        self.pageSize = pageSize
        self.debounce = debounce
        self.analytics = analytics
        self.rows = .empty(for: scope)
        // A save made anywhere — a dish page pushed from these very results — is true here too.
        savedDishes?.add(self)
    }

    // MARK: - The three inputs

    /// The screen opened, or came back. Loads whatever the current scope owes.
    public func start() async {
        await runIfNeeded()
    }

    /// A segment was tapped. No debounce: a tap is not a keystroke, and the answer is owed now.
    public func select(_ scope: SearchScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        adopt(states[scope] ?? ScopeState(rows: .empty(for: scope)))
        pending?.cancel()
        pending = Task { [weak self] in await self?.runIfNeeded() }
    }

    /// Where the phone is — handed in by the screen, which is the only layer allowed to ask.
    /// Arriving late is normal (the permission sheet takes as long as it takes), so it loads Nearby
    /// itself if that is what is on screen.
    public func setOrigin(_ origin: SearchOrigin?) async {
        guard let origin, origin != self.origin else { return }
        self.origin = origin
        guard scope == .places, isBelowMinimumLength else { return }
        await run()
    }

    // MARK: - Paging

    /// The row at `index` came on screen. Six from the end, the next page is asked for.
    public func loadMoreIfNeeded(index: Int) async {
        guard index >= rows.count - Self.prefetchDistance else { return }
        await loadMore()
    }

    public func loadMore() async {
        guard isLoadingMore == false, hasReachedEnd == false else { return }
        guard var state = states[scope], state.isLoaded else { return }
        guard let cursor = state.next else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }
        let generationAtStart = generation
        do {
            // The query the first page was asked with — `nil` for a standing list (Nearby, the whole
            // shelf), exactly as `run()` decided it.
            let typed = SearchQueryPolicy(scope: scope).query(from: state.query)
            let more = try await page(for: scope, query: typed, after: cursor)
            guard generationAtStart == generation else { return }
            state = states[scope] ?? state
            state.rows = SearchStore.appending(more.rows, to: state.rows)
            state.next = more.next
            state.hasReachedEnd = more.next == nil
            states[scope] = state
            adopt(state)
        } catch {
            // A failed second page leaves the first one standing. The list is still true.
        }
    }

    // MARK: - The shelf, from here

    /// The bookmark on a Saved row. The row leaves at the tap, like it does on the shelf, and comes
    /// back where it was if the unsave is refused. `perform` is the shared ``SaveAction``'s own
    /// unsave, so the round trip, the haptic and `save_toggled` are the shelf's, not a copy of them.
    public func unsave(_ dish: SavedDish, perform: () async -> Bool) async {
        let removed = removeSaved(dish.dishID)
        guard await perform() == false, let removed else { return }
        restoreSaved(removed.dish, at: removed.index)
    }

    @discardableResult
    private func removeSaved(_ dishID: UUID) -> (dish: SavedDish, index: Int)? {
        guard var state = states[.saved], case .saved(var dishes) = state.rows,
              let index = dishes.firstIndex(where: { $0.dishID == dishID }) else { return nil }
        let dish = dishes.remove(at: index)
        state.rows = .saved(dishes)
        if dishes.isEmpty, state.phase == .ready { state.phase = .empty }
        states[.saved] = state
        if scope == .saved { adopt(state) }
        return (dish, index)
    }

    private func restoreSaved(_ dish: SavedDish, at index: Int) {
        guard var state = states[.saved], case .saved(var dishes) = state.rows,
              dishes.contains(where: { $0.dishID == dish.dishID }) == false else { return }
        dishes.insert(dish, at: min(index, dishes.count))
        state.rows = .saved(dishes)
        state.phase = .ready
        states[.saved] = state
        if scope == .saved { adopt(state) }
    }

    // MARK: - Running a query

    private var isBelowMinimumLength: Bool {
        SearchQueryPolicy(scope: scope).query(from: query) == nil
    }

    private func schedule() {
        pending?.cancel()
        generation += 1
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard Task.isCancelled == false else { return }
            await self?.run()
        }
    }

    /// Runs only when this scope is not already holding the answer to this query.
    private func runIfNeeded() async {
        let normalized = SearchQueryPolicy(scope: scope).normalize(query)
        if let state = states[scope], state.isLoaded, state.query == normalized { return }
        await run()
    }

    private func run() async {
        let policy = SearchQueryPolicy(scope: scope)
        let normalized = policy.normalize(query)
        let scope = scope
        generation += 1
        let generationAtStart = generation

        // Below the minimum: the standing list, or nothing at all. Never a flash of empty.
        let typed = policy.query(from: query)
        if typed == nil, scope.hasStandingList == false {
            var state = ScopeState(rows: .empty(for: scope))
            state.query = normalized
            state.isLoaded = true
            state.phase = .idle
            states[scope] = state
            adopt(state)
            return
        }

        var state = states[scope] ?? ScopeState(rows: .empty(for: scope))
        state.query = normalized
        state.isNearby = typed == nil && scope == .places
        // A first load draws skeletons; a re-query keeps the rows that are up while the next set
        // comes down, so the list does not blink between two answers.
        state.phase = state.rows.isEmpty ? .loading : state.phase
        states[scope] = state
        adopt(state)

        let started = ContinuousClock.now
        do {
            let first = try await page(for: scope, query: typed, after: nil)
            guard generationAtStart == generation else { return }
            state.rows = first.rows
            state.next = first.next
            state.hasReachedEnd = first.next == nil
            state.isLoaded = true
            state.phase = first.rows.isEmpty ? .empty : .ready
            states[scope] = state
            adopt(state)
            report(scope: scope, query: normalized, resultCount: first.rows.count, since: started)
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            state.rows = .empty(for: scope)
            state.isLoaded = true
            state.phase = .failed(message: SearchStore.failureMessage(error))
            states[scope] = state
            adopt(state)
        }
    }

    /// One page, whichever scope asked for it. A `nil` query is the standing list: Nearby for
    /// Places, the whole shelf for Saved, and nothing at all for the other two.
    private func page(for scope: SearchScope, query: String?, after cursor: SearchCursor?) async throws -> LoadedPage {
        switch (scope, query) {
        case (.places, let query?):
            let page = try await service.places(query: query, after: cursor, pageSize: pageSize)
            return LoadedPage(rows: .places(page.rows), next: page.next)
        case (.places, nil):
            // No permission, no location, no section — and no copy about it.
            guard let origin else { return LoadedPage(rows: .places([])) }
            let page = try await service.nearbyPlaces(origin: origin, after: cursor, pageSize: pageSize)
            return LoadedPage(rows: .places(page.rows), next: page.next)
        case (.dishes, let query?):
            let page = try await service.dishes(query: query, after: cursor, pageSize: pageSize)
            return LoadedPage(rows: .dishes(page.rows), next: page.next)
        case (.people, let query?):
            let page = try await service.people(query: query, after: cursor, pageSize: pageSize)
            return LoadedPage(rows: .people(page.rows), next: page.next)
        case (.saved, let query):
            let page = try await service.savedDishes(matching: query, after: cursor, pageSize: pageSize)
            return LoadedPage(rows: .saved(page.rows), next: page.next)
        case (.dishes, nil), (.people, nil):
            return LoadedPage(rows: .empty(for: scope))
        }
    }

    private struct LoadedPage {
        var rows: SearchRows
        var next: SearchCursor?
    }

    // MARK: - Telemetry

    private func report(scope: SearchScope, query: String, resultCount: Int, since started: ContinuousClock.Instant) {
        // The standing lists are not searches: nobody typed anything, so counting them would put a
        // zero-length query in the middle of the funnel's length distribution.
        guard query.isEmpty == false else { return }
        let elapsed = ContinuousClock.now - started
        analytics(SearchEvents.searchPerformed(
            scope: scope,
            queryLength: query.count,
            resultCount: resultCount,
            milliseconds: Int(
                elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            )
        ))
    }

    /// A row was opened. Called by the screen at the tap, because the tap is the intent.
    public func reportOpened() {
        analytics(SearchEvents.searchResultOpened(scope: scope))
    }

    // MARK: - Small machinery

    private func adopt(_ state: ScopeState) {
        rows = state.rows
        phase = state.phase
        hasReachedEnd = state.hasReachedEnd
        isShowingNearby = state.isNearby && state.rows.isEmpty == false
    }

    /// Appends a page, dropping anything already on screen — two windows onto one ranked list
    /// overlap by construction (`search_all` has no offset), and a duplicated row is a row a tap
    /// cannot identify.
    static func appending(_ page: SearchRows, to existing: SearchRows) -> SearchRows {
        switch (existing, page) {
        case (.places(let old), .places(let new)):
            var seen = Set(old.map(\.id))
            return .places(old + new.filter { seen.insert($0.id).inserted })
        case (.dishes(let old), .dishes(let new)):
            var seen = Set(old.map(\.dishID))
            return .dishes(old + new.filter { seen.insert($0.dishID).inserted })
        case (.people(let old), .people(let new)):
            var seen = Set(old.map(\.userID))
            return .people(old + new.filter { seen.insert($0.userID).inserted })
        case (.saved(let old), .saved(let new)):
            var seen = Set(old.map(\.dishID))
            return .saved(old + new.filter { seen.insert($0.dishID).inserted })
        default:
            return page
        }
    }

    static func failureMessage(_ error: any Error) -> String {
        (error as? AteAPIError) == .notAuthenticated ? "Nobody's\nsigned in." : "Couldn't\nsearch."
    }

    /// Test seam: waits for the scheduled search to finish, so a debounce can be asserted rather
    /// than slept through.
    func settle() async {
        await pending?.value
    }
}

extension SearchStore: SavedDishObserving {
    /// An unsave anywhere takes the dish off this shelf too. A save anywhere makes the shelf stale
    /// rather than guessing where the new row sorts: it is read again the next time it is shown.
    public func savedDishChanged(dishID: UUID, isSaved: Bool) {
        if isSaved {
            states[.saved]?.isLoaded = false
        } else {
            removeSaved(dishID)
        }
    }
}
