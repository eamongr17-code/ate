import Foundation
import Observation

/// **One bar of the histogram, opened**: the chart with a score selected, and the dishes behind it.
///
/// The chart is fetched again rather than handed down from You, because the two screens fail
/// independently and a pushed page that inherits a stale chart is a page that disagrees with the one
/// underneath it. It is one cheap RPC.
@MainActor
@Observable
public final class RatingsStore {

    /// The bar that is lit, always a half-step.
    public private(set) var score: Double
    public private(set) var histogram = ScoreHistogram.empty
    public private(set) var dishes: [ScoredDish] = []
    public private(set) var isLoading = true

    private let stats: any StatsReading
    private let pageSize: Int
    private var viewer: UUID?
    private var hasLoadedHistogram = false
    /// Where the next page starts. `nil` once the list is exhausted — the list is keyset-paged like
    /// every other (ARCHITECTURE.md), not a 500-row read hoping nobody eats that much.
    private var cursor: PageCursor?
    private var isLoadingMore = false

    public init(score: Double, stats: any StatsReading, pageSize: Int = StatsClient.defaultDishLimit) {
        self.score = ScoreHistogram.snapped(score)
        self.stats = stats
        self.pageSize = pageSize
    }

    /// How many distinct dishes sit at the selected score — the artboard's "36 dishes". It is the
    /// histogram's own count, not `dishes.count`: the list is one row per *review*, and the label
    /// counts dishes.
    public var dishCount: Int { histogram.dishCount(at: score) }

    public func loadIfNeeded() async {
        guard hasLoadedHistogram == false else { return }
        await load()
    }

    public func refresh() async {
        hasLoadedHistogram = false
        await load()
    }

    /// Tapping another bar, from this screen. A no-op for the bar already lit, and for an empty one:
    /// a score nobody gave has nothing behind it, so it is not a link.
    public func select(_ next: Double) async {
        let snapped = ScoreHistogram.snapped(next)
        guard snapped != score, histogram.dishCount(at: snapped) > 0 else { return }
        score = snapped
        await loadDishes()
    }

    private func load() async {
        guard let viewer = await viewerID() else {
            isLoading = false
            return
        }
        if let chart = try? await stats.histogram(userID: viewer) {
            histogram = chart
            hasLoadedHistogram = true
        }
        await loadDishes()
    }

    /// The next page, asked for as the last few rows come into view.
    public func loadMoreIfNeeded(after dish: ScoredDish) async {
        guard isLoadingMore == false, cursor != nil else { return }
        guard let index = dishes.firstIndex(where: { $0.id == dish.id }),
              index >= dishes.count - RatingsStore.prefetchDistance else { return }
        await loadMore()
    }

    /// How close to the end a row has to be before the next page is asked for.
    private static let prefetchDistance = 5

    private func loadDishes() async {
        guard let viewer = await viewerID() else {
            isLoading = false
            return
        }
        isLoading = true
        cursor = nil
        let page = try? await stats.dishes(userID: viewer, score: score, after: nil, pageSize: pageSize)
        dishes = page?.items ?? []
        cursor = page?.nextCursor
        isLoading = false
    }

    private func loadMore() async {
        guard let viewer = await viewerID(), let cursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await stats.dishes(
            userID: viewer, score: score, after: cursor, pageSize: pageSize
        ) else { return }
        // A keyset page can re-serve a row when one lands mid-scroll; the id is the guard.
        let known = Set(dishes.map(\.id))
        dishes.append(contentsOf: page.items.filter { known.contains($0.id) == false })
        self.cursor = page.nextCursor
    }

    private func viewerID() async -> UUID? {
        if let viewer { return viewer }
        viewer = try? await stats.viewerID()
        return viewer
    }
}
