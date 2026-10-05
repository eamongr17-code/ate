import Foundation
import Testing
@testable import AteKit

@MainActor
@Suite("Lists — the dish picker and the Add to a list sheet")
struct ListPickerTests {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func settle(_ store: ListPickerStore) async {
        await store.pending?.value
    }

    @Test("one row per dish, its latest visit; dishes already on the list are left out")
    func dedupeAndExclude() async {
        let ragu = UUID()
        let lines = [
            pickerLine("Ragu", score: 4.5, daysAgo: 1, dishID: ragu),
            pickerLine("Ragu", score: 3.0, daysAgo: 9, dishID: ragu),
            pickerLine("Tiramisu", score: 3.0, daysAgo: 2),
            pickerLine("Croissant", score: 5, daysAgo: 3),
            pickerLine("Lobster roll", score: nil, daysAgo: 4)
        ]
        let service = InMemoryLists(lines: lines)
        let id = service.seed(name: "Best", lines: [lines[3].line], createdAt: base)
        let store = ListPickerStore(
            service: service, listID: id, excluding: [lines[3].line], debounce: .milliseconds(5)
        )
        await store.start()
        #expect(store.rows.map(\.dishName) == ["Ragu", "Tiramisu", "Lobster roll"])
        #expect(store.rows.first?.score == Rating(exactly: 4.5), "the latest score")
        #expect(store.rows.last?.score == nil, "unscored dishes show, with their empty star")
    }

    @Test("a dish flagged in_list by the server is left out even when the page did not pass it")
    func inListFromServer() async {
        let lines = [pickerLine("Ragu", daysAgo: 1), pickerLine("Tiramisu", daysAgo: 2)]
        let service = InMemoryLists(lines: lines)
        let id = service.seed(name: "Best", lines: [lines[1].line], createdAt: base)
        let store = ListPickerStore(service: service, listID: id, debounce: .milliseconds(5))
        await store.start()
        #expect(store.rows.map(\.dishName) == ["Ragu"])
    }

    @Test("the query is debounced, under two characters is no filter, and matches dish or place")
    func debounce() async {
        let lines = [
            pickerLine("Smash burger", place: "Rockwell & Sons", daysAgo: 1),
            pickerLine("Ragu", place: "Tipo 00", daysAgo: 2),
            pickerLine("Fries", place: "Burger Project", daysAgo: 3)
        ]
        let service = InMemoryLists(lines: lines)
        let store = ListPickerStore(service: service, listID: nil, debounce: .milliseconds(30))
        await store.start()
        #expect(store.rows.count == 3)
        store.setQuery("b")
        store.setQuery("bu")
        store.setQuery("bur")
        await settle(store)
        #expect(service.calls.filter { $0 == "my_scored_dishes" }.count == 2, "one read for three keystrokes")
        #expect(store.rows.map(\.dishName) == ["Smash burger", "Fries"])
        store.setQuery("b")
        await settle(store)
        #expect(store.rows.count == 3, "one character is the whole record again")
        store.setQuery(" b ")
        await settle(store)
        #expect(service.calls.filter { $0 == "my_scored_dishes" }.count == 3, "the same effective query asks nothing")
    }

    @Test("a long query is cut to 100 characters, never refused")
    func longQuery() async {
        let service = InMemoryLists(lines: [pickerLine("Ragu", daysAgo: 1)])
        let store = ListPickerStore(service: service, listID: nil, debounce: .milliseconds(1))
        store.setQuery(String(repeating: "r", count: 150))
        await settle(store)
        #expect(store.effectiveQuery?.count == 100)
        #expect(store.phase == .empty)
    }

