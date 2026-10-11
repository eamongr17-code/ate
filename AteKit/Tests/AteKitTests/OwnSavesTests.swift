import Foundation
import Synchronization
import Testing
@testable import AteKit

private let tipo = UUID()
private let base = Date(timeIntervalSince1970: 1_790_000_000)

private func own(_ name: String, minutesAgo: Double, source: OwnSaveSource = .manual) -> OwnSave {
    OwnSave(
        id: UUID(), dishName: name, restaurantID: tipo, restaurantName: "Tipo 00", source: source,
        createdAt: base.addingTimeInterval(-minutesAgo * 60)
    )
}

private func ate(_ name: String, minutesAgo: Double) -> SavedDish {
    SavedDish(
        dishID: UUID(), dishName: name, restaurantID: tipo, restaurantName: "Tipo 00", dishScore: 4.5,
        savedAt: base.addingTimeInterval(-minutesAgo * 60)
    )
}

@Suite("Own saves — the link, the draft")
struct OwnSaveSourceTests {
    @Test("a link's host decides where it came from", arguments: [
        ("https://www.tiktok.com/@sydneyeats/video/7300000000000000000", OwnSaveSource.tiktok),
        ("https://vm.tiktok.com/ZMabc123/", .tiktok),
        ("https://www.instagram.com/reel/C1abc/?igsh=xyz", .instagram),
        ("https://instagr.am/p/abc", .instagram),
        ("https://www.broadsheet.com.au/melbourne/food-and-drink", .link),
        ("https://nottiktok.com/x", .link),
        ("http://www.tiktok.com/@x/video/1", .manual),
        ("tiktok.com/@x", .manual),
        ("", .manual)
    ])
    func source(link: String, expected: OwnSaveSource) {
        #expect(OwnSaveSource.of(link: link) == expected)
    }

    @Test("no link is typed by hand")
    func noLink() {
        #expect(OwnSaveSource.of(link: nil) == .manual)
    }

    @Test("the dish name is trimmed, 1 to 120 characters; the link is https or nothing")
    func draft() {
        var draft = OwnSaveDraft(dishName: "  Crab fried rice ", restaurantID: tipo, restaurantName: "Ho Jiak")
        #expect(draft.trimmedDishName == "Crab fried rice")
        #expect(draft.cleanLink == nil)
        draft.link = " https://vm.tiktok.com/ZMabc/ "
        #expect(draft.cleanLink == "https://vm.tiktok.com/ZMabc/")
        #expect(draft.source == .tiktok)
        draft.dishName = "   "
        #expect(draft.trimmedDishName == nil)
        draft.dishName = String(repeating: "x", count: 121)
        #expect(draft.trimmedDishName == nil)
    }

