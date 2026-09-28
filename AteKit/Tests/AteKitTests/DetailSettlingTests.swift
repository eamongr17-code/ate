import Foundation
import Testing
@testable import AteKit

/// Staged loading: a detail page settles once, and a refresh never takes it back to the skeleton.
@MainActor
@Suite("Detail pages settle")
struct DetailSettlingTests {
    @Test("a dish page settles only once its header and first reviews are both in")
    func dishSettles() async throws {
        let social = InMemorySocialService.seededWithSaves()
        let tipo = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!
        let dishID = try #require(try await social.placeDishes(restaurantID: tipo, after: nil, pageSize: 5).items.first)
            .dishID
        let store = DishPageStore(dishID: dishID, source: .unknown, dishes: social)
        #expect(store.isSettled == false)
        await store.load()
        #expect(store.isSettled)
    }

    @Test("a place page settles once header, menu and both visit lists are in")
    func placeSettles() async {
        let social = InMemorySocialService.seededWithSaves()
        let tipo = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!
        let store = PlacePageStore(restaurantID: tipo, source: .unknown, places: social)
        #expect(store.isSettled == false)
        await store.load()
        #expect(store.isSettled)
    }

    /// A place and a dish with nothing written about them, whose lists answer slowly once told to —
    /// so a refresh can be caught with its empty list back in `.loading`.
    final class EmptyDetail: PlacePageReading, DishPageReading, TestFake, @unchecked Sendable {
        let placeID = UUID()
        let dishID = UUID()
        private let lock = NSLock()
        private var slowFlag = false
        var slow: Bool {
            get { lock.withLock { slowFlag } }
            set { lock.withLock { slowFlag = newValue } }
        }

        private func pause() async {
            if slow { try? await Task.sleep(for: .milliseconds(300)) }
        }

        func placeSummary(restaurantID: UUID) async throws -> PlaceSummary {
            PlaceSummary(restaurantID: placeID, name: "Nowhere")
        }
        func placeDishes(restaurantID: UUID, after cursor: MenuDishCursor?, pageSize: Int) async throws
            -> MenuDishPage { MenuDishPage(items: [], nextCursor: nil) }
        func entriesAtPlace(
            restaurantID: UUID, scope: PlaceEntryScope, after cursor: PageCursor?, pageSize: Int
        ) async throws -> Page<EntryCard> {
            await pause()
            return Page(items: [], requestedLimit: pageSize)
        }
        func dishSummary(dishID: UUID) async throws -> DishSummary {
            DishSummary(dishID: dishID, name: "Nothing", restaurantID: placeID, restaurantName: "Nowhere")
        }
        func dishReviews(dishID: UUID, after cursor: DishReviewCursor?, pageSize: Int) async throws
            -> DishReviewPage {
            await pause()
            return DishReviewPage(items: [], nextCursor: nil)
        }
    }

    @Test("a place with no visits stays settled through a pull to refresh — never back to the skeleton")
    func placeRefreshKeepsSettled() async throws {
        let reader = EmptyDetail()
        let store = PlacePageStore(restaurantID: reader.placeID, places: reader)
        await store.load()
        #expect(store.isSettled)
        reader.slow = true
        let refresh = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.entries.phase == .loading, "the empty list is back in the air")
        #expect(store.isSettled)
        await refresh.value
        #expect(store.isSettled)
    }

    @Test("a dish with no reviews stays settled through a pull to refresh")
    func dishRefreshKeepsSettled() async throws {
        let reader = EmptyDetail()
        let store = DishPageStore(dishID: reader.dishID, dishes: reader)
        await store.load()
        #expect(store.isSettled)
        reader.slow = true
        let refresh = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.phase == .loading, "the empty list is back in the air")
        #expect(store.isSettled)
        await refresh.value
        #expect(store.isSettled)
    }
}
