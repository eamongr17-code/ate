import Foundation
import Observation

/// **The dish page**: the header, the bookmark, and the reviews with the viewer's own at the top.
///
/// The bookmark is the interesting part. It is seeded from `dish_summary.saved` and then it
/// *listens* — the same ``SavedDishBroadcast`` the feed, a profile and an entry page listen to — so
/// a dish saved on this page is already saved on the feed underneath it, and a dish saved on the
/// feed is already saved when this page is pushed. Nothing is hand-wired, which is the only way
/// "the same action works identically everywhere" survives a fourth surface (AGENTS.md rule 2).
@MainActor
@Observable
public final class DishPageStore: SavedDishObserving {

    public enum Header: Sendable, Equatable {
        case loading
        case ready(DishSummary)
        /// Deleted, never there, or behind a block.
        case unavailable
        /// The read never came back — offline, or the server fell over. Not the same as a place
        /// that is not there: this one is worth another try, and the page offers one.
        case unreachable

        /// Either way the page has said all it will: its one line, and nothing under it.
        public var isFailure: Bool { self == .unavailable || self == .unreachable }
    }

    public enum Reviews: Sendable, Equatable {
        case loading
        case ready
        /// Loaded, and nobody has written about this dish. Honest, not an error.
        case empty
        case signedOut
        case failed(message: String)
    }

    public static let reviewPageSize = 20

    public let dishID: UUID
    public let source: DetailSource

    public private(set) var header: Header = .loading
    public private(set) var reviews: [DishReview] = []
    public private(set) var phase: Reviews = .loading
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedEnd = false
    /// A later page failed while rows were already on screen. Shown inline, never as an alert.
    public private(set) var inlineErrorMessage: String?
    /// The viewer's bookmark, wherever it was last changed.
    public private(set) var isSaved = false

    private let dishes: any DishPageReading
    private let analytics: AnalyticsRecorder
    private let pageSize: Int
    private var nextCursor: DishReviewCursor?
    private var seenIDs: Set<UUID> = []
    private var hasLoadedHeader = false
    private var hasLoadedFirstPage = false
    private var isLoadingFirstPage = false
    private var generation = 0
    private var hasRecordedView = false

    /// How close to the end a row must be before the next page is asked for.
    private static let prefetchDistance = 4

    public init(
        dishID: UUID,
        source: DetailSource = .unknown,
        dishes: any DishPageReading,
        pageSize: Int = DishPageStore.reviewPageSize,
        savedDishes: SavedDishBroadcast? = nil,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) {
        self.dishID = dishID
        self.source = source
        self.dishes = dishes
        self.pageSize = pageSize
        self.analytics = analytics
        savedDishes?.add(self)
    }

    // MARK: - What the view reads

    public var summary: DishSummary? {
        if case .ready(let summary) = header { return summary }
        return nil
    }

    public var name: String? { summary?.name }
    public var restaurantID: UUID? { summary?.restaurantID }

    /// **The hero**, as `design/v1/Dish` draws it: two tilted squircles.
    ///
    /// Straight off `dish_summary.photos`, newest first (0029) — one round trip, and never
    /// assembled out of the reviews, which would draw a different pair depending on how far the
    /// list had paged.
    public var heroPhotoURLs: [String] {
        var urls: [String] = []
        for photo in summary?.photos ?? [] where urls.contains(photo.url) == false {
            urls.append(photo.url)
            if urls.count >= Self.heroPhotoCount { break }
        }
        return urls
    }

    /// Two. A third angle would be a wider stack than the artboard draws.
    public static let heroPhotoCount = 2
    /// `nil` = nobody has scored it. Rendered as an empty star row, never as 0.0.
    public var score: Double? { summary?.score }
    public var peopleCount: Int { summary?.peopleCount ?? 0 }

    // MARK: - Loading

    public func load() async {
        async let header: Void = loadHeaderIfNeeded()
        async let list: Void = loadFirstPageIfNeeded()
        _ = await (header, list)
    }

    public func refresh() async {
        hasLoadedHeader = false
        async let header: Void = loadHeaderIfNeeded()
        async let list: Void = loadFirstPage()
        _ = await (header, list)
    }