    @Test("decodes the view's row")
    func decoding() throws {
        let json = Data("""
        [{"id":"7a0c0b7e-2f7b-4b38-9a77-3a2f7b0c0b7e","dish_name":"Crab fried rice",
          "restaurant_id":"1b0c0b7e-2f7b-4b38-9a77-3a2f7b0c0b7e","restaurant_name":"Ho Jiak",
          "restaurant_city":"Sydney","source":"tiktok","source_url":"https://www.tiktok.com/@x/video/1",
          "source_author":"@x","source_caption":null,"created_at":"2026-10-11T06:00:00.123456+00:00"}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([OwnSave].self, from: json)
        #expect(rows.first?.source == .tiktok)
        #expect(rows.first?.restaurantCity == "Sydney")
        #expect(rows.first?.sourceCaption == nil)
    }
}

@Suite("Own saves — the shelf, both kinds in one order")
struct SavedShelfTests {
    @Test("newest first across both kinds")
    func merged() {
        let rows = SavedShelf.rows(
            ate: [ate("Gnocchi", minutesAgo: 5), ate("Tiramisu", minutesAgo: 30)],
            own: [own("Crab fried rice", minutesAgo: 1), own("Pho", minutesAgo: 10)],
            ateHasReachedEnd: true
        )
        let names = rows.map { row -> String in
            switch row {
            case .ate(let dish): dish.dishName
            case .own(let save): save.dishName
            }
        }
        #expect(names == ["Crab fried rice", "Gnocchi", "Pho", "Tiramisu"])
    }

    @Test("an own save older than the last Ate row loaded waits for the next page")
    func waitsForThePage() {
        let ateRows = [ate("Gnocchi", minutesAgo: 5)]
        let old = own("Pho", minutesAgo: 60)
        #expect(SavedShelf.rows(ate: ateRows, own: [old], ateHasReachedEnd: false).count == 1)
        #expect(SavedShelf.rows(ate: ateRows, own: [old], ateHasReachedEnd: true).count == 2)
        #expect(SavedShelf.rows(ate: [], own: [old], ateHasReachedEnd: false).count == 1, "no Ate saves: all of yours")
    }
}

@MainActor
@Suite("Own saves — the store")
struct OwnSavesStoreTests {
    @Test("add reads back the server's place; remove is at once and undoes")
    func addRemoveUndo() async throws {
        let service = InMemoryOwnSaves(places: [tipo: .init(name: "Tipo 00", city: "Melbourne")])
        let sent = Mutex<[AnalyticsEvent]>([])
        let store = OwnSavesStore(service: service, analytics: { event in sent.withLock { $0.append(event) } })
        await store.loadIfNeeded()
        #expect(store.hasLoaded)
        #expect(store.saves.isEmpty)

        let made = await store.add(
            OwnSaveDraft(dishName: "Pho", restaurantID: tipo, restaurantName: "Tipo", link: "https://vm.tiktok.com/a"),
            from: .saved
        )
        #expect(made)
        let save = try #require(store.saves.first)
        #expect(save.restaurantName == "Tipo 00")
        #expect(save.restaurantCity == "Melbourne")
        #expect(save.source == .tiktok)
        #expect(sent.withLock { $0 }.contains(OwnSaveEvents.added(source: .tiktok, origin: .saved)))

        await store.remove(save)
        #expect(store.saves.isEmpty)
        #expect(store.undoable == save)
        await store.undoRemove()
        #expect(store.saves.map(\.dishName) == ["Pho"])
        #expect(store.undoable == nil)
    }

    @Test("a refused remove puts the dish back")
    func refusedRemove() async {
        let service = InMemoryOwnSaves(rows: [own("Pho", minutesAgo: 1)])
        let store = OwnSavesStore(service: service)
        await store.refresh()
        await service.failNextWrite()
        await store.remove(store.saves[0])
        #expect(store.saves.count == 1)
        #expect(store.undoable == nil)
    }

    @Test("a refused add says so and adds nothing")
    func refusedAdd() async {
        let service = InMemoryOwnSaves()
        let store = OwnSavesStore(service: service)
        await service.failNextWrite()
        let draft = OwnSaveDraft(dishName: "Pho", restaurantID: tipo, restaurantName: "Tipo")
        let made = await store.add(draft, from: .saved)
        #expect(made == false)
        #expect(store.saves.isEmpty)
    }

    @Test("I ate it: once the entry is saved, the dish leaves Saved")
    func fulfil() async throws {
        let pho = own("Pho", minutesAgo: 1, source: .instagram)
        let service = InMemoryOwnSaves(rows: [pho, own("Laksa", minutesAgo: 2)])
        let sent = Mutex<[AnalyticsEvent]>([])
        let store = OwnSavesStore(service: service, analytics: { event in sent.withLock { $0.append(event) } })
        await store.refresh()
        await store.fulfil(id: pho.id)
        #expect(store.saves.map(\.dishName) == ["Laksa"])
        #expect(try await service.ownSaves().count == 1)
        #expect(sent.withLock { $0 } == [OwnSaveEvents.eaten(source: .instagram)])
    }
}
