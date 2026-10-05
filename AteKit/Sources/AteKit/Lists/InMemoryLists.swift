#if DEBUG
import Foundation

/// **Your lists, in memory** — tests, previews and the `-ate-preview-data` drive. It keeps the 0060
/// rules the screens lean on: newest-created first on a two-part keyset, the 50-list and 100-item
/// caps, trimmed 1…80 names, idempotent adds appended last, ranks closing up on a remove, a reorder
/// that must name every item exactly once, and a picker over your own lines, newest visit first.
public final class InMemoryLists: ListsServing, InMemoryStandIn, @unchecked Sendable {
    struct StoredItem {
        let id: UUID
        let line: DishLine
        let addedAt: Date
    }

    struct StoredList {
        let id: UUID
        var name: String
        let createdAt: Date
        var updatedAt: Date
        var items: [StoredItem]
    }

    private let lock = NSLock()
    private var lists: [StoredList]
    /// Every dish line you have written — what the picker searches and what an item draws.
    private var lines: [ListPickerDish]
    private let latency: Duration
    private let now: @Sendable () -> Date
    /// Refusals by the index of the call that meets them.
    private var failures: [Int: ListsError] = [:]
    /// Every call made, by RPC name, newest last — for tests that assert what was asked.
    public private(set) var calls: [String] = []
    /// The last ordered id array `reorder` was given.
    public private(set) var lastReorder: [UUID]?

    public init(
        lines: [ListPickerDish] = [],
        latency: Duration = .zero,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.lists = []
        self.lines = lines
        self.latency = latency
        self.now = now
    }

    // MARK: - Test and preview hooks

    /// The next call (whichever it is) throws `error` — or the one `after` calls from now. Queued:
    /// two `failNext`s fail the next two calls.
    public func failNext(_ error: ListsError, after skipped: Int = 0) {
        lock.withLock {
            var index = calls.count + skipped
            while failures[index] != nil { index += 1 }
            failures[index] = error
        }
    }

    /// A list, made directly — no cap, no latency.
    @discardableResult
    public func seed(name: String, lines: [DishLine], createdAt: Date) -> UUID {
        lock.withLock {
            let items = lines.enumerated().map { offset, line in
                StoredItem(id: UUID(), line: line, addedAt: createdAt.addingTimeInterval(Double(offset)))
            }
            let id = UUID()
            lists.append(StoredList(id: id, name: name, createdAt: createdAt, updatedAt: createdAt, items: items))
            return id
        }
    }

    /// The line was taken off its visit (a re-sort or a delete): it leaves every list, ranks close up.
    public func removeLine(_ line: DishLine) {
        lock.withLock {
            lines.removeAll { $0.line == line }
            for index in lists.indices { lists[index].items.removeAll { $0.line == line } }
        }
    }

    public func itemIDs(listID: UUID) -> [UUID] {
        lock.withLock { lists.first { $0.id == listID }?.items.map(\.id) ?? [] }
    }

    // MARK: - ListsServing

    public func myLists(after cursor: PageCursor?, limit: Int) async throws -> UserListPage {
        try await begin("my_lists")
        return lock.withLock {
            let clamped = min(ListRules.listCap, max(1, limit))
            let ordered = lists.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
            let after = ordered.filter { list in
                guard let cursor else { return true }
                return (list.createdAt, list.id.uuidString) < (cursor.createdAt, cursor.id.uuidString)
            }
            return UserListPage(items: after.prefix(clamped).map(summary), requestedLimit: clamped)
        }
    }

    public func list(id: UUID) async throws -> ListDetail {
        try await begin("get_list")
        return try lock.withLock {
            guard let list = lists.first(where: { $0.id == id }) else { throw ListsError.listNotFound }
            return ListDetail(list: summary(list), items: items(of: list))
        }
    }

    public func createList(name: String) async throws -> UserList {
        try await begin("create_list")
        return try lock.withLock {
            guard let name = ListRules.name(name) else { throw ListsError.badName }
            guard lists.count < ListRules.listCap else { throw ListsError.listCap }
            let created = now()
            let list = StoredList(id: UUID(), name: name, createdAt: created, updatedAt: created, items: [])
            lists.append(list)
            return summary(list)
        }
    }

    public func renameList(id: UUID, name: String) async throws -> UserList {
        try await begin("rename_list")
        return try lock.withLock {
            guard let index = lists.firstIndex(where: { $0.id == id }) else { throw ListsError.listNotFound }
            guard let name = ListRules.name(name) else { throw ListsError.badName }
            lists[index].name = name
            lists[index].updatedAt = now()
            return summary(lists[index])
        }
    }

    public func deleteList(id: UUID) async throws {
        try await begin("delete_list")
        lock.withLock { lists.removeAll { $0.id == id } }
    }

