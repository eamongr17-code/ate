import Foundation
import Testing

@testable import AteKit

@Suite("Sitting state")
struct SittingStateTests {
    private static let restaurant = SittingRestaurant(
        id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        name: "Chin Chin",
        suburb: "Melbourne"
    )

    /// Whole seconds: drafts persist as ISO-8601, which has no sub-second precision, and a
    /// `Date()` here would fail an equality round-trip for a reason that has nothing to do with the
    /// behaviour under test.
    private static let openedAt = Date(timeIntervalSince1970: 1_756_700_000)

    private func sitting(dishCount: Int, rated: Bool = false) -> SittingState {
        var state = SittingState(restaurant: Self.restaurant, startedAt: Self.openedAt)
        for index in 0..<dishCount {
            let outcome = state.add(dishID: UUID(), dishName: "Dish \(index)")
            if rated, case .added(let cardID, _) = outcome {
                state.setScore(Rating(rounding: 4), for: cardID)
            }
        }
        return state
    }

    // MARK: - Adding

    @Test("a dish is appended in arrival order")
    func addsInArrivalOrder() {
        var state = sitting(dishCount: 0)
        let first = UUID()
        let second = UUID()
        let firstCard = UUID()

        #expect(state.add(dishID: first, dishName: "Betel Leaf", cardID: firstCard)
            == .added(cardID: firstCard, index: 0))
        state.add(dishID: second, dishName: "Son-in-law Eggs")

        #expect(state.dishes.map(\.dishID) == [first, second])
        #expect(state.dishes[0].id == firstCard, "the card id IS the review id, minted up front")
    }

    @Test("§4.3 duplicate guard: the same dish never gets a second card")
    func duplicateGuard() {
        var state = sitting(dishCount: 0)
        let dishID = UUID()
        guard case .added(let cardID, _) = state.add(dishID: dishID, dishName: "Betel Leaf") else {
            Issue.record("first add should succeed")
            return
        }
        let outcome = state.add(dishID: dishID, dishName: "Betel Leaf")
        #expect(outcome == .duplicate(cardID: cardID, index: 0))
        #expect(state.dishes.count == 1)
    }

    @Test("§4.3 soft cap: the ninth dish is refused, the first eight are not")
    func softCap() {
        var state = sitting(dishCount: SittingState.softCap)
        #expect(state.canAddAnother == false)
        #expect(state.add(dishID: UUID(), dishName: "One too many") == .atCapacity)
        #expect(state.dishes.count == SittingState.softCap)
    }

    // MARK: - Removing

    @Test("§4.3 removing the last card empties the sitting rather than ending it")
    func removingLastCardKeepsTheSitting() {
        var state = sitting(dishCount: 1)
        let cardID = state.dishes[0].id
        #expect(state.remove(cardID: cardID) == 0)
        #expect(state.isEmpty)
        #expect(state.isPostable == false)
        #expect(state.hasContent == false)
    }

    @Test("removing an unknown card is a no-op")
    func removingUnknownCard() {
        var state = sitting(dishCount: 2)
        #expect(state.remove(cardID: UUID()) == nil)
        #expect(state.dishes.count == 2)
    }

    @Test("swipe-to-delete offsets remove the right cards")
    func removeAtOffsets() {
        var state = sitting(dishCount: 3)
        let second = state.dishes[1].id
        let removed = state.remove(atOffsets: IndexSet(integer: 1))
        #expect(removed == [second])
        #expect(state.dishes.count == 2)
        #expect(state.dishes.contains { $0.id == second } == false)
    }

    // MARK: - Editing

    @Test("a late update for a card that has been deleted is dropped, not resurrected")
    func lateUpdateForDeletedCard() {
        var state = sitting(dishCount: 1)
        let cardID = state.dishes[0].id
        state.remove(cardID: cardID)
        state.setPhotoUploadState(.uploaded(urlString: "https://x/y.jpg"), for: cardID)
        #expect(state.dishes.isEmpty)
    }

    @Test("photo upload state transitions on the right card only")
    func photoUploadState() {
        var state = sitting(dishCount: 2)
        let first = state.dishes[0].id
        state.setPhoto(SittingPhoto(localFileName: "a.jpg"), for: first)
        #expect(state.hasUploadInFlight)
        state.setPhotoUploadState(.uploaded(urlString: "https://x/a.jpg"), for: first)
        #expect(state.hasUploadInFlight == false)
        #expect(state.dishes[0].photo?.uploadState.uploadedURLString == "https://x/a.jpg")
        #expect(state.dishes[1].photo == nil)
    }

    // MARK: - Post gate

    @Test("§4.3 Post needs at least one card and every card rated")
    func postGate() {
        #expect(sitting(dishCount: 0).isPostable == false)
        #expect(sitting(dishCount: 2, rated: false).isPostable == false)
        #expect(sitting(dishCount: 2, rated: true).isPostable)
    }

    @Test("the first unrated card is the one the canvas scrolls to and wiggles")
    func firstUnrated() {
        var state = sitting(dishCount: 3)
        state.setScore(Rating(rounding: 4), for: state.dishes[0].id)
        #expect(state.firstUnratedCardID == state.dishes[1].id)
        state.setScore(Rating(rounding: 3), for: state.dishes[1].id)
        state.setScore(Rating(rounding: 5), for: state.dishes[2].id)
        #expect(state.firstUnratedCardID == nil)
    }

    @Test("§4.2 the Post button pluralises", arguments: [(1, "Post"), (2, "Post 2 dishes"), (5, "Post 5 dishes")])
    func postButtonTitle(count: Int, expected: String) {
        #expect(sitting(dishCount: count, rated: true).postButtonTitle == expected)
    }

    // MARK: - Draft guard

    @Test("§7 hasContent is true for a rating, a note or a photo — and false for a bare card")
    func hasContent() {
        var state = sitting(dishCount: 1)
        let cardID = state.dishes[0].id
        #expect(state.hasContent == false)

        state.setNote("   ", for: cardID)
        #expect(state.hasContent == false, "whitespace is not content")

        state.setNote("crunchy", for: cardID)
        #expect(state.hasContent)

        state.setNote("", for: cardID)
        state.setPhoto(SittingPhoto(localFileName: "a.jpg"), for: cardID)
        #expect(state.hasContent)

        state.setPhoto(nil, for: cardID)
        state.setScore(Rating(rounding: 0.5), for: cardID)
        #expect(state.hasContent)
    }

    @Test("seconds_from_open counts from the sheet opening, never negative")
    func secondsFromOpen() {
        let started = Date(timeIntervalSince1970: 1_000)
        let state = SittingState(restaurant: Self.restaurant, startedAt: started)
        #expect(state.secondsFromOpen(now: started.addingTimeInterval(13)) == 13)
        #expect(state.secondsFromOpen(now: started.addingTimeInterval(-5)) == 0)
    }

    @Test("a sitting round-trips through JSON so a draft survives a relaunch")
    func codableRoundTrip() throws {
        var state = sitting(dishCount: 2)
        state.setScore(Rating(rounding: 4.5), for: state.dishes[0].id)
        state.setNote("worth it", for: state.dishes[0].id)
        state.setPhoto(
            SittingPhoto(localFileName: "a.jpg", uploadState: .uploaded(urlString: "https://x/a.jpg")),
            for: state.dishes[1].id
        )

        let data = try JSONEncoder.ate.encode(state)
        let decoded = try JSONDecoder.ate.decode(SittingState.self, from: data)
        #expect(decoded == state)
    }
}
