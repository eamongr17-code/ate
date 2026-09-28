import Foundation
import Observation

/// **Below a dish's reviews** (round 7, `DishExplore`): "More to explore" — the dish's tags as chips —
/// and "More like this" — the dishes most like it, as a carousel.
///
/// Read **after** the page's own read (the header and the first reviews), so neither ever slows the
/// part of the page somebody opened it for. Both reads go out together and the two sections arrive
/// together, once: until then the page holds their space at its final size, and a section with
/// nothing in it — or a read that fell over — simply is not there. No error line: an absent
/// "more like this" is not something to explain (design rule 1).
@MainActor
@Observable
public final class DishExploreStore {
    public let dishID: UUID

    /// The chips, in print order (``DishTagOrder``). `[]` until settled, and when there are none.
    public private(set) var tags: [DishTag] = []
    /// The carousel, the page's own dish never among it.
    public private(set) var similar: [SimilarDish] = []
    /// Both reads have answered. Until then the sections are still shapes at their final size.
    public private(set) var isSettled = false

    private let reads: any DishExploreReading
    private let limit: Int
    private var isLoading = false

    public init(
        dishID: UUID,
        reads: any DishExploreReading,
        limit: Int = DishExploreClient.similarLimit
    ) {
        self.dishID = dishID
        self.reads = reads
        self.limit = limit
    }

    /// Whether "More to explore" is on the page: held while it is read, then only with a chip in it.
    public var showsTags: Bool { isSettled == false || tags.isEmpty == false }
    /// Whether "More like this" is on the page, by the same rule.
    public var showsSimilar: Bool { isSettled == false || similar.isEmpty == false }

    /// Once per page. Call it when the page's own read has settled.
    public func load() async {
        guard isSettled == false else { return }
        await read()
    }

    /// A pull to refresh: read again, and keep what is on screen until the answer is in.
    public func refresh() async {
        await read()
    }

    private func read() async {
        guard isLoading == false else { return }
        isLoading = true
        defer { isLoading = false }
        let reads = reads, dishID = dishID, limit = limit
        // A failed read is an absent section, not an error on the page.
        async let tagRows = try? reads.dishTags(dishID: dishID)
        async let similarRows = try? reads.similarDishes(dishID: dishID, limit: limit)
        let (tagResult, similarResult) = await (tagRows, similarRows)
        // Taken away mid-read (the page was popped): nothing to settle, and the next visit asks again.
        guard Task.isCancelled == false else { return }
        if let tagResult { tags = DishTagOrder.explore(tagResult) } else if isSettled == false { tags = [] }
        if let similarResult {
            similar = Self.others(similarResult, than: dishID)
        } else if isSettled == false {
            similar = []
        }
        isSettled = true
    }

    /// The page's own dish is never "like" itself, and a dish is one card — the server excludes and
    /// dedupes already; this is the belt to its braces, because a duplicate id in a list is a crash.
    static func others(_ rows: [SimilarDish], than dishID: UUID) -> [SimilarDish] {
        var seen: Set<UUID> = [dishID]
        return rows.filter { seen.insert($0.dishID).inserted }
    }
}

/// **One tag's dishes** — the page a chip opens: a plain list of dish rows, keyset-paged, best first.
@MainActor
@Observable
public final class TagDishesStore {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        /// Loaded, and no dish carries the tag.
        case empty
        case failed(message: String)
    }

    public static let pageSize = 20

    public let tag: DishTagRoute
    public private(set) var dishes: [SimilarDish] = []
    public private(set) var phase: Phase = .loading
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedEnd = false
    /// A later page failed while rows were on screen: said inline, never as an alert.
    public private(set) var inlineErrorMessage: String?

    private let reads: any DishExploreReading
    private let pageSize: Int
    private var nextCursor: TagDishCursor?
    private var seenIDs: Set<UUID> = []
    private var hasLoaded = false
    private var generation = 0

    /// How close to the end a row must be before the next page is asked for.
    private static let prefetchDistance = 4
    static let failureMessage = "Couldn't load these dishes."

    public init(tag: DishTagRoute, reads: any DishExploreReading, pageSize: Int = TagDishesStore.pageSize) {
        self.tag = tag
        self.reads = reads
        self.pageSize = pageSize
    }

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await refresh()
    }

    public func refresh() async {
        generation += 1
        let generationAtStart = generation
        if dishes.isEmpty { phase = .loading }
        do {
            let page = try await reads.dishesByTag(
                kind: tag.kind, slug: tag.slug, city: tag.city, after: nil, pageSize: pageSize
            )
            guard generationAtStart == generation else { return }
            hasLoaded = true
            dishes = []
            seenIDs = []
            append(page)
            phase = dishes.isEmpty ? .empty : .ready
            inlineErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            hasLoaded = true
            if dishes.isEmpty {
                phase = .failed(message: Self.failureMessage)
            } else {
                inlineErrorMessage = Self.failureMessage
            }
        }
    }

    /// Infinite scroll. Fires only near the end, so a fast scroll does not queue a request per row.
    public func loadMoreIfNeeded(after dish: SimilarDish) async {
        guard let index = dishes.firstIndex(where: { $0.id == dish.id }),
              index >= dishes.count - Self.prefetchDistance else { return }
        await loadMore()
    }

    public func loadMore() async {
        guard isLoadingMore == false, hasReachedEnd == false, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generationAtStart = generation
        do {
            let page = try await reads.dishesByTag(
                kind: tag.kind, slug: tag.slug, city: tag.city, after: cursor, pageSize: pageSize
            )
            guard generationAtStart == generation else { return }
            append(page)
            inlineErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            inlineErrorMessage = "Couldn't load more dishes."
        }
    }

    /// Appends in the server's order, dropping ids already on screen.
    private func append(_ page: TagDishPage) {
        dishes += page.items.filter { seenIDs.insert($0.dishID).inserted }
        nextCursor = page.nextCursor
        hasReachedEnd = page.isLastPage
    }
}
