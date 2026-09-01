import Foundation
import Observation

/// The dish detail screen's state: header, paginated reviews, their authors, and the two funnel
/// events the screen owns. The view reads properties and calls three methods; everything that could
/// be wrong (merge redirects, page boundaries, the unrated state) is here, where tests can reach it.
@MainActor
@Observable
public final class DishDetailModel {
    /// Page size for the reviews list. Small enough that the first screenful arrives fast, large
    /// enough that a normal dish never needs a second request.
    public static let reviewPageSize = 20

    /// The id the caller navigated with — which may be a merge tombstone. ``dish`` is the survivor.
    public let requestedDishID: UUID
    public let source: DetailSource

    private let dataSource: any DetailDataSource
    private let analytics: AnalyticsRecorder
    private let onLogDish: (@MainActor () -> Void)?

    public private(set) var state: DetailLoadState = .idle
    public private(set) var snapshot: DishDetailSnapshot?
    public private(set) var reviews: [Review] = []
    public private(set) var authorsByID: [UUID: User] = [:]
    public private(set) var isLoadingMoreReviews = false

    /// The request for the next page, or nil when the stream is exhausted. Starting non-nil is what
    /// makes the first page just another "load more".
    private var nextReviewRequest: PageRequest? = PageRequest(limit: DishDetailModel.reviewPageSize)
    private var hasRecordedView = false

    public init(
        dishID: UUID,
        source: DetailSource = .unknown,
        dataSource: any DetailDataSource,
        analytics: @escaping AnalyticsRecorder = { _ in },
        onLogDish: (@MainActor () -> Void)? = nil
    ) {
        self.requestedDishID = dishID
        self.source = source
        self.dataSource = dataSource
        self.analytics = analytics
        self.onLogDish = onLogDish
    }

    // MARK: - Derived state the view renders

    public var dish: Dish? { snapshot?.dish }
    public var restaurant: Restaurant? { snapshot?.restaurant }
    /// nil = unrated ("want-to-try"), rendered `–/5`. Never 0 (data-model §1.3).
    public var score: Double? { snapshot?.score }
    public var isRated: Bool { snapshot?.isRated ?? false }
    public var reviewCount: Int { snapshot?.reviewCount ?? 0 }
    public var hasMoreReviews: Bool { nextReviewRequest != nil }
    /// True once the first page has come back empty — distinct from "still loading".
    public var showsEmptyReviewState: Bool { state.isLoaded && reviews.isEmpty }
    /// Only offered when the host wired a log flow; until then the CTA doesn't exist rather than
    /// existing and doing nothing.
    public var canLogDish: Bool { onLogDish != nil }

    public func author(of review: Review) -> User? { authorsByID[review.reviewerID] }

    // MARK: - Loading

    /// Idempotent enough to sit in `.task`: a second call while loading, or after a successful load,
    /// is a no-op. Use ``reload()`` to force.
    public func load() async {
        guard state == .idle || state.errorMessage != nil else { return }
        await performLoad()
    }

    public func reload() async {
        await performLoad()
    }

    private func performLoad() async {
        state = .loading
        do {
            let snapshot = try await dataSource.dishDetail(id: requestedDishID)
            self.snapshot = snapshot
            reviews = []
            authorsByID = [:]
            nextReviewRequest = PageRequest(limit: Self.reviewPageSize)
            state = .loaded
            recordViewIfNeeded(dishID: snapshot.dish.id)
            await loadMoreReviews()
        } catch {
            state = .failed(error.detailDisplayMessage)
        }
    }

    /// Pull-to-refresh: re-reads the header and the first page. Kept separate from ``reload()`` only
    /// so a refresh never flashes the whole screen back to a spinner.
    public func refresh() async {
        guard let dishID = snapshot?.dish.id else {
            await performLoad()
            return
        }
        do {
            let snapshot = try await dataSource.dishDetail(id: dishID)
            self.snapshot = snapshot
            reviews = []
            nextReviewRequest = PageRequest(limit: Self.reviewPageSize)
            state = .loaded
            await loadMoreReviews()
        } catch {
            state = .failed(error.detailDisplayMessage)
        }
    }

    /// Infinite scroll trigger. Called as rows appear; fires only near the end so a fast scroll
    /// doesn't queue a request per row.
    public func loadMoreIfNeeded(currentReviewID: UUID) async {
        guard let index = reviews.firstIndex(where: { $0.id == currentReviewID }),
              index >= reviews.count - 3 else { return }
        await loadMoreReviews()
    }

    /// One page, keyset-cut. Reviews are scoped to the **survivor** dish id, so a tombstoned link
    /// shows the surviving dish's reviews rather than an empty list.
    public func loadMoreReviews() async {
        guard let request = nextReviewRequest,
              !isLoadingMoreReviews,
              let dishID = snapshot?.dish.id else { return }

        isLoadingMoreReviews = true
        defer { isLoadingMoreReviews = false }

        do {
            let page = try await dataSource.reviews(dishID: dishID, request: request)
            append(page)
            nextReviewRequest = request.next(after: page)
            await hydrateAuthors(for: page.items)
        } catch {
            // A failed *subsequent* page must not blank a screenful of good reviews; stop paging and
            // leave what's there. The first page's failure is still surfaced via `state`.
            if reviews.isEmpty { state = .failed(error.detailDisplayMessage) }
            nextReviewRequest = nil
        }
    }

    /// Appends, dropping ids already on screen. The keyset cursor shouldn't ever re-serve a row, but
    /// a duplicate id in a SwiftUI `List` is a crash, not a cosmetic bug.
    private func append(_ page: Page<Review>) {
        var seen = Set(reviews.map(\.id))
        for review in page.items where seen.insert(review.id).inserted {
            reviews.append(review)
        }
    }

    private func hydrateAuthors(for reviews: [Review]) async {
        let missing = Set(reviews.map(\.reviewerID)).subtracting(authorsByID.keys)
        guard !missing.isEmpty else { return }
        // A missing author is a display gap, never a screen failure — the reviews still stand.
        guard let profiles = try? await dataSource.authors(ids: Array(missing)) else { return }
        for profile in profiles { authorsByID[profile.id] = profile }
    }

    // MARK: - Funnel

    /// Fired once per screen, with the **survivor** dish id, after the header resolves — so the
    /// funnel counts dishes people actually saw, not tombstones or failed loads.
    private func recordViewIfNeeded(dishID: UUID) {
        guard !hasRecordedView else { return }
        hasRecordedView = true
        analytics(DetailEvents.dishDetailViewed(dishID: dishID, source: source))
    }

    /// The CTA. The event fires even before the log sheet exists, so the intent is measured from
    /// day one (brief D) — the action is whatever the host injected.
    public func logDishTapped() {
        analytics(DetailEvents.logCTATapped(from: .dishDetail))
        onLogDish?()
    }
}
