import Foundation
import Observation

/// **One list's page** — its dishes in hand order, and every edit that page makes.
///
/// Reorder and remove are optimistic. A remove leaves an Undo behind (the Saved shelf's pattern: put
/// back where it was, offered for one dish at a time). A reorder sends the FULL id array; if the
/// server says the ids no longer match the list (`reorder_mismatch` — an item left on its own, say),
/// the list is read again and the drag reapplied to what is there. Any other refusal puts the old
/// order back. The shelf, when given, is told every new count, cover and name.
@MainActor
@Observable
public final class ListStore {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case empty
        case failed
        /// Deleted, or never yours. The page has nothing to show and should close.
        case gone
    }

    public let listID: UUID
    public private(set) var list: UserList?
    public private(set) var items: [ListItem] = []
    public private(set) var phase: Phase = .loading
    public private(set) var failure: ListsError?
    /// The last dish taken off, while it can still be put back — the Undo pill.
    public private(set) var undoable: ListItem?
    public private(set) var isAdding = false

    @ObservationIgnored private var undoIndex: Int?
    @ObservationIgnored private let service: any ListsServing
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private weak var shelf: ListsStore?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var hasLoaded = false
    /// Bumped by every local edit, so a refusal only rolls back over its own edit.
    @ObservationIgnored private var edits = 0

    public init(
        listID: UUID,
        list: UserList? = nil,
        service: any ListsServing,
        shelf: ListsStore? = nil,
        analytics: @escaping AnalyticsRecorder = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.listID = listID
        self.list = list
        self.service = service
        self.shelf = shelf
        self.analytics = analytics
        self.now = now
    }

    public var name: String { list?.name ?? "" }
    public var count: Int { items.count }
    /// Room for this many more dishes before the 100 cap.
    public var remaining: Int { max(0, ListRules.itemCap - items.count) }
    /// Every line on the list — what the picker leaves out.
    public var lines: Set<DishLine> { Set(items.map(\.line)) }

    public func clearFailure() { failure = nil }

    // MARK: - Loading

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await refresh()
    }

    public func refresh() async {
        let editsAtStart = edits
        if items.isEmpty, phase != .gone { phase = .loading }
        do {
            let detail = try await service.list(id: listID)
            guard editsAtStart == edits else { return }
            adopt(detail)
        } catch {
            guard editsAtStart == edits else { return }
            if ListsError.of(error) == .listNotFound {
                phase = .gone
                shelf?.removed(listID: listID)
            } else if items.isEmpty {
                phase = .failed
            }
        }
    }

    // MARK: - Reorder

    /// A drag ended: `source` rows now sit before the row that was at `destination` (SwiftUI's
    /// `onMove` arguments).
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        let ids = items.map(\.id)
        let moving = source.sorted().filter { ids.indices.contains($0) }.map { ids[$0] }
        guard moving.isEmpty == false else { return }
        var rest = ids.enumerated().filter { source.contains($0.offset) == false }.map(\.element)
        let target = min(rest.count, max(0, destination - source.filter { $0 < destination }.count))
        rest.insert(contentsOf: moving, at: target)
        await reorder(to: rest)
    }

    /// The list in this order — every item id once. Anything else is ignored.
    public func reorder(to ids: [UUID]) async {
        guard ids != items.map(\.id), Set(ids) == Set(items.map(\.id)), Set(ids).count == ids.count else { return }
        let before = items
        apply(order: ids)
        edits += 1
        let editsAtStart = edits
        do {
            try await service.reorder(listID: listID, itemIDs: ids)
            analytics(ListEvents.reordered(listSize: items.count))
        } catch {
            let refusal = ListsError.of(error)
            guard editsAtStart == edits else { return }
            if refusal == .reorderMismatch {
                await reapply(ids)
            } else {
                items = before
                publish()
                failure = refusal
            }
        }
    }

    /// The list moved under the drag: read it again, put what is still there in the dragged order
    /// (anything new goes last), and send that once. If that is refused too, the server's order stands.
    private func reapply(_ wanted: [UUID]) async {
        guard let detail = try? await service.list(id: listID) else {
            failure = .reorderMismatch
            return
        }
        adopt(detail)
        let rank = Dictionary(uniqueKeysWithValues: wanted.enumerated().map { ($1, $0) })
        let order = items.map(\.id).enumerated()
            .sorted { (rank[$0.element] ?? wanted.count + $0.offset) < (rank[$1.element] ?? wanted.count + $1.offset) }
            .map(\.element)
        guard order != items.map(\.id) else { return }
        let fresh = items
        apply(order: order)
        do {
            try await service.reorder(listID: listID, itemIDs: order)
            analytics(ListEvents.reordered(listSize: items.count))
        } catch {
            items = fresh
            publish()
            failure = ListsError.of(error)
        }
    }

    // MARK: - Remove and Undo

    /// The swipe: the row leaves now and ranks close up; it comes back on a refusal. Returns whether
    /// it landed. A landed remove is offered back through ``undoable``.
    @discardableResult
    public func remove(_ item: ListItem) async -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return false }
        settleUndo()
        items.remove(at: index)
        renumber()
        edits += 1
        do {
            try await service.removeItem(itemID: item.id)
            undoable = item
            undoIndex = index
            return true
        } catch {
            items.insert(item, at: min(index, items.count))
            renumber()
            failure = ListsError.of(error)
            return false
        }
    }

    /// **Undo**, straight after a remove: the dish goes back where it was. The server appends a re-add
    /// last (under a new item id), so a dish that was not last is then moved home with a reorder.
    @discardableResult
    public func undoRemove() async -> Bool {
        guard let item = undoable else { return false }
        undoable = nil
        let index = min(undoIndex ?? items.count, items.count)
        undoIndex = nil
        guard items.contains(where: { $0.line == item.line }) == false else { return false }
        items.insert(item, at: index)
        renumber()
        edits += 1
        do {
            let receipt = try await service.addItem(listID: listID, line: item.line)
            if let at = items.firstIndex(where: { $0.id == item.id }) {
                items[at] = items[at].at(position: at + 1, id: receipt.itemID)
            }
            analytics(ListEvents.itemRemoved(listSize: items.count - 1, undone: true))
            if receipt.position != index + 1 {
                do {
                    try await service.reorder(listID: listID, itemIDs: items.map(\.id))
                } catch {
                    await refresh()
                }
            }
            publish()
            return true
        } catch {
            items.removeAll { $0.id == item.id }
            renumber()
            failure = ListsError.of(error)
            return false
        }
    }

    /// The Undo pill timed out. Only the dish it was offered for is let go.
    public func expireUndo(for item: ListItem) {
        guard undoable?.id == item.id else { return }
        settleUndo()
    }

    /// A remove whose Undo is over is counted once, as not undone.
    private func settleUndo() {
        guard undoable != nil else { return }
        analytics(ListEvents.itemRemoved(listSize: items.count, undone: false))
        undoable = nil
        undoIndex = nil
    }

    // MARK: - Add

    /// The picker's "Add N dishes": appended in the order picked, shown at once, sent one at a time.
    /// Lines already on the list are skipped. More than the cap allows is refused whole (`itemCap`);
    /// a refusal part-way keeps what landed and takes back the rest. Returns how many landed.
    @discardableResult
    public func add(_ dishes: [ListPickerDish]) async -> Int {
        var seen = lines
        let fresh = dishes.filter { seen.insert($0.line).inserted }
        guard fresh.isEmpty == false else { return 0 }
        guard items.count + fresh.count <= ListRules.itemCap else {
            failure = .itemCap
            return 0
        }
        isAdding = true
        defer { isAdding = false }
        let added = now()
        let placeholders = fresh.enumerated().map { offset, dish in
            dish.item(id: UUID(), position: items.count + offset + 1, addedAt: added)
        }
        items += placeholders
        edits += 1
        publish()
        var landed = 0
        for placeholder in placeholders {
            do {
                let receipt = try await service.addItem(listID: listID, line: placeholder.line)
                if let at = items.firstIndex(where: { $0.id == placeholder.id }) {
                    items[at] = items[at].at(position: at + 1, id: receipt.itemID)
                }
                landed += 1
            } catch {
                let pending = Set(placeholders.dropFirst(landed).map(\.id))
                items.removeAll { pending.contains($0.id) }
                renumber()
                failure = ListsError.of(error)
                break
            }
        }
        if landed > 0 { analytics(ListEvents.itemAdded(count: landed, from: .picker)) }
        publish()
        return landed
    }

    // MARK: - Rename and delete (the page's ••• menu)

    @discardableResult
    public func rename(to raw: String) async -> Bool {
        guard let name = ListRules.name(raw) else {
            failure = .badName
            return false
        }
        guard let before = list, before.name != name else { return list != nil }
        list = before.with(name: name)
        publish()
        do {
            let renamed = try await service.renameList(id: listID, name: name)
            list = renamed.with(itemCount: items.count, covers: ListCovers.of(items))
            publish()
            analytics(ListEvents.renamed())
            return true
        } catch {
            list = before
            publish()
            failure = ListsError.of(error)
            return false
        }
    }

    /// Deletes the list. The page closes on `true`; the shelf has already let it go.
    @discardableResult
    public func delete() async -> Bool {
        do {
            try await service.deleteList(id: listID)
            analytics(ListEvents.deleted(items: items.count))
            phase = .gone
            shelf?.removed(listID: listID)
            return true
        } catch {
            failure = ListsError.of(error)
            return false
        }
    }

    // MARK: - Machinery

    private func adopt(_ detail: ListDetail) {
        list = detail.list
        items = detail.items
        hasLoaded = true
        renumber()
    }

    private func apply(order ids: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = ids.compactMap { byID[$0] }
        renumber()
    }

    /// Positions are 1…n in array order, always — and the summary follows.
    private func renumber() {
        items = items.enumerated().map { offset, item in
            item.position == offset + 1 ? item : item.at(position: offset + 1)
        }
        publish()
    }

    private func publish() {
        if hasLoaded || items.isEmpty == false { phase = items.isEmpty ? .empty : .ready }
        guard let current = list else { return }
        let summary = current.with(itemCount: items.count, covers: ListCovers.of(items))
        list = summary
        shelf?.updated(summary)
    }
}
