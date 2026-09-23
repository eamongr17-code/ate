import Foundation
import Observation

/// **A keyset-paged list of entries** — the feed, and a profile's entries.
///
/// The rules are the ones every list in this app follows and the journal already proved: a composite
/// `(created_at, id)` cursor, dedup on arrival, and a generation counter so a slow page cannot append
/// itself onto a fresher list. What is new here is that the rows belong to *other people*, so two
/// things the journal never has to do happen here:
///
/// - **a save is optimistic** — the bookmark flips before the RPC answers, and is put back if it
///   refuses, because a save is one tap on a moving list and a round trip is a visible stutter;
/// - **a block empties the list of that person immediately** — the server has already removed them
///   from every read, and the refetch that follows must not be the first time the reader sees it.
///
/// The loader is a closure rather than a protocol so the feed and a profile share one implementation
/// (they differ only in which RPC they call) and so a test can drive paging with no network at all.
@MainActor
@Observable
public final class EntryListStore {

    /// What the screen shows instead of entries.
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        /// Loaded, and there is nothing. An honest state, not an error.
        case empty
        /// No session. RLS hands `anon` a successful empty page, so without this "signed out" and
        /// "nobody has written anything" would be the same screen.
        case signedOut
        case failed(message: String)
    }

    /// One page, from wherever this list comes from.
    public typealias Loader = @Sendable (PageCursor?, Int) async throws -> Page<EntryCard>

    public private(set) var entries: [EntryCard] = []
    public private(set) var phase: Phase = .loading
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedEnd = false
    /// A page failed while rows were already on screen. Shown inline, never as an alert.
    public private(set) var inlineErrorMessage: String?

    private let loader: Loader
    private let fallbackMessage: String
    private let pageSize: Int
    private var nextCursor: PageCursor?
    private var seenIDs: Set<UUID> = []
    private var hasLoadedOnce = false
    private var generation = 0
    private var isLoadingFirstPage = false
    /// 1-based, and reset by a refresh — what `feed_page_loaded` reports.
    public private(set) var pagesLoaded = 0
    /// Called as each page lands, with `(page, itemsNowLoaded)`.
    ///
    /// A closure rather than something a view watches: a refresh sets the count back to zero and
    /// straight to one in the same turn, and an observer would see no change at all and report
    /// nothing. The event belongs where the page actually arrives.
    public var onPageLoaded: (@MainActor (Int, Int) -> Void)?

    /// How close to the end a row must be before the next page is asked for.
    private static let prefetchDistance = 4

    public init(pageSize: Int = 20, fallbackMessage: String, loader: @escaping Loader) {
        self.pageSize = pageSize
        self.fallbackMessage = fallbackMessage
        self.loader = loader
    }

    // MARK: - Loading

    public func loadIfNeeded() async {
        guard hasLoadedOnce == false else { return }
        await loadFirstPage()
    }

    /// Pull to refresh, and what a block does to every open list. Existing rows stay on screen until
    /// the new first page arrives, so a refresh never flashes empty.
    public func refresh() async {
        await loadFirstPage()
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
            let page = try await loader(cursor, pageSize)
            guard generationAtStart == generation else { return }
            append(page)
            inlineErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            inlineErrorMessage = message(for: error)
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
            let page = try await loader(nil, pageSize)
            guard generationAtStart == generation else { return }
            hasLoadedOnce = true
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
                    : .failed(message: message(for: error))
            } else if Self.isNotAuthenticated(error) {
                reset()
                phase = .signedOut
            } else {
                inlineErrorMessage = message(for: error)
            }
        }
    }

    // MARK: - Local changes

    /// Flips the bookmark on every line of this dish, wherever it appears in the list — the same
    /// dish saved from one entry is saved on every other entry that serves it, and a list that
    /// disagreed with itself would read as a bug.
    public func setSaved(dishID: UUID, to isSaved: Bool) {
        entries = entries.map { $0.settingSaved(dishID: dishID, to: isSaved) }
    }

    /// Someone was blocked: they are gone from the server's reads already, and they go from this
    /// list now rather than after a round trip.
    public func removeAuthor(_ authorID: UUID) {
        entries.removeAll { $0.authorID == authorID }
        seenIDs = Set(entries.map(\.id))
        if entries.isEmpty, phase == .ready { phase = .empty }
    }

    public func entry(id: UUID) -> EntryCard? {
        entries.first { $0.id == id }
    }

    /// One row replaced in place — an entry reloaded after it was opened, so a save made on its page
    /// is already true when the reader comes back to the list.
    public func replace(_ card: EntryCard) {
        guard let index = entries.firstIndex(where: { $0.id == card.id }) else { return }
        entries[index] = card
    }

    // MARK: - Machinery

    private func reset() {
        entries = []
        seenIDs = []
        nextCursor = nil
        hasReachedEnd = false
        pagesLoaded = 0
    }

    private func append(_ page: Page<EntryCard>) {
        let fresh = page.items.filter { seenIDs.insert($0.id).inserted }
        entries.append(contentsOf: fresh)
        nextCursor = page.nextCursor
        hasReachedEnd = page.isLastPage
        pagesLoaded += 1
        onPageLoaded?(pagesLoaded, entries.count)
    }

    static func isNotAuthenticated(_ error: any Error) -> Bool {
        (error as? AteAPIError) == .notAuthenticated
    }

    /// One short sentence, in the app's own voice. Never the raw error: a PostgREST body is noise to
    /// the reader, and Sentry already has it.
    func message(for error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "You're offline."
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "Couldn't reach Ate."
            default:
                return fallbackMessage
            }
        }
        return fallbackMessage
    }
}
