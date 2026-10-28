import Foundation
import Observation

/// **"Add to a list"** — every list you have, ticked where it already holds the dish line (or, for
/// several lines, all of them). A tick adds the lines (appended last), an untick removes them; both
/// show at once and undo themselves on a refusal. A list can be made from here too, with the lines
/// already on it.
///
/// Several lines come from an entry's "Add to a list" (Eamon, 28 Oct): the dishes picked there go on
/// together. A list holding only some of them shows unticked, and a tick adds the rest.
@MainActor
@Observable
public final class AddToListStore {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed
    }

    /// The first of ``lines`` — the one line the sheet is about when there is only one.
    public let line: DishLine
    public let lines: [DishLine]
    public private(set) var lists: [ListMembership] = []
    public private(set) var phase: Phase = .loading
    public private(set) var failure: ListsError?
    /// The list "New list" made here, as the server named it — the screen opens it once the line is on.
    public private(set) var created: UserList?

    @ObservationIgnored private let service: any ListsServing
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private weak var shelf: ListsStore?
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// Per list, the item each of ``lines`` already is on it.
    @ObservationIgnored private var held: [UUID: [DishLine: UUID]] = [:]

    public convenience init(
        line: DishLine,
        service: any ListsServing,
        shelf: ListsStore? = nil,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) {
        self.init(lines: [line], service: service, shelf: shelf, analytics: analytics)
    }

    /// `lines`: at least one, each once, in the order they go on a list.
    public init(
        lines: [DishLine],
        service: any ListsServing,
        shelf: ListsStore? = nil,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) {
        var seen = Set<DishLine>()
        let unique = lines.filter { seen.insert($0).inserted }
        precondition(unique.isEmpty == false, "Add to a list needs a dish line")
        self.line = unique[0]
        self.lines = unique
        self.service = service
        self.shelf = shelf
        self.analytics = analytics
    }

    /// How many lists hold the line (every one of the lines).
    public var containingCount: Int { lists.filter(\.contains).count }

    public func clearFailure() { failure = nil }

    public func load() async {
        if lists.isEmpty { phase = .loading }
        do {
            var readings: [DishLine: [ListMembership]] = [:]
            // One read per line, side by side: an entry holds a handful of dishes.
            try await withThrowingTaskGroup(of: (DishLine, [ListMembership]).self) { group in
                for line in lines {
                    group.addTask { [service] in (line, try await service.lists(containing: line)) }
                }
                for try await (line, memberships) in group { readings[line] = memberships }
            }
            var held: [UUID: [DishLine: UUID]] = [:]
            for (line, memberships) in readings {
                for membership in memberships {
                    if let itemID = membership.itemID { held[membership.listID, default: [:]][line] = itemID }
                }
            }
            self.held = held
            lists = (readings[line] ?? []).map { membership in
                ListMembership(
                    listID: membership.listID, name: membership.name, itemCount: membership.itemCount,
                    itemID: holdsAll(membership.listID) ? held[membership.listID]?[line] : nil
                )
            }
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
        return before.contains ? await takeOff(before) : await putOn(before)
    }

    /// Every line off the list, one item at a time; a refusal puts back what is still there.
    private func takeOff(_ before: ListMembership) async -> Bool {
        let items = held[before.listID] ?? [:]
        replace(before.listID, with: before.holding(nil))
        var removed = 0
        for line in lines {
            guard let itemID = items[line] else { continue }
            do {
                try await service.removeItem(itemID: itemID)
                held[before.listID]?[line] = nil
                removed += 1
            } catch {
                settle(before, removed: removed)
                return fail(ListsError.of(error))
            }
        }
        settle(before, removed: removed)
        analytics(ListEvents.itemRemoved(listSize: before.itemCount - removed))
        return true
    }

    /// Every line not on the list yet, appended in order; a refusal keeps what landed.
    private func putOn(_ before: ListMembership) async -> Bool {
        let missing = lines.filter { held[before.listID]?[$0] == nil }
        if before.itemCount + missing.count > ListRules.itemCap { return fail(.itemCap) }
        // A placeholder id ticks the row now; the server's id replaces it.
        replace(before.listID, with: ListMembership(
            listID: before.listID, name: before.name, itemCount: before.itemCount + missing.count, itemID: UUID()
        ))
        var added = 0
        for line in missing {
            do {
                let receipt = try await service.addItem(listID: before.listID, line: line)
                held[before.listID, default: [:]][line] = receipt.itemID
                added += 1
            } catch {
                settle(before, added: added)
                return fail(ListsError.of(error))
            }
        }
        settle(before, added: added)
        analytics(ListEvents.itemAdded(count: added, from: .sheet))
        return true
    }

    /// The row as the server now has it, and the shelf's count moved by what changed.
    private func settle(_ before: ListMembership, added: Int = 0, removed: Int = 0) {
        let all = holdsAll(before.listID)
        replace(before.listID, with: ListMembership(
            listID: before.listID, name: before.name, itemCount: before.itemCount + added - removed,
            itemID: all ? held[before.listID]?[line] : nil
        ))
        if added - removed != 0 { shelf?.changedCount(listID: before.listID, by: added - removed) }
    }

    private func holdsAll(_ listID: UUID) -> Bool {
        let items = held[listID] ?? [:]
        return lines.allSatisfy { items[$0] != nil }
    }

    private func replace(_ listID: UUID, with membership: ListMembership) {
        guard let at = lists.firstIndex(where: { $0.listID == listID }) else { return }
        lists[at] = membership
    }

    /// "New list" from the sheet: made, then the lines put on it. The new list is ticked, on top.
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
}
