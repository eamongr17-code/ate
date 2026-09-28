import Foundation
import Testing
@testable import AteKit

/// Round 6, detail: a dish or place page draws at once from what the row that opened it knew, and
/// "what to order" is shown in the server's order.
@MainActor
@Suite("Detail round 6")
struct DetailRound6Tests {

    private static let dish = UUID()
    private static let place = UUID()

    @Test func aSlipsPreviewCarriesNoScore() {
        let previews = DishPreviews()
        previews.note(DishPreview(
            dishID: Self.dish, name: "Ragù", restaurantID: Self.place, restaurantName: "Tipo 00"
        ))
        let preview = previews.preview(for: Self.dish)
        #expect(preview?.name == "Ragù")
        #expect(preview?.restaurantName == "Tipo 00")
        #expect(preview?.score == nil, "a person's own score is never the dish's aggregate")
        #expect(preview?.hasPhotos == nil, "unknown, so the page reserves the hero")
    }

    @Test func aBetterInformedRowFillsInWhatAnEarlierOneDidNotKnow() {
        let previews = DishPreviews()
        previews.note(DishPreview(
            dishID: Self.dish, name: "Ragù", restaurantID: Self.place, restaurantName: "Tipo 00"
        ))
        previews.note(DishPreview(dishID: Self.dish, name: "Ragù", score: 4.4, photoURL: "https://x/1.jpg"))
        let preview = previews.preview(for: Self.dish)
        #expect(preview?.score == 4.4)
        #expect(preview?.restaurantName == "Tipo 00", "kept from the first")
        #expect(preview?.hasPhotos == true)
    }

    @Test func thePreviewsAreBounded() {
        let previews = DishPreviews(capacity: 2)
        let first = UUID()
        previews.note(DishPreview(dishID: first, name: "A"))
        previews.note(DishPreview(dishID: UUID(), name: "B"))
        previews.note(DishPreview(dishID: UUID(), name: "C"))
        #expect(previews.preview(for: first) == nil, "the oldest goes first")
    }

    @Test func aDishPageHasItsPreviewBeforeItsReadAndLeavesOneBehind() async {
        let previews = DishPreviews()
        previews.note(DishPreview(dishID: Self.dish, name: "Ragù", restaurantName: "Tipo 00"))
        let store = DishPageStore(dishID: Self.dish, dishes: StubDishes(dishID: Self.dish), previews: previews)
        #expect(store.preview?.name == "Ragù")
        #expect(store.isSettled == false)
        await store.load()
        #expect(previews.preview(for: Self.dish)?.score == 4.5, "the loaded page leaves its whole self behind")
    }

    @Test func aPlaceNameIsRememberedForItsPage() {
        let previews = PlacePreviews()
        previews.note(Self.place, name: "Tipo 00")
        previews.note(UUID(), name: "")
        #expect(previews.name(for: Self.place) == "Tipo 00")
    }
}

/// One dish, scored 4.5, with no reviews.
private struct StubDishes: DishPageReading, TestFake {
    let dishID: UUID

    func dishSummary(dishID: UUID) async throws -> DishSummary {
        DishSummary(
            dishID: dishID, name: "Ragù", restaurantID: UUID(), restaurantName: "Tipo 00",
            score: 4.5, reviewCount: 3, scoredCount: 3, peopleCount: 3
        )
    }

    func dishReviews(dishID: UUID, after cursor: DishReviewCursor?, pageSize: Int) async throws -> DishReviewPage {
        DishReviewPage(items: [], nextCursor: nil)
    }

}
