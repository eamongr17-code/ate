import Foundation
import Observation

/// All of the diary's behaviour — paging, dedup, staleness, and which state the screen is in — as
/// one `@Observable` the view merely renders. Every rule below is exercised by `DiaryStoreTests`
/// against a stubbed ``DiaryReading``.
///
/// **Why this isn't `FeedStore` with a different client.** The paging invariants are the same (and
/// the keyset/dedup/generation handling here is deliberately the same shape, page for page), but two
/// behaviours differ in kind: the diary must *become stale* when you post — a list of your own
/// reviews that doesn't contain the one you just wrote is a bug, not a cache miss — and its copy is
/// first-person ("you haven't logged anything") where the feed's is about everyone. Sharing the type
/// would mean branching on a mode flag inside every state transition. If a third paginated list
/// appears, extracting one engine from both stores is the right move; two is not yet a pattern.
@MainActor
@Observable
public final class DiaryStore {

    /// What the screen shows *instead of* entries.
    public enum Phase: Sendable, Equatable {
        /// First load in flight.
        case loading
        /// At least one entry is loaded.
        case ready
        /// Loaded successfully, and you haven't logged anything yet. An invitation, not an error.
        case empty
        /// No session. RLS hands `anon` a successful empty page, so without this the signed-out user
        /// would be told *they* had logged nothing — a claim about a person we can't identify.
        case signedOut
        /// First load failed with nothing on screen. Recoverable via ``retry()``.
        case failed(message: String)

        /// Whether the diary shows its "Log a dish" composer (§3.1, §3.4).
        ///
        /// True in **every** phase except signed out — including `.loading` and `.failed`. That is
        /// the whole rule: logging a dish is not a read of your history and must never wait on one.
        /// Someone standing in a restaurant with no signal still gets to record what they ate; what
        /// they lose is the list underneath, which is not what they opened the app to do.
        ///
        /// Signed out is the one exception, and not for tidiness: there is no session to write a
        /// review against, so the button could only fail.
        public var allowsComposer: Bool { self != .signedOut }
    }

    /// How close to the end of the list a row must be to trigger the next page.
    private static let prefetchDistance = 5

    // MARK: - Observable state

    public private(set) var entries: [FeedEntry] = []
    /// ``entries``, read as a record: months of sittings (§3.2). Stored rather than computed on
    /// demand because the view touches it on every layout pass and the grouping is a full pass over
    /// the page; it is recomputed on *every* mutation of `entries`, which is what makes a sitting
    /// split across a page boundary regroup when the next page lands.
    public private(set) var months: [DiaryMonth] = []
    /// The line under the large title, or `nil` when there is nothing trustworthy to say (§3.1).
    public private(set) var recordLine: String?
    public private(set) var phase: Phase = .loading
    /// A page-load or refresh failed while content was already on screen. Shown inline near the
    /// content — never as an alert, which would interrupt scrolling to report a recoverable miss.
    public private(set) var inlineErrorMessage: String?
    public private(set) var isLoadingMore = false
    /// True once the stream is exhausted — the list stops asking and hides its footer.
    public private(set) var hasReachedEnd = false

    // MARK: - Private state

    private let client: any DiaryReading
    private let analytics: AnalyticsRecorder
    private let pageSize: Int
    private var nextCursor: PageCursor?
    /// Membership index for O(1) dedup. Two pages can overlap when a review is deleted mid-scroll
    /// and the keyset shifts; a repeated id must be dropped, never rendered twice.
    private var seenIDs: Set<UUID> = []
    private var hasLoadedOnce = false
    /// Set when something happened that the loaded list can't reflect (you posted). The next
    /// appearance reloads instead of showing a list that is missing your newest review.
    private var needsRefresh = false
    /// Bumped on every refresh so a slow in-flight page can't append itself onto a fresher list.
    private var generation = 0
    private var isLoadingFirstPage = false

    public init(
        client: any DiaryReading,
        analytics: @escaping AnalyticsRecorder = { _ in },
        pageSize: Int = PageRequest.defaultLimit
    ) {
        self.client = client
        self.analytics = analytics
        self.pageSize = pageSize
    }

    // MARK: - Loading

    /// The appearance entry point: loads on the first appearance, and on any later one where the
    /// list is known to be stale. Otherwise it stays quiet, so switching tabs neither refetches nor
    /// jumps the scroll position.
    public func loadIfNeeded() async {
        guard !hasLoadedOnce || needsRefresh else { return }
        await loadFirstPage()
    }

    /// Pull-to-refresh, and the retry affordance on the error state. Existing entries stay on screen
    /// until the new first page arrives, so a refresh never flashes an empty list.
    public func refresh() async {
        await loadFirstPage()
    }

    /// Explicit retry from the failed/signed-out state.
    public func retry() async {
        await loadFirstPage()
    }

    /// Marks whatever is loaded as no longer trustworthy, without fetching. The next
    /// ``loadIfNeeded()`` does the work.
    ///
    /// Used for anything that changes what *your* diary contains or who "you" are — a post, or a
    /// session appearing after the first read already failed with no session (the Debug auto
    /// sign-in, which resolves after the launch tab has already asked).
    public func invalidate() {
        needsRefresh = true
    }

