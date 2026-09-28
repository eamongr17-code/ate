import Foundation
import Testing
@testable import AteKit

@Suite("Feed area")
struct FeedAreaTests {
    @MainActor
    @Test("Changing area starts the list again from nothing, and reads the new area")
    func reloadForArea() async {
        let areas = AreaBox()
        let store = EntryListStore(fallbackMessage: "x") { _, size in
            let area = await areas.value
            return Page(
                items: area == nil ? [BrowseFixtures.card(1), BrowseFixtures.card(2)] : [BrowseFixtures.card(3)],
                requestedLimit: size
            )
        }
        await store.loadIfNeeded()
        #expect(store.entries.count == 2)
        await areas.set("Carlton")
        await store.reload()
        #expect(store.entries.count == 1)
        #expect(store.phase == .ready)
        #expect(store.pagesLoaded == 1)
    }

    @Test("The in-memory feed filters by area, and everywhere is everything")
    func filter() async throws {
        let social = InMemorySocialService(entries: [
            BrowseFixtures.card(1, city: "Melbourne"), BrowseFixtures.card(2, city: "Sydney")
        ])
        let everywhere = try await social.feedPage(after: nil, pageSize: 10, includeOwn: false, area: nil)
        let sydney = try await social.feedPage(after: nil, pageSize: 10, includeOwn: false, area: "Sydney")
        #expect(everywhere.items.count == 2)
        #expect(sydney.items.count == 1)
    }
}

@MainActor
private final class AreaBox {
    var value: String?
    func set(_ area: String?) { value = area }
}