    @Test("pages on the three-part keyset with no dish twice")
    func paging() async {
        let lines = (0..<25).map { pickerLine("Dish \($0)", daysAgo: $0) }
        let service = InMemoryLists(lines: lines)
        let store = ListPickerStore(service: service, listID: nil, pageSize: 10, debounce: .milliseconds(1))
        await store.start()
        #expect(store.rows.count == 10)
        await store.loadMore()
        await store.loadMore()
        #expect(store.rows.count == 25 && store.hasReachedEnd)
        #expect(store.rows.map(\.dishName) == lines.map(\.dishName))
    }

    @Test("ticks keep their order, untick, and stop at the list's room")
    func selection() async {
        let lines = (0..<4).map { pickerLine("Dish \($0)", daysAgo: $0) }
        let store = ListPickerStore(service: InMemoryLists(lines: lines), listID: nil, room: 2)
        await store.start()
        #expect(store.toggle(store.rows[2]))
        #expect(store.toggle(store.rows[0]))
        #expect(store.selection.map(\.dishName) == ["Dish 2", "Dish 0"])
        #expect(store.toggle(store.rows[1]) == false)
        #expect(store.failure == .itemCap)
        #expect(store.toggle(store.rows[2]))
        #expect(store.selection.map(\.dishName) == ["Dish 0"])
    }

    // MARK: - Add to a list

    @Test("every list, ticked where it holds the line; a tick adds, an untick removes")
    func addToList() async throws {
        let lines = [pickerLine("Ragu", daysAgo: 1), pickerLine("Tiramisu", daysAgo: 2)]
        let service = InMemoryLists(lines: lines)
        let pasta = service.seed(name: "Pasta", lines: [lines[0].line], createdAt: base)
        let date = service.seed(name: "Date night", lines: [], createdAt: base.addingTimeInterval(10))
        let shelf = ListsStore(service: service)
        await shelf.refresh()
        let log = EventLog()
        let store = AddToListStore(line: lines[0].line, service: service, shelf: shelf, analytics: log.recorder)
        await store.load()
        #expect(store.lists.map(\.name) == ["Date night", "Pasta"])
        #expect(store.lists.map(\.contains) == [false, true])
        #expect(await store.toggle(store.lists[0]))
        #expect(store.containingCount == 2)
        #expect(try await service.list(id: date).items.map(\.line) == [lines[0].line])
        #expect(shelf.lists.first { $0.id == date }?.itemCount == 1)
        #expect(await store.toggle(store.lists[1]))
        #expect(try await service.list(id: pasta).items.isEmpty)
        #expect(log.names == ["list_item_added", "list_item_removed"])
        #expect(log.first(named: "list_item_added")?.parameters["from"] == "sheet")
    }

    @Test("a refused tick unticks again, and a full list names the cap")
    func addToListRollback() async {
        let lines = (0..<101).map { pickerLine("D\($0)", daysAgo: $0) }
        let service = InMemoryLists(lines: lines)
        service.seed(name: "Full", lines: lines.prefix(100).map(\.line), createdAt: base)
        service.seed(name: "Open", lines: [], createdAt: base.addingTimeInterval(10))
        let store = AddToListStore(line: lines[100].line, service: service)
        await store.load()
        service.failNext(.unreachable)
        #expect(await store.toggle(store.lists[0]) == false)
        #expect(store.lists[0].contains == false && store.failure == .unreachable)
        #expect(await store.toggle(store.lists[1]) == false)
        #expect(store.failure == .itemCap)
    }

    @Test("New list from the sheet: made, ticked, on top of the shelf too")
    func addToNewList() async {
        let lines = [pickerLine("Ragu", daysAgo: 1)]
        let service = InMemoryLists(lines: lines)
        let shelf = ListsStore(service: service)
        await shelf.refresh()
        let store = AddToListStore(line: lines[0].line, service: service, shelf: shelf)
        await store.load()
        #expect(await store.createList(named: "Pasta"))
        #expect(store.lists.map(\.name) == ["Pasta"] && store.lists[0].contains)
        #expect(shelf.lists.map(\.name) == ["Pasta"] && shelf.lists[0].itemCount == 1)
    }
}
