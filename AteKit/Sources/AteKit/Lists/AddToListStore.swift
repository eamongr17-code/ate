import Foundation
import Observation

/// **"Add to a list"** — every list you have, ticked where it already holds this dish line. A tick
/// adds the line (appended last), an untick removes it; both show at once and undo themselves on a
/// refusal. A list can be made from here too, with the line already on it.
@MainActor
@Observable
public final class AddToListStore {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed
    }

    public let line: DishLine
    public private(set) var lists: [ListMembership] = []
    public private(set) var phase: Phase = .loading
    public private(set) var failure: ListsError?
    /// The list "New list" made here, as the server named it — the screen opens it once the line is on.
    public private(set) var created: UserList?

    @ObservationIgnored private let service: any ListsServing
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private weak var shelf: ListsStore?
    @ObservationIgnored private var inFlight: Set<UUID> = []

    public init(
        line: DishLine,
        service: any ListsServing,
        shelf: ListsStore? = nil,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) {
        self.line = line
        self.service = service
        self.shelf = shelf
        self.analytics = analytics
    }

    /// How many lists hold the line.
    public var containingCount: Int { lists.filter(\.contains).count }

    public func clearFailure() { failure = nil }

    public func load() async {
        if lists.isEmpty { phase = .loading }
        do {
            lists = try await service.lists(containing: line)
            phase = .ready
        } catch {
            if lists.isEmpty { phase = .failed }
        }
    }

    /// One tap on a list's row. Returns whether it landed.
    @discardableResult
    public func toggle(_ membership: ListMembership) async -> Bool {
        guard inFlight.insert(membership.listID).inserted else { return false }
        defer { inFlight.remove(membership.listID) }
        guard let index = lists.firstIndex(where: { $0.listID == membership.listID }) else { return false }
        let before = lists[index]
        if let itemID = before.itemID {
            lists[index] = before.holding(nil)
            do {
                try await service.removeItem(itemID: itemID)
                analytics(ListEvents.itemRemoved(listSize: before.itemCount - 1))
                shelf?.changedCount(listID: before.listID, by: -1)
                return true
            } catch {
                restore(before)
                return fail(ListsError.of(error))
            }
        }
        if before.itemCount >= ListRules.itemCap { return fail(.itemCap) }
        // A placeholder id ticks the row now; the server's id replaces it.
        lists[index] = before.holding(UUID())
        do {
            let receipt = try await service.addItem(listID: before.listID, line: line)
            if let at = lists.firstIndex(where: { $0.listID == before.listID }) {
                lists[at] = ListMembership(
                    listID: before.listID, name: before.name, itemCount: before.itemCount + 1, itemID: receipt.itemID
                )
            }
            analytics(ListEvents.itemAdded(count: 1, from: .sheet))
            shelf?.changedCount(listID: before.listID, by: 1)
            return true
        } catch {
            restore(before)
            return fail(ListsError.of(error))
        }
    }

    /// "New list" from the sheet: made, then the line put on it. The new list is ticked, on top.
    @discardableResult
    public func createList(named name: String) async -> Bool {
        guard let name = ListRules.name(name) else { return fail(.badName) }
        do {
            let created = try await service.createList(name: name)
            analytics(ListEvents.created())
            shelf?.added(created)
            self.created = created
            lists.insert(ListMembership(listID: created.id, name: created.name, itemCount: 0, itemID: nil), at: 0)
            guard let membership = lists.first else { return false }
            return await toggle(membership)
        } catch {
            return fail(ListsError.of(error))
        }
    }

    private func fail(_ error: ListsError) -> Bool {
        failure = error
        return false
    }

    private func restore(_ membership: ListMembership) {
        guard let at = lists.firstIndex(where: { $0.listID == membership.listID }) else { return }
        lists[at] = membership
    }
}