    /// "Try again", after a header that never came back. The same reads a pull to refresh makes,
    /// with the header back to its skeleton while they are in the air.
    public func retry() async {
        guard header == .unreachable else { return }
        analytics(RecoveryEvents.detailRetried(.dish))
        header = .loading
        await refresh()
    }

    /// Only a row the server said is not there is "not here". Everything else — a timeout, a 500,
    /// no network — is "couldn't reach Ate", and gets a retry.
    private static func isMissing(_ error: AteAPIError) -> Bool {
        if case .notFound = error { return true }
        return false
    }

    private func loadHeaderIfNeeded() async {
        guard hasLoadedHeader == false else { return }
        do {
            let summary = try await dishes.dishSummary(dishID: dishID)
            hasLoadedHeader = true
            header = .ready(summary)
            isSaved = summary.isSaved
            recordViewIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            hasLoadedHeader = true
            let isMissing = (error as? AteAPIError).map(Self.isMissing) == true
            header = isMissing ? .unavailable : .unreachable
            if isMissing == false { analytics(RecoveryEvents.detailUnreachable(.dish)) }
        }
    }

    private func loadFirstPageIfNeeded() async {
        guard hasLoadedFirstPage == false else { return }
        await loadFirstPage()
    }

    private func loadFirstPage() async {
        guard isLoadingFirstPage == false else { return }
        isLoadingFirstPage = true
        generation += 1
        let generationAtStart = generation
        defer { isLoadingFirstPage = false }

        if reviews.isEmpty { phase = .loading }

        do {
            let page = try await dishes.dishReviews(dishID: dishID, after: nil, pageSize: pageSize)
            guard generationAtStart == generation else { return }
            hasLoadedFirstPage = true
            reset()
            append(page)
            phase = reviews.isEmpty ? .empty : .ready
            inlineErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            hasLoadedFirstPage = true
            if reviews.isEmpty {
                phase = EntryListStore.isNotAuthenticated(error)
                    ? .signedOut
                    : .failed(message: "Couldn't load these reviews.")
            } else {
                inlineErrorMessage = "Couldn't load these reviews."
            }
        }
    }

    /// Infinite scroll. Fires only near the end, so a fast scroll does not queue a request per row.
    public func loadMoreIfNeeded(after review: DishReview) async {
        guard let index = reviews.firstIndex(where: { $0.id == review.id }) else { return }
        guard index >= reviews.count - Self.prefetchDistance else { return }
        await loadMore()
    }

    public func loadMore() async {
        guard isLoadingMore == false, isLoadingFirstPage == false,
              hasReachedEnd == false, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let generationAtStart = generation
        do {
            let page = try await dishes.dishReviews(dishID: dishID, after: cursor, pageSize: pageSize)
            guard generationAtStart == generation else { return }
            append(page)
            inlineErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            // A failed *later* page must not blank a screenful of good reviews.
            inlineErrorMessage = "Couldn't load more reviews."
        }
    }

    // MARK: - The bookmark

    /// Told by ``SavedDishBroadcast`` — including the roll-back when the server refuses.
    public func savedDishChanged(dishID: UUID, isSaved: Bool) {
        guard dishID == self.dishID else { return }
        self.isSaved = isSaved
    }

    // MARK: - Machinery

    private func reset() {
        reviews = []
        seenIDs = []
        nextCursor = nil
        hasReachedEnd = false
    }

    /// Appends, dropping ids already on screen — the keyset should never re-serve a row, but a
    /// duplicate id in a SwiftUI list is a crash, not a cosmetic bug. Re-ordered on arrival so
    /// "You" stays at the top whichever page it landed on.
    private func append(_ page: DishReviewPage) {
        let fresh = page.items.filter { seenIDs.insert($0.id).inserted }
        reviews = DishReviewOrder.youFirst(reviews + fresh)
        nextCursor = page.nextCursor
        hasReachedEnd = page.isLastPage
    }

    // MARK: - Funnel

    private func recordViewIfNeeded() {
        guard hasRecordedView == false else { return }
        hasRecordedView = true
        analytics(DetailEvents.dishDetailViewed(dishID: dishID, source: source))
    }
}
