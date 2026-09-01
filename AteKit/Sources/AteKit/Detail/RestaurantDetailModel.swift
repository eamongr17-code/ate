import Foundation
import Observation

/// The restaurant detail screen's state: header, ranked dish list, one funnel event pair.
///
/// **The rating is read, never computed.** `avgRating` comes straight from `restaurant_stats`,
/// where it is the mean of per-dish averages (data-model §1.2). Averaging `dishes` here — or worse,
/// averaging a page of reviews — produces a different, wrong number; that was the legacy client's
/// bug and there is deliberately no code here that could reintroduce it.
@MainActor
@Observable
public final class RestaurantDetailModel {
    public let restaurantID: UUID
    public let source: DetailSource

    private let dataSource: any DetailDataSource
    private let analytics: AnalyticsRecorder
    private let onLogDish: (@MainActor () -> Void)?

    public private(set) var state: DetailLoadState = .idle
    public private(set) var snapshot: RestaurantDetailSnapshot?
    private var hasRecordedView = false

    public init(
        restaurantID: UUID,
        source: DetailSource = .unknown,
        dataSource: any DetailDataSource,
        analytics: @escaping AnalyticsRecorder = { _ in },
        onLogDish: (@MainActor () -> Void)? = nil
    ) {
        self.restaurantID = restaurantID
        self.source = source
        self.dataSource = dataSource
        self.analytics = analytics
        self.onLogDish = onLogDish
    }

    // MARK: - Derived state the view renders

    public var restaurant: Restaurant? { snapshot?.restaurant }
    /// nil = nothing here is rated yet. Rendered `–/5`, never 0.
    public var avgRating: Double? { snapshot?.avgRating }
    public var isRated: Bool { snapshot?.isRated ?? false }
    public var reviewCount: Int { snapshot?.reviewCount ?? 0 }
    /// Review count desc, then score desc (see ``DishRanking``).
    public var dishes: [RankedDish] { snapshot?.dishes ?? [] }
    public var showsEmptyDishState: Bool { state.isLoaded && dishes.isEmpty }
    public var canLogDish: Bool { onLogDish != nil }

    // MARK: - Loading

    public func load() async {
        guard state == .idle || state.errorMessage != nil else { return }
        await performLoad()
    }

    public func refresh() async {
        await performLoad()
    }

    private func performLoad() async {
        state = .loading
        do {
            let snapshot = try await dataSource.restaurantDetail(id: restaurantID)
            self.snapshot = snapshot
            state = .loaded
            recordViewIfNeeded()
        } catch {
            state = .failed(error.detailDisplayMessage)
        }
    }

    // MARK: - Funnel

    private func recordViewIfNeeded() {
        guard !hasRecordedView else { return }
        hasRecordedView = true
        analytics(DetailEvents.restaurantDetailViewed(restaurantID: restaurantID, source: source))
    }

    public func logDishTapped() {
        analytics(DetailEvents.logCTATapped(from: .restaurantDetail))
        onLogDish?()
    }
}
