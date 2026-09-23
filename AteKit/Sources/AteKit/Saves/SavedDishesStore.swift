import Foundation
import Observation

/// **The Saved shelf**: the dishes you meant to eat, grouped by where they are served.
///
/// Paged like everything else (`(saved_at, dish_id)` keyset), and grouped on arrival so a place
/// split across a page boundary rejoins when the next page lands rather than appearing twice.
///
/// Unsaving is optimistic and **removes the row**: on this screen the bookmark is the only reason a
/// row exists, so leaving an emptied one behind would be a list that disagrees with the tap that
/// just happened. If the RPC refuses, the row goes back where it was.
@MainActor
@Observable
public final class SavedDishesStore {

    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case empty
        case signedOut
        case failed(message: String)
    }

    public private(set) var dishes: [SavedDish] = []
    public private(set) var groups: [SavedDishGroup] = []
    public private(set) var phase: Phase = .loading
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedEnd = false

    private let saves: any DishSaving
    private let pageSize: Int
    private var nextCursor: PageCursor?
    private var seenIDs: Set<UUID> = []
    private var hasLoadedOnce = false
    private var generation = 0
    private var isLoadingFirstPage = false

    private static let prefetchDistance = 6

    public init(saves: any DishSaving, pageSize: Int = 50) {
        self.saves = saves
        self.pageSize = pageSize
    }

    // MARK: - Loading

    public func loadIfNeeded() async {
        guard hasLoadedOnce == false else { return }
        await loadFirstPage()
    }

    public func refresh() async {
        await loadFirstPage()
    }

    /// Something happened elsewhere that this list cannot know about — a save in the feed, or on an
    /// entry page. The shelf reloads the next time it is looked at rather than while it is not.
    public func invalidate() {
        hasLoadedOnce = false
    }

    public func loadMoreIfNeeded(after dish: SavedDish) async {
        guard let index = dishes.firstIndex(where: { $0.dishID == dish.dishID }) else { return }
        guard index >= dishes.count - Self.prefetchDistance else { return }
        await loadMore()
    }

    public func loadMore() async {
        guard isLoadingMore == false, isLoadingFirstPage == false,
              hasReachedEnd == false, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generationAtStart = generation
        guard let page = try? await saves.savedDishesPage(after: cursor, pageSize: pageSize) else { return }
        guard generationAtStart == generation else { return }
        append(page)
    }

    private func loadFirstPage() async {
        guard isLoadingFirstPage == false else { return }
        isLoadingFirstPage = true
        generation += 1
        let generationAtStart = generation
        defer { isLoadingFirstPage = false }

        if dishes.isEmpty { phase = .loading }
        do {
            let page = try await saves.savedDishesPage(after: nil, pageSize: pageSize)
            guard generationAtStart == generation else { return }
            hasLoadedOnce = true
            reset()
            append(page)
            phase = dishes.isEmpty ? .empty : .ready
        } catch is CancellationError {
            return
        } catch {
            guard generationAtStart == generation else { return }
            hasLoadedOnce = true
            guard dishes.isEmpty else { return }
            phase = (error as? AteAPIError) == .notAuthenticated
                ? .signedOut
                : .failed(message: "Couldn't load what you saved.")
        }
    }

    // MARK: - Unsaving

    /// Optimistic: the row leaves, and comes back if the server refuses.
    ///
    /// **Returns whether it landed**, because the caller has things to do that must not happen on a
    /// refusal — telling every other list the dish is unsaved, and counting a `save_toggled` that
    /// never happened.
    @discardableResult
    public func unsave(_ dish: SavedDish) async -> Bool {
        let index = dishes.firstIndex { $0.dishID == dish.dishID }
        if let index {
            dishes.remove(at: index)
            seenIDs.remove(dish.dishID)
            regroup()
            if dishes.isEmpty, phase == .ready { phase = .empty }
        }
        do {
            try await saves.unsave(dishID: dish.dishID)
            return true
        } catch {
            guard let index else { return false }
            dishes.insert(dish, at: min(index, dishes.count))
            seenIDs.insert(dish.dishID)
            phase = .ready
            regroup()
            return false
        }
    }

    // MARK: - Machinery

    private func reset() {
        dishes = []
        seenIDs = []
        nextCursor = nil
        hasReachedEnd = false
        regroup()
    }

    private func append(_ page: Page<SavedDish>) {
        let fresh = page.items.filter { seenIDs.insert($0.dishID).inserted }
        dishes.append(contentsOf: fresh)
        nextCursor = page.nextCursor
        hasReachedEnd = page.isLastPage
        regroup()
    }

    /// The one place `dishes` is read back into shape. Every mutation ends here.
    private func regroup() {
        groups = SavedDishGrouping.groups(from: dishes)
    }
}
