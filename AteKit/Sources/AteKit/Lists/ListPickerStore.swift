import Foundation
import Observation

/// **"Add dishes"** — your own dishes, to put on a list: search, tick, add in the order ticked.
///
/// One row per dish: the server answers one row per (visit, dish), newest visit first, and the first
/// row seen for a dish — its latest visit, so its latest score — is the one shown. A dish already on
/// the list (any visit of it) is left out. The query is debounced; under two characters it is no
/// filter at all, the server's own rule, so the whole record shows before anything is typed.
@MainActor
@Observable
public final class ListPickerStore {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case empty
        case failed
    }

    public private(set) var query = ""
    public private(set) var rows: [ListPickerDish] = []
    public private(set) var phase: Phase = .loading
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedEnd = false
    /// Ticked, in the order ticked — the order they are appended in.
    public private(set) var selection: [ListPickerDish] = []
    /// Set when a tick would pass the list's 100-dish cap.
    public private(set) var failure: ListsError?

    @ObservationIgnored private let service: any ListsServing
    @ObservationIgnored private let listID: UUID?
    @ObservationIgnored private let scoredOnly: Bool
    @ObservationIgnored private let room: Int
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var excludedDishes: Set<UUID>
    @ObservationIgnored private var shownDishes: Set<UUID> = []
    @ObservationIgnored private var cursor: ListPickerCursor?
    /// The effective query the rows answer (`nil` = no filter), once they answer one.
    @ObservationIgnored private var answered: String??
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var pending: Task<Void, Never>?

    private static let prefetchDistance = 6
    /// How many pages a first read may walk past rows that are all already on the list.
    private static let fillPages = 4

    /// - Parameters:
    ///   - listID: fills `in_list` on the server.
    ///   - excluding: the list's lines as the page has them — their dishes are left out too.
    ///   - room: how many more dishes the list can take (``ListStore/remaining``).
    ///   - scoredOnly: `false` shows unscored dishes too, with their empty star.
    public init(
        service: any ListsServing,
        listID: UUID?,
        excluding: Set<DishLine> = [],
        room: Int = ListRules.itemCap,
        scoredOnly: Bool = false,
        pageSize: Int = 30,
        debounce: Duration = SearchQueryPolicy.debounce
    ) {
        self.service = service
        self.listID = listID
        self.excludedDishes = Set(excluding.map(\.dishID))
        self.room = max(0, room)
        self.scoredOnly = scoredOnly
        self.pageSize = pageSize
        self.debounce = debounce
    }

    /// The query the server will be sent: trimmed, at most 100 characters, `nil` under two.
    public var effectiveQuery: String? { ListRules.query(query) }

    public func isSelected(_ dish: ListPickerDish) -> Bool {
        selection.contains { $0.dishID == dish.dishID }
    }

    public var canSelectMore: Bool { selection.count < room }

    // MARK: - Inputs

    /// The sheet appeared: the first page, if it is not already showing.
    public func start() async {
        guard answered != .some(effectiveQuery) else { return }
        await run()
    }

    /// A keystroke. Debounced; a change that does not move the effective query asks nothing.
    public func setQuery(_ text: String) {
        query = text
        pending?.cancel()
        guard answered != .some(effectiveQuery) else { return }
        generation += 1
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard Task.isCancelled == false else { return }
            await self?.run()
        }
    }

    /// A tap: ticks or unticks. Past the list's room it refuses with `itemCap` and returns `false`.
    @discardableResult
    public func toggle(_ dish: ListPickerDish) -> Bool {
        if let index = selection.firstIndex(where: { $0.dishID == dish.dishID }) {
            selection.remove(at: index)
            return true
        }
        guard canSelectMore else {
            failure = .itemCap
            return false
        }
        selection.append(dish)
        return true
    }

    public func clearFailure() { failure = nil }

    // MARK: - Paging

    public func loadMoreIfNeeded(after dish: ListPickerDish) async {
        guard let index = rows.firstIndex(where: { $0.dishID == dish.dishID }),
              index >= rows.count - Self.prefetchDistance else { return }
        await loadMore()
    }

    public func loadMore() async {
        guard isLoadingMore == false, hasReachedEnd == false, let cursor, answered != nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generationAtStart = generation
        guard let page = try? await fetch(after: cursor), generationAtStart == generation else { return }
        take(page)
    }

    // MARK: - Machinery

    private func run() async {
        generation += 1
        let generationAtStart = generation
        let asked = effectiveQuery
        if rows.isEmpty { phase = .loading }
        do {
            var page = try await fetch(after: nil)
            guard generationAtStart == generation else { return }
            rows = []
            shownDishes = []
            take(page)
            // A page that was all already-listed dishes still has a next one to show.
            var walked = 1
            while rows.count < pageSize / 2, let next = cursor, walked < Self.fillPages {
                page = try await fetch(after: next)
                guard generationAtStart == generation else { return }
                take(page)
                walked += 1
            }
            answered = .some(asked)
            phase = rows.isEmpty ? .empty : .ready
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            if rows.isEmpty { phase = .failed }
        }
    }

    private func fetch(after cursor: ListPickerCursor?) async throws -> ListPickerPage {
        try await service.myDishLines(
            query: effectiveQuery, scoredOnly: scoredOnly, listID: listID, after: cursor, limit: pageSize
        )
    }

    private func take(_ page: ListPickerPage) {
        for row in page.items where row.inList {
            excludedDishes.insert(row.dishID)
        }
        rows.removeAll { excludedDishes.contains($0.dishID) }
        for row in page.items where excludedDishes.contains(row.dishID) == false {
            guard shownDishes.insert(row.dishID).inserted else { continue }
            rows.append(row)
        }
        cursor = page.nextCursor
        hasReachedEnd = page.nextCursor == nil
    }
}