    /// Called when reviews were posted elsewhere in the app (the Log sheet finishing). Marks the
    /// list stale rather than fetching immediately: the sheet is still on screen, the diary may be
    /// three tabs away, and the request that matters is the one made when it's next looked at.
    public func reviewsWerePosted() {
        invalidate()
    }

    /// Called as rows appear. Fires the next page once the visible row is within
    /// ``prefetchDistance`` of the end.
    public func loadMoreIfNeeded(after entry: FeedEntry) async {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        guard index >= entries.count - Self.prefetchDistance else { return }
        await loadMore()
    }

    /// The next page. Safe to call spuriously: it no-ops while one is in flight, at the end of the
    /// stream, or before the first page has landed.
    public func loadMore() async {
        guard !isLoadingMore, !isLoadingFirstPage, !hasReachedEnd, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let generationAtStart = generation
        do {
            let page = try await client.diaryPage(PageRequest(limit: pageSize, after: cursor))
            guard generationAtStart == generation else { return }  // a refresh overtook us
            append(page)
            inlineErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            inlineErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    // MARK: - Machinery

    private func loadFirstPage() async {
        guard !isLoadingFirstPage else { return }
        isLoadingFirstPage = true
        generation += 1
        let generationAtStart = generation
        defer { isLoadingFirstPage = false }

        if entries.isEmpty { phase = .loading }

        do {
            let page = try await client.diaryPage(PageRequest(limit: pageSize))
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
                    : .failed(message: Self.userFacingMessage(for: error))
            } else if Self.isNotAuthenticated(error) {
                // Signed out mid-session: the stale list is no longer ours to show.
                reset()
                phase = .signedOut
            } else {
                inlineErrorMessage = Self.userFacingMessage(for: error)
            }
        }
    }

    private func reset() {
        entries = []
        seenIDs = []
        nextCursor = nil
        hasReachedEnd = false
        regroup()
    }

    private func append(_ page: Page<FeedEntry>) {
        let fresh = page.items.filter { seenIDs.insert($0.id).inserted }
        entries.append(contentsOf: fresh)
        nextCursor = page.nextCursor
        hasReachedEnd = page.isLastPage
        regroup()
    }

    /// The one place `entries` is read back into shape. Every mutation ends here — a memoised
    /// grouping is exactly the bug §3.2 names, where a sitting cut in half by a page boundary stays
    /// cut in half forever.
    private func regroup() {
        months = DiaryGrouping.months(from: entries)
        recordLine = DiaryRecordLine.text(entries: entries, hasReachedEnd: hasReachedEnd)
    }

    // MARK: - Optimistic insert

    /// Puts a just-posted sitting on the page immediately (§7.4).
    ///
    /// Called as the Log sheet leaves, with the rows it wrote and the names it wrote them under.
    /// ``reviewsWerePosted()`` still runs behind it, so the server's version of these rows lands on
    /// the next look and reconciles onto identical ids — this only changes *when* the block appears,
    /// never what it eventually says.
    ///
    /// It matters most on the first log of all: ``loadFirstPage()`` shows `.loading` only when
    /// `entries` is empty, which is precisely the case where the person would otherwise watch their
    /// first ever entry arrive as a skeleton.
    ///
    /// Rows already present are ignored (a retry that re-reports a landed row must not double it),
    /// and the phase moves off `.empty`/`.loading` because there is now something to show. A
    /// signed-out store is left alone: rows posted by a session we no longer have are not ours to
    /// render.
    public func insertPosted(_ posted: PostedSitting) {
        guard phase != .signedOut else { return }
        let fresh = posted.diaryEntries().filter { seenIDs.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        entries.insert(contentsOf: fresh, at: 0)
        // `hasReachedEnd` is untouched on purpose: it means "no older page follows", and prepending
        // newer rows leaves that true — so a fully-loaded diary keeps its exact record line, now
        // counting the sitting you just posted.
        phase = .ready
        regroup()
    }

    // MARK: - Interaction

    public func recordDiaryViewed() {
        analytics(DiaryEvents.diaryViewed())
    }

    /// Records the tap. Navigation itself is a pushed ``DishRoute`` value in the view — this exists
    /// only so the diary's contribution to dish detail is measurable at its source.
    public func recordTap(on entry: FeedEntry) {
        analytics(DiaryEvents.diaryEntryTapped(dishID: entry.dishRoute.dishID))
    }

    /// The diary's three doors into the log flow (§9). Recorded through the store rather than at each
    /// button so all three go through one injected recorder and are asserted in one test.
    public func recordLogCTATapped(from origin: LogCTAOrigin) {
        analytics(DetailEvents.logCTATapped(from: origin))
    }

    // MARK: - Errors

    static func isNotAuthenticated(_ error: any Error) -> Bool {
        (error as? AteAPIError) == .notAuthenticated
    }

    /// One short, human sentence, in the diary's first person. Never the raw error: a PostgREST 400
    /// body is noise to the reader and belongs in Sentry, which already has it.
    static func userFacingMessage(for error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "You're offline."
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "Couldn't reach Ate. Check your connection."
            default:
                return "Couldn't load your diary."
            }
        }
        if Self.isNotAuthenticated(error) { return "Sign in to see your diary." }
        return "Couldn't load your diary."
    }
}
