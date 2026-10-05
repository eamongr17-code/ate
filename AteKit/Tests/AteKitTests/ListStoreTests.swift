import Foundation
import Testing
@testable import AteKit

@MainActor
@Suite("Lists — one list")
struct ListStoreTests {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private struct Fixture {
        let service: InMemoryLists
        let store: ListStore
        let shelf: ListsStore
        let lines: [ListPickerDish]
    }

    /// A list holding `count` of `count + spare` lines, and the store open on it.
    private func fixture(count: Int = 5, spare: Int = 3) async -> Fixture {
        let lines = (0..<(count + spare)).map { pickerLine("Dish \($0)", daysAgo: $0, photo: "p\($0)") }
        let service = InMemoryLists(lines: lines)
        let id = service.seed(name: "Burgers", lines: lines.prefix(count).map(\.line), createdAt: base)
        let shelf = ListsStore(service: service)
        await shelf.refresh()
        let store = ListStore(listID: id, service: service, shelf: shelf)
        await store.refresh()
        return Fixture(service: service, store: store, shelf: shelf, lines: lines)
    }

    @Test("loads the list in order, positions 1…n")
    func load() async {
        let fixture = await fixture()
        let store = fixture.store
        #expect(store.items.map(\.dishName) == ["Dish 0", "Dish 1", "Dish 2", "Dish 3", "Dish 4"])
        #expect(store.items.map(\.position) == [1, 2, 3, 4, 5])
        #expect(store.name == "Burgers" && store.phase == .ready)
    }

