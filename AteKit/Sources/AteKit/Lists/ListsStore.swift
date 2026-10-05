import Foundation
import Observation

/// **The Lists shelf** — your lists, newest made first, keyset-paged.
///
/// Every edit is optimistic and undone on a refusal: a new list appears at once (on a placeholder id
/// until the server names it — ``isPending(_:)``), a rename shows at once, a delete leaves at once.
/// A refusal puts things back and leaves ``failure`` set; a cap is the one a screen should explain.
@MainActor
@Observable
public final class ListsStore {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case empty
        case failed
    }

    public private(set) var lists: [UserList] = []
    public private(set) var phase: Phase = .loading
    public private(set) var isLoadingMore = false
    public private(set) var hasReachedEnd = false
    /// The last refusal, until ``clearFailure()``.
    public private(set) var failure: ListsError?
    /// Lists made here that the server has not answered for yet.
    public private(set) var pendingIDs: Set<UUID> = []

    @ObservationIgnored private let service: any ListsServing
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var cursor: PageCursor?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var generation = 0

    private static let prefetchDistance = 5

    public init(
        service: any ListsServing,
        analytics: @escaping AnalyticsRecorder = { _ in },
        pageSize: Int = 50,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.analytics = analytics
        self.pageSize = pageSize
        self.now = now
    }

    public func isPending(_ list: UserList) -> Bool { pendingIDs.contains(list.id) }

    public func clearFailure() { failure = nil }

    // MARK: - Loading

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await refresh()
    }

    public func refresh() async {
        generation += 1
        let generationAtStart = generation
        if lists.isEmpty { phase = .loading }
        do {
            let page = try await service.myLists(after: nil, limit: pageSize)
            guard generationAtStart == generation else { return }
            // A list still being made stays at the top through a refresh.
            let pending = lists.filter { pendingIDs.contains($0.id) }
            lists = pending + page.items
            cursor = page.nextCursor
            hasReachedEnd = page.nextCursor == nil
            hasLoaded = true
            settlePhase()
        } catch {
            guard generationAtStart == generation else { return }
            if lists.isEmpty { phase = .failed }
        }
    }

    public func loadMoreIfNeeded(after list: UserList) async {
        guard let index = lists.firstIndex(where: { $0.id == list.id }),
              index >= lists.count - Self.prefetchDistance else { return }
        await loadMore()
    }

    public func loadMore() async {
        guard hasLoaded, isLoadingMore == false, hasReachedEnd == false, let cursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generationAtStart = generation
        guard let page = try? await service.myLists(after: cursor, limit: pageSize),
              generationAtStart == generation else { return }
        let known = Set(lists.map(\.id))
        lists += page.items.filter { known.contains($0.id) == false }
        self.cursor = page.nextCursor
        hasReachedEnd = page.nextCursor == nil
    }

    // MARK: - Edits

    /// A new list, on top at once. Returns the list as the server made it, or `nil` on a refusal
    /// (``failure`` says which — `listCap` past 50, `badName` for an empty or over-long name).
    @discardableResult
    public func create(name raw: String) async -> UserList? {
        guard let name = ListRules.name(raw) else { return refuse(.badName) }
        if hasReachedEnd, lists.count >= ListRules.listCap { return refuse(.listCap) }
        let made = now()
        let placeholder = UserList(id: UUID(), name: name, itemCount: 0, createdAt: made, updatedAt: made)
        lists.insert(placeholder, at: 0)
        pendingIDs.insert(placeholder.id)
        settlePhase()
        defer { pendingIDs.remove(placeholder.id) }
        do {
            let created = try await service.createList(name: name)
            replace(placeholder.id, with: created)
            analytics(ListEvents.created())
            return created
        } catch {
            lists.removeAll { $0.id == placeholder.id }
            settlePhase()
            return refuse(ListsError.of(error))
        }
    }

    /// The new name shows at once; the old one comes back on a refusal.
    @discardableResult
    public func rename(_ list: UserList, to raw: String) async -> Bool {
        guard let name = ListRules.name(raw) else { return fail(.badName) }
        guard let index = lists.firstIndex(where: { $0.id == list.id }) else { return false }
        let before = lists[index]
        guard before.name != name else { return true }
        lists[index] = before.with(name: name)
        do {
            let renamed = try await service.renameList(id: list.id, name: name)
            replace(list.id, with: renamed.with(covers: before.covers))
            analytics(ListEvents.renamed())
            return true
        } catch {
            let refusal = ListsError.of(error)
            if refusal == .listNotFound {
                // Gone already: the shelf agrees with the server rather than resurrecting it.
                lists.removeAll { $0.id == list.id }
                settlePhase()
            } else {
                replace(list.id, with: before)
            }
            return fail(refusal)
        }
    }

    /// The list leaves at once and comes back where it was on a refusal.
    @discardableResult
    public func delete(_ list: UserList) async -> Bool {
        guard let index = lists.firstIndex(where: { $0.id == list.id }) else { return false }
        let removed = lists.remove(at: index)
        settlePhase()
        do {
            try await service.deleteList(id: list.id)
            analytics(ListEvents.deleted(items: removed.itemCount))
            return true
        } catch {
            lists.insert(removed, at: min(index, lists.count))
            settlePhase()
            return fail(ListsError.of(error))
        }
    }

    /// A list changed on its own page (a count, a cover, a name): the shelf takes the new summary.
    public func updated(_ list: UserList) {
        replace(list.id, with: list)
    }

    /// A list made somewhere else (the Add to a list sheet's New list): on top of the shelf.
    public func added(_ list: UserList) {
        guard lists.contains(where: { $0.id == list.id }) == false else { return }
        lists.insert(list, at: 0)
        settlePhase()
    }

    /// A dish went on or off a list from somewhere else (the Add to a list sheet).
    public func changedCount(listID: UUID, by delta: Int) {
        guard let list = lists.first(where: { $0.id == listID }) else { return }
        replace(listID, with: list.with(itemCount: list.itemCount + delta))
    }

    /// A list was deleted from its own page.
    public func removed(listID: UUID) {
        lists.removeAll { $0.id == listID }
        settlePhase()
    }

    // MARK: - Machinery

    private func replace(_ id: UUID, with list: UserList) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[index] = list
    }

    private func settlePhase() {
        guard hasLoaded || lists.isEmpty == false else { return }
        phase = lists.isEmpty ? .empty : .ready
    }

    /// Records the refusal and answers `nil`, so a caller can `return refuse(…)`.
    private func refuse(_ error: ListsError) -> UserList? {
        failure = error
        return nil
    }

    private func fail(_ error: ListsError) -> Bool {
        failure = error
        return false
    }
}
