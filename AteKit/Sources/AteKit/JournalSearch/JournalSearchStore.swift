import Foundation
import Observation

/// **The Journal's search field** — your own entries, by words, place or dish.
///
/// Debounced; under two characters nothing is asked and the field shows your recent searches
/// instead (``recents``, kept on the phone per person). Results page on the Journal's keyset. A
/// search is remembered when it is used — a result opened, or the Search key — never per keystroke.
/// Rows from the last query stay up while the next one is asked, so the list never flashes empty.
@MainActor
@Observable
public final class JournalSearchStore {
    public enum Phase: Sendable, Equatable {
        /// Under two characters: the recents show.
        case idle
        case searching
        case ready
        /// Asked, and nothing in your record matches.
        case empty
        case failed
    }

    public private(set) var query = ""
    public private(set) var results: [EntryCard] = []
    public private(set) var phase: Phase = .idle
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedEnd = false
    public let recents: RecentSearches

    @ObservationIgnored private let service: any JournalSearching
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var cursor: PageCursor?
    /// The normalised query the results answer.
    @ObservationIgnored private var answered: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var pending: Task<Void, Never>?

    private static let prefetchDistance = 5

    public init(
        service: any JournalSearching,
        recents: RecentSearches,
        analytics: @escaping AnalyticsRecorder = { _ in },
        pageSize: Int = 20,
        debounce: Duration = SearchQueryPolicy.debounce
    ) {
        self.service = service
        self.recents = recents
        self.analytics = analytics
        self.pageSize = pageSize
        self.debounce = debounce
    }

    /// The recents the Journal keeps for `owner`.
    public static func recents(owner: UUID?, defaults: UserDefaults = .standard) -> RecentSearches {
        RecentSearches(owner: owner, surface: "journal", defaults: defaults)
    }

    /// What will be sent: trimmed, at most 100 characters, `nil` under two.
    public var effectiveQuery: String? { JournalSearchQuery.normalized(query) }

    // MARK: - Inputs

    /// The magnifier opened the field.
    public func opened() {
        analytics(JournalSearchEvents.opened())
    }

    /// A keystroke. Debounced; under two characters the results clear and the recents show.
    public func setQuery(_ text: String) {
        query = text
        pending?.cancel()
        guard let next = effectiveQuery else {
            generation += 1
            reset()
            phase = .idle
            return
        }
        guard next != answered else { return }
        generation += 1
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard Task.isCancelled == false else { return }
            await self?.run()
        }
    }

    /// The Search key: asked now (no debounce) and remembered.
    public func submit() async {
        pending?.cancel()
        guard let next = effectiveQuery else { return }
        recents.record(next)
        guard next != answered else { return }
        await run()
    }

    /// A recent search tapped: it becomes the query, asked now, and moves to the top.
    public func select(_ recent: RecentSearch) async {
        query = recent.text
        await submit()
    }

    /// A result was opened: the search that found it is remembered.
    public func opened(_ card: EntryCard) {
        if let answered { recents.record(answered) }
        let position = (results.firstIndex { $0.id == card.id } ?? 0) + 1
        analytics(JournalSearchEvents.resultOpened(position: position))
    }

    /// The field was cleared or closed.
    public func cancel() {
        setQuery("")
    }

    // MARK: - Paging

    public func loadMoreIfNeeded(after card: EntryCard) async {
        guard let index = results.firstIndex(where: { $0.id == card.id }),
              index >= results.count - Self.prefetchDistance else { return }
        await loadMore()
    }

    public func loadMore() async {
        guard isLoadingMore == false, hasReachedEnd == false, let cursor, let answered else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generationAtStart = generation
        guard let page = try? await service.searchMyEntries(answered, after: cursor, limit: pageSize),
              generationAtStart == generation, answered == self.answered else { return }
        let known = Set(results.map(\.id))
        results += page.items.filter { known.contains($0.id) == false }
        self.cursor = page.nextCursor
        hasReachedEnd = page.isLastPage
    }

    /// An entry was deleted elsewhere: it leaves the results.
    public func remove(entryID: UUID) {
        results.removeAll { $0.id == entryID }
        if results.isEmpty, phase == .ready { phase = .empty }
    }

    // MARK: - Machinery

    private func run() async {
        guard let asked = effectiveQuery else { return }
        generation += 1
        let generationAtStart = generation
        if results.isEmpty { phase = .searching }
        do {
            let page = try await service.searchMyEntries(asked, after: nil, limit: pageSize)
            guard generationAtStart == generation else { return }
            results = page.items
            cursor = page.nextCursor
            hasReachedEnd = page.isLastPage
            answered = asked
            phase = results.isEmpty ? .empty : .ready
            analytics(JournalSearchEvents.searched(queryLength: asked.count, resultCount: results.count))
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            // Rows from an earlier query would read as this one's answer.
            reset()
            phase = .failed
        }
    }

    private func reset() {
        results = []
        cursor = nil
        answered = nil
        hasReachedEnd = false
    }
}