    @Test("a drag sends the FULL ordered id array; positions stay 1…n")
    func reorderIntegrity() async throws {
        let fixture = await fixture()
        let service = fixture.service
        let store = fixture.store
        let ids = store.items.map(\.id)
        // Drag the last row to the top.
        await store.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        let expected = [ids[4], ids[0], ids[1], ids[2], ids[3]]
        #expect(store.items.map(\.id) == expected)
        #expect(store.items.map(\.position) == [1, 2, 3, 4, 5])
        #expect(service.lastReorder == expected)
        #expect(service.itemIDs(listID: store.listID) == expected)
        // Drag the first row down past two: SwiftUI's destination counts the row's own slot.
        await store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.items.map(\.id) == [ids[0], ids[1], ids[4], ids[2], ids[3]])
        #expect(Set(try #require(service.lastReorder)) == Set(ids))
    }

    @Test("a refused reorder puts the old order back")
    func reorderRollback() async {
        let fixture = await fixture()
        let service = fixture.service
        let store = fixture.store
        let before = store.items.map(\.id)
        service.failNext(.unreachable)
        await store.move(fromOffsets: IndexSet(integer: 0), toOffset: 5)
        #expect(store.items.map(\.id) == before)
        #expect(store.failure == .unreachable)
    }

    @Test("reorder_mismatch: read again and reapply the drag to what is there")
    func reorderMismatch() async throws {
        let fixture = await fixture()
        let service = fixture.service
        let store = fixture.store
        let lines = fixture.lines
        let ids = store.items.map(\.id)
        // Dish 2 left the list on its own (its visit was re-sorted) while the page still showed it.
        service.removeLine(lines[2].line)
        await store.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(store.items.map(\.id) == [ids[4], ids[0], ids[1], ids[3]])
        #expect(service.itemIDs(listID: store.listID) == [ids[4], ids[0], ids[1], ids[3]])
        #expect(store.failure == nil)
    }

    @Test("a remove leaves at once, ranks close up, and Undo puts it back in its own place")
    func removeAndUndo() async throws {
        let fixture = await fixture()
        let service = fixture.service
        let store = fixture.store
        let shelf = fixture.shelf
        let log = EventLog()
        let logged = ListStore(listID: store.listID, service: service, shelf: shelf, analytics: log.recorder)
        await logged.refresh()
        let second = logged.items[1]
        #expect(await logged.remove(second))
        #expect(logged.items.map(\.dishName) == ["Dish 0", "Dish 2", "Dish 3", "Dish 4"])
        #expect(logged.items.map(\.position) == [1, 2, 3, 4])
        #expect(logged.undoable == second)
        #expect(shelf.lists.first?.itemCount == 4, "the shelf follows")
        #expect(await logged.undoRemove())
        #expect(logged.items.map(\.dishName) == ["Dish 0", "Dish 1", "Dish 2", "Dish 3", "Dish 4"])
        #expect(logged.undoable == nil)
        let server = try await service.list(id: store.listID).items.map(\.dishName)
        #expect(server == ["Dish 0", "Dish 1", "Dish 2", "Dish 3", "Dish 4"], "moved home on the server too")
        #expect(logged.items.map(\.id) == service.itemIDs(listID: store.listID), "the re-added id is the server's")
        #expect(log.first(named: "list_item_removed")?.parameters["undone"] == "true")
        #expect(shelf.lists.first?.itemCount == 5)
    }

    @Test("an Undo is offered for one dish at a time; its clock only lets go of its own")
    func undoExpiry() async {
        let fixture = await fixture()
        let store = fixture.store
        let first = store.items[0]
        let second = store.items[1]
        await store.remove(first)
        await store.remove(second)
        #expect(store.undoable == second)
        store.expireUndo(for: first)
        #expect(store.undoable == second)
        store.expireUndo(for: second)
        #expect(store.undoable == nil)
        #expect(await store.undoRemove() == false)
    }

    @Test("a refused remove puts the row back; nothing is offered")
    func removeRollback() async {
        let fixture = await fixture()
        let service = fixture.service
        let store = fixture.store
        let target = store.items[2]
        service.failNext(.unreachable)
        #expect(await store.remove(target) == false)
        #expect(store.items[2] == target && store.items.count == 5)
        #expect(store.undoable == nil && store.failure == .unreachable)
    }

    @Test("adds append in the order picked, take the server's ids, and skip lines already there")
    func add() async {
        let fixture = await fixture()
        let service = fixture.service
        let store = fixture.store
        let lines = fixture.lines
        let log = EventLog()
        let logged = ListStore(listID: store.listID, service: service, analytics: log.recorder)
        await logged.refresh()
        let landed = await logged.add([lines[7], lines[0], lines[5]])
        #expect(landed == 2)
        #expect(logged.items.suffix(2).map(\.dishName) == ["Dish 7", "Dish 5"])
        #expect(logged.items.map(\.id) == service.itemIDs(listID: store.listID))
        #expect(log.first(named: "list_item_added")?.parameters["count"] == "2")
    }

    @Test("more than the 100 cap allows is refused whole, before asking")
    func addCap() async {
        let lines = (0..<102).map { pickerLine("D\($0)", daysAgo: $0) }
        let service = InMemoryLists(lines: lines)
        let id = service.seed(name: "Full", lines: lines.prefix(99).map(\.line), createdAt: base)
        let store = ListStore(listID: id, service: service)
        await store.refresh()
        #expect(store.remaining == 1)
        #expect(await store.add([lines[100], lines[101]]) == 0)
        #expect(store.failure == .itemCap && store.items.count == 99)
        #expect(service.calls.contains("add_list_item") == false)
    }

    @Test("a refusal part-way keeps what landed and takes back the rest")
    func addPartial() async {
        let fixture = await fixture()
        let service = fixture.service
        let store = fixture.store
        let lines = fixture.lines
        // The second add is refused.
        service.failNext(.itemCap, after: 1)
        let landed = await store.add([lines[5], lines[6], lines[7]])
        #expect(landed == 1)
        #expect(store.items.map(\.dishName).suffix(2) == ["Dish 4", "Dish 5"])
        #expect(store.items.map(\.id) == service.itemIDs(listID: store.listID))
        #expect(store.failure == .itemCap)
    }

    @Test("a deleted list reads as gone and leaves the shelf")
    func gone() async {
        let fixture = await fixture()
        let service = fixture.service
        let store = fixture.store
        let shelf = fixture.shelf
        try? await service.deleteList(id: store.listID)
        await store.refresh()
        #expect(store.phase == .gone)
        #expect(shelf.lists.isEmpty)
    }

    @Test("rename and delete from the page's menu reach the shelf")
    func renameDelete() async {
        let fixture = await fixture()
        let store = fixture.store
        let shelf = fixture.shelf
        #expect(await store.rename(to: "Best burgers"))
        #expect(store.name == "Best burgers" && shelf.lists.first?.name == "Best burgers")
        #expect(await store.delete())
        #expect(store.phase == .gone && shelf.lists.isEmpty)
    }
}
