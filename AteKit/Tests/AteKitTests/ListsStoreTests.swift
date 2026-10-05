import Foundation
import Testing
@testable import AteKit

/// A dish line for the in-memory service: newest first by `daysAgo`.
func pickerLine(
    _ name: String, place: String = "Tipo 00", score: Double? = 4.5, daysAgo: Int, entryID: UUID = UUID(),
    dishID: UUID = UUID(), photo: String? = nil
) -> ListPickerDish {
    ListPickerDish(
        entryID: entryID, dishID: dishID, dishName: name, restaurantID: UUID(), restaurantName: place,
        locality: "CBD", score: score.flatMap { Rating(exactly: $0) }, photoURL: photo,
        visitedAt: Date(timeIntervalSince1970: 1_789_812_840 - Double(daysAgo) * 86_400)
    )
}

private let base = Date(timeIntervalSince1970: 1_790_000_000)

@MainActor
@Suite("Lists — the shelf")
struct ListsStoreTests {
    @Test("the preview has three lists, the burgers with six dishes, and one empty")
    func preview() async throws {
        let service = InMemoryLists.preview()
        let store = ListsStore(service: service)
        await store.loadIfNeeded()
        #expect(store.lists.count == 3)
        let burgers = try #require(store.lists.first { $0.name == "Melbourne\u{2019}s best burgers" })
        #expect(burgers.itemCount == 6)
        #expect(store.lists.contains { $0.itemCount == 0 })
        #expect(store.lists.first?.name == "Date night", "newest made first")
        #expect(try await service.list(id: burgers.id).items.count == 6)
    }

    @Test("pages on the keyset with nothing twice, and stops at a short page")
    func paging() async {
        let service = InMemoryLists()
        for index in 0..<7 {
            service.seed(name: "List \(index)", lines: [], createdAt: base.addingTimeInterval(Double(index)))
        }
        let store = ListsStore(service: service, pageSize: 3)
        await store.refresh()
        #expect(store.lists.map(\.name) == ["List 6", "List 5", "List 4"])
        await store.loadMore()
        await store.loadMore()
        #expect(store.lists.count == 7 && Set(store.lists.map(\.id)).count == 7)
        #expect(store.hasReachedEnd)
        #expect(service.calls.filter { $0 == "my_lists" }.count == 3)
    }

    @Test("a new list shows at once on top, then takes the server's id; counted once")
    func create() async throws {
        let service = InMemoryLists(latency: .milliseconds(40))
        let log = EventLog()
        let store = ListsStore(service: service, analytics: log.recorder)
        await store.refresh()
        #expect(store.phase == .empty)
        let task = Task { await store.create(name: "  Pho  ") }
        try await Task.sleep(for: .milliseconds(10))
        #expect(store.lists.map(\.name) == ["Pho"])
        #expect(store.isPending(store.lists[0]))
        let created = try #require(await task.value)
        #expect(store.lists.map(\.id) == [created.id])
        #expect(store.pendingIDs.isEmpty && store.phase == .ready)
        #expect(log.names == ["list_created"])
    }

    @Test("a refused create leaves nothing behind and names the cap")
    func createCap() async {
        let service = InMemoryLists()
        let store = ListsStore(service: service)
        await store.refresh()
        service.failNext(.listCap)
        #expect(await store.create(name: "Fifty-first") == nil)
        #expect(store.lists.isEmpty && store.phase == .empty)
        #expect(store.failure == .listCap && store.failure?.isCap == true)
    }

    @Test("the 50-list cap is refused before asking when the whole shelf is known")
    func createCapLocally() async {
        let service = InMemoryLists()
        for index in 0..<ListRules.listCap {
            service.seed(name: "L\(index)", lines: [], createdAt: base.addingTimeInterval(Double(index)))
        }
        let store = ListsStore(service: service, pageSize: 50)
        await store.refresh()
        await store.loadMore()
        #expect(store.hasReachedEnd)
        #expect(await store.create(name: "One more") == nil)
        #expect(store.failure == .listCap)
        #expect(service.calls.contains("create_list") == false)
    }

    @Test("an empty name is refused without asking")
    func badName() async {
        let service = InMemoryLists()
        let store = ListsStore(service: service)
        #expect(await store.create(name: "   ") == nil)
        #expect(store.failure == .badName && service.calls.isEmpty)
    }

    @Test("a rename shows at once and rolls back on a refusal")
    func rename() async throws {
        let service = InMemoryLists()
        service.seed(name: "Burgers", lines: [], createdAt: base)
        let log = EventLog()
        let store = ListsStore(service: service, analytics: log.recorder)
        await store.refresh()
        let list = try #require(store.lists.first)
        #expect(await store.rename(list, to: "Best burgers"))
        #expect(store.lists.first?.name == "Best burgers")
        service.failNext(.unreachable)
        #expect(await store.rename(try #require(store.lists.first), to: "Worst burgers") == false)
        #expect(store.lists.first?.name == "Best burgers")
        #expect(store.failure == .unreachable)
        #expect(log.names == ["list_renamed"])
    }

    @Test("a delete leaves at once and comes back where it was on a refusal")
    func delete() async throws {
        let service = InMemoryLists()
        for index in 0..<3 {
            service.seed(name: "L\(index)", lines: [], createdAt: base.addingTimeInterval(Double(index)))
        }
        let log = EventLog()
        let store = ListsStore(service: service, analytics: log.recorder)
        await store.refresh()
        let middle = store.lists[1]
        service.failNext(.unreachable)
        #expect(await store.delete(middle) == false)
        #expect(store.lists.map(\.name) == ["L2", "L1", "L0"])
        #expect(await store.delete(middle))
        #expect(store.lists.map(\.name) == ["L2", "L0"])
        #expect(log.first(named: "list_deleted")?.parameters["items"] == "0")
    }
}