    public func addItem(listID: UUID, line: DishLine) async throws -> ListItemReceipt {
        try await begin("add_list_item")
        return try lock.withLock {
            guard let index = lists.firstIndex(where: { $0.id == listID }) else { throw ListsError.listNotFound }
            guard lines.contains(where: { $0.line == line }) else { throw ListsError.lineNotFound }
            if let position = lists[index].items.firstIndex(where: { $0.line == line }) {
                let item = lists[index].items[position]
                return ListItemReceipt(
                    itemID: item.id, listID: listID, entryID: line.entryID, dishID: line.dishID,
                    position: position + 1, addedAt: item.addedAt
                )
            }
            guard lists[index].items.count < ListRules.itemCap else { throw ListsError.itemCap }
            let item = StoredItem(id: UUID(), line: line, addedAt: now())
            lists[index].items.append(item)
            lists[index].updatedAt = item.addedAt
            return ListItemReceipt(
                itemID: item.id, listID: listID, entryID: line.entryID, dishID: line.dishID,
                position: lists[index].items.count, addedAt: item.addedAt
            )
        }
    }

    public func removeItem(itemID: UUID) async throws {
        try await begin("remove_list_item")
        lock.withLock {
            for index in lists.indices where lists[index].items.contains(where: { $0.id == itemID }) {
                lists[index].items.removeAll { $0.id == itemID }
                lists[index].updatedAt = now()
            }
        }
    }

    public func reorder(listID: UUID, itemIDs: [UUID]) async throws {
        try await begin("reorder_list")
        try lock.withLock {
            lastReorder = itemIDs
            guard let index = lists.firstIndex(where: { $0.id == listID }) else { throw ListsError.listNotFound }
            let current = lists[index].items
            guard itemIDs.count == current.count, Set(itemIDs) == Set(current.map(\.id)),
                  Set(itemIDs).count == itemIDs.count else { throw ListsError.reorderMismatch }
            let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            lists[index].items = itemIDs.compactMap { byID[$0] }
            lists[index].updatedAt = now()
        }
    }

    public func lists(containing line: DishLine) async throws -> [ListMembership] {
        try await begin("my_lists_for_dish_line")
        return lock.withLock {
            lists.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }.map { list in
                ListMembership(
                    listID: list.id, name: list.name, itemCount: list.items.count,
                    itemID: list.items.first { $0.line == line }?.id
                )
            }
        }
    }

    public func myDishLines(
        query: String?, scoredOnly: Bool, listID: UUID?, after cursor: ListPickerCursor?, limit: Int
    ) async throws -> ListPickerPage {
        try await begin("my_scored_dishes")
        if let query, query.trimmingCharacters(in: .whitespacesAndNewlines).count > ListRules.queryLimit {
            throw ListsError.badInput
        }
        return lock.withLock {
            let clamped = min(PageRequest.maximumLimit, max(1, limit))
            let needle = ListRules.query(query).map(Self.fold)
            let held = Set(lists.first { $0.id == listID }?.items.map(\.line) ?? [])
            let ordered = lines.sorted { Self.key($0) > Self.key($1) }
            let kept = ordered.filter { row in
                if scoredOnly, row.score == nil { return false }
                if let cursor, Self.key(row) >= Self.key(cursor) { return false }
                guard let needle else { return true }
                return Self.fold(row.dishName).contains(needle)
                    || Self.fold(row.restaurantName ?? "").contains(needle)
            }
            let page = kept.prefix(clamped).map { row in
                ListPickerDish(
                    entryID: row.entryID, dishID: row.dishID, dishName: row.dishName, restaurantID: row.restaurantID,
                    restaurantName: row.restaurantName, locality: row.locality, score: row.score,
                    photoURL: row.photoURL, visitedAt: row.visitedAt, inList: held.contains(row.line)
                )
            }
            return ListPickerPage(items: page, requestedLimit: clamped)
        }
    }

    // MARK: - Machinery

    private func begin(_ function: String) async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
        try lock.withLock {
            let index = calls.count
            calls.append(function)
            if let failure = failures.removeValue(forKey: index) { throw failure }
        }
    }

    private func items(of list: StoredList) -> [ListItem] {
        let byLine = Dictionary(lines.map { ($0.line, $0) }, uniquingKeysWith: { first, _ in first })
        return list.items.enumerated().compactMap { offset, item in
            byLine[item.line]?.item(id: item.id, position: offset + 1, addedAt: item.addedAt)
        }
    }

    private func summary(_ list: StoredList) -> UserList {
        let items = items(of: list)
        return UserList(
            id: list.id, name: list.name, itemCount: items.count, covers: ListCovers.of(items),
            createdAt: list.createdAt, updatedAt: list.updatedAt
        )
    }

    private static func key(_ row: ListPickerDish) -> PickerKey {
        PickerKey(visitedAt: row.visitedAt, entry: row.entryID.uuidString, dish: row.dishID.uuidString)
    }

    private static func key(_ cursor: ListPickerCursor) -> PickerKey {
        PickerKey(visitedAt: cursor.visitedAt, entry: cursor.entryID.uuidString, dish: cursor.dishID.uuidString)
    }

    /// `search_key`'s spirit: case- and accent-blind.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}

/// The picker's order as a comparable key: `(visited_at, entry_id, dish_id)`.
private struct PickerKey: Comparable {
    let visitedAt: Date
    let entry: String
    let dish: String

    static func < (lhs: PickerKey, rhs: PickerKey) -> Bool {
        (lhs.visitedAt, lhs.entry, lhs.dish) < (rhs.visitedAt, rhs.entry, rhs.dish)
    }
}
#endif
