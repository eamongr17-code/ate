import Foundation
import Testing

@testable import AteKit

@Suite("Drafts + receipt (§7, §5.2)")
struct LogDraftTests {
    private static let restaurant = SittingRestaurant(
        id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
        name: "Chin Chin",
        suburb: "Melbourne"
    )

    private func draft(dishCount: Int, rated: Bool, savedAt: Date = Date()) -> LogDraft {
        var state = SittingState(restaurant: Self.restaurant)
        for index in 0..<dishCount {
            state.add(dishID: UUID(), dishName: "Dish \(index)")
            if rated { state.setScore(Rating(rounding: 4), for: state.dishes[index].id) }
        }
        return LogDraft(sitting: state, savedAt: savedAt)
    }

    // MARK: - Draft

    @Test("§7 a draft expires after 7 days")
    func expiry() {
        let now = Date()
        #expect(draft(dishCount: 1, rated: true, savedAt: now.addingTimeInterval(-60 * 60 * 24 * 6))
            .isExpired(now: now) == false)
        #expect(draft(dishCount: 1, rated: true, savedAt: now.addingTimeInterval(-60 * 60 * 24 * 8))
            .isExpired(now: now))
    }

    @Test("age_minutes drives log_draft_resumed")
    func ageMinutes() {
        let now = Date()
        #expect(draft(dishCount: 1, rated: true, savedAt: now.addingTimeInterval(-20 * 60))
            .ageMinutes(now: now) == 20)
    }

    @Test("only a sitting with content is worth keeping — or one with a post to retry")
    func worthKeeping() {
        #expect(draft(dishCount: 1, rated: false).isWorthKeeping == false)
        #expect(draft(dishCount: 1, rated: true).isWorthKeeping)

        var pending = draft(dishCount: 1, rated: false)
        pending.needsPostRetry = true
        #expect(pending.isWorthKeeping)
    }

    @Test("the Continue row's summary pluralises", arguments: [(1, "1 dish"), (2, "2 dishes")])
    func summary(count: Int, expected: String) {
        #expect(draft(dishCount: count, rated: true).dishCountSummary == expected)
    }

    @Test("an expired draft is never handed back by the store")
    func storeDropsExpired() {
        let stale = draft(dishCount: 1, rated: true, savedAt: Date().addingTimeInterval(-60 * 60 * 24 * 9))
        let store = InMemoryLogDraftStore(draft: stale)
        #expect(store.load() == nil)
    }

    @Test("saving a second sitting silently replaces the first — one draft, maximum")
    func oneDraftMaximum() throws {
        let store = InMemoryLogDraftStore()
        let first = draft(dishCount: 1, rated: true)
        let second = draft(dishCount: 2, rated: true)
        store.save(first)
        store.save(second)
        #expect(try #require(store.load()).id == second.id)
        store.clear(draftID: second.id)
        #expect(store.load() == nil)
    }

    @Test("a draft round-trips through JSON with its ratings, notes and photo state intact")
    func codableRoundTrip() throws {
        // Whole seconds: the draft persists as ISO-8601, which carries no sub-second precision.
        let savedAt = Date(timeIntervalSince1970: 1_756_700_000)
        var state = SittingState(restaurant: Self.restaurant, startedAt: savedAt)
        state.add(dishID: UUID(), dishName: "Betel Leaf")
        state.setScore(Rating(rounding: 4.5), for: state.dishes[0].id)
        state.setNote("crunchy", for: state.dishes[0].id)
        state.setPhoto(SittingPhoto(localFileName: "a.jpg"), for: state.dishes[0].id)
        let original = LogDraft(
            sitting: state,
            savedAt: savedAt,
            postedReviewIDs: [UUID()],
            needsPostRetry: true
        )

        let decoded = try JSONDecoder.ate.decode(
            LogDraft.self, from: try JSONEncoder.ate.encode(original)
        )
        #expect(decoded == original)
    }

    // MARK: - Receipt

    @Test("a single-dish receipt has a hero score and offers 'View dish'")
    func singleDishReceipt() throws {
        var state = SittingState(restaurant: Self.restaurant)
        let dishID = UUID()
        state.add(dishID: dishID, dishName: "Betel Leaf")
        state.setScore(Rating(rounding: 4.5), for: state.dishes[0].id)

        let receipt = ReceiptModel(sitting: state, author: .init(name: "Eamon", handle: "@eamon"))
        #expect(receipt.isSingleDish)
        #expect(receipt.heroScore?.value == 4.5)
        #expect(receipt.singleDishRoute == DishRoute(dishID: dishID))
        #expect(receipt.placeLine == "Chin Chin · Melbourne")
        #expect(receipt.shareTitle == "Betel Leaf")
    }

    @Test("a multi-dish receipt has no hero score and no 'View dish'")
    func multiDishReceipt() {
        var state = SittingState(restaurant: Self.restaurant)
        state.add(dishID: UUID(), dishName: "Betel Leaf")
        state.add(dishID: UUID(), dishName: "Son-in-law Eggs")
        state.setScore(Rating(rounding: 4.5), for: state.dishes[0].id)
        state.setScore(Rating(rounding: 3), for: state.dishes[1].id)

        let receipt = ReceiptModel(sitting: state, author: nil)
        #expect(receipt.isSingleDish == false)
        #expect(receipt.heroScore == nil)
        #expect(receipt.singleDishRoute == nil)
        #expect(receipt.lines.count == 2)
        #expect(receipt.shareTitle == "Betel Leaf + 1 more")
    }

    @Test("§5.3 the text-only fallback names the dishes, the scores and the place")
    func shareTextFallback() {
        var state = SittingState(restaurant: Self.restaurant)
        state.add(dishID: UUID(), dishName: "Betel Leaf")
        state.setScore(Rating(rounding: 4.5), for: state.dishes[0].id)
        #expect(ReceiptModel(sitting: state, author: nil).shareText
            == "Betel Leaf 4.5/5 at Chin Chin · Melbourne")
    }

    @Test("a restaurant with no suburb prints no dangling separator")
    func placeLineWithoutSuburb() {
        let state = SittingState(restaurant: SittingRestaurant(id: UUID(), name: "Nowhere"))
        #expect(ReceiptModel(sitting: state, author: nil).placeLine == "Nowhere")
    }
}
