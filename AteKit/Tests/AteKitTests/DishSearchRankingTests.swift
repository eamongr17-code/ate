import Foundation
import Testing

@testable import AteKit

@Suite("Dish search — ranking, history, filtering")
struct DishSearchRankingTests {
    private let restaurantID = UUID()

    private func row(_ name: String, count: Int = 0, score: Double? = nil, id: UUID = UUID()) -> DishRowModel {
        DishRowModel(dishID: id, name: name, restaurantID: restaurantID, score: score, reviewCount: count)
    }

    private func review(dish: UUID, at seconds: TimeInterval, score: Double = 4.0) -> Review {
        Review(
            id: UUID(),
            reviewerID: UUID(),
            dishID: dish,
            restaurantID: restaurantID,
            score: Rating(exactly: score)!,
            createdAt: Date(timeIntervalSince1970: seconds),
            updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    // MARK: - Menu order (§11.3)

    @Test("the menu ranks review_count desc, then score desc")
    func menuOrder() {
        let ordered = DishSearchRanking.menuOrder([
            row("Quiet gem", count: 2, score: 5.0),
            row("Crowd favourite", count: 40, score: 4.2),
            row("Also popular", count: 40, score: 4.8)
        ])
        #expect(ordered.map(\.name) == ["Also popular", "Crowd favourite", "Quiet gem"])
    }

    @Test("an unrated dish sorts last but is never treated as zero-rated")
    func unratedIsNotZero() {
        let unrated = row("Never ordered", count: 0, score: nil)
        let bad = row("Genuinely bad", count: 3, score: 1.0)
        let ordered = DishSearchRanking.menuOrder([unrated, bad])
        #expect(ordered.map(\.name) == ["Genuinely bad", "Never ordered"])
        #expect(ordered.last?.score == nil)
        #expect(ordered.last?.isRated == false)
    }

    @Test("nil scores trail within the same review-count band")
    func nilScoreTrailsWithinBand() {
        let ordered = DishSearchRanking.menuOrder([
            row("No score", count: 5, score: nil),
            row("Scored", count: 5, score: 3.0)
        ])
        #expect(ordered.map(\.name) == ["Scored", "No score"])
    }

    @Test("the order is total, so an offset page boundary can't duplicate or drop a row")
    func totalOrder() {
        let a = row("Same", count: 1, score: 4.0, id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        let b = row("Same", count: 1, score: 4.0, id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
        #expect(DishSearchRanking.menuOrder([b, a]).map(\.dishID) == [a.dishID, b.dishID])
        #expect(DishSearchRanking.menuOrder([a, b]).map(\.dishID) == [a.dishID, b.dishID])
    }

    // MARK: - History (§11.3 "You've had here")

    @Test("history is deduped by dish, most recent first, and capped")
    func historyDedup() {
        let brisket = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!
        let mac = UUID(uuidString: "00000000-0000-4000-8000-0000000000BB")!
        let ids = DishSearchRanking.historyDishIDs(from: [
            review(dish: brisket, at: 300),
            review(dish: mac, at: 200),
            review(dish: brisket, at: 100)
        ])
        #expect(ids == [brisket, mac])
    }

    @Test("history respects the cap")
    func historyCap() {
        let reviews = (0..<9).map { review(dish: UUID(), at: TimeInterval($0)) }
        #expect(DishSearchRanking.historyDishIDs(from: reviews, limit: 5).count == 5)
    }

    @Test("the 'you rated' caption uses the viewer's MOST RECENT score for the dish")
    func latestOwnScore() {
        let brisket = UUID()
        let scores = DishSearchRanking.latestOwnScores(from: [
            review(dish: brisket, at: 100, score: 2.0),
            review(dish: brisket, at: 300, score: 4.5)
        ])
        #expect(scores[brisket]?.score.value == 4.5)
    }

    // MARK: - Filtered list (§11.3, ≥1 char)

    @Test("filtered results put your history first, then the catalogue, with no duplicates")
    func flatten() {
        let brisketID = UUID()
        let history = [row("Brisket", id: brisketID)]
        let catalogue = [
            row("Brisket roll", count: 50, score: 4.9),
            row("Brisket", count: 10, score: 4.0, id: brisketID)
        ]
        let flat = DishSearchRanking.flatten(history: history, catalogue: catalogue)
        #expect(flat.map(\.name) == ["Brisket", "Brisket roll"])
        // The history copy wins — it's the one carrying "you rated …".
        #expect(flat.first?.dishID == brisketID)
    }

    @Test("neither input is re-sorted by flatten")
    func flattenPreservesOrder() {
        let history = [row("B"), row("A")]
        let catalogue = [row("Z"), row("Y")]
        #expect(DishSearchRanking.flatten(history: history, catalogue: catalogue).map(\.name) == ["B", "A", "Z", "Y"])
    }

    // MARK: - Row construction

    @Test("a dish with no stats row is unrated, not zero-rated")
    func rowFromDishWithoutStats() {
        let dish = Dish(id: UUID(), name: "Brisket", restaurantID: restaurantID, createdAt: .init())
        let model = DishRowModel(dish: dish)
        #expect(model.score == nil)
        #expect(model.reviewCount == 0)
        #expect(model.isRated == false)
    }

    @Test("a row built from a tombstone carries the SURVIVOR's id (§6.3 redirect)")
    func rowFollowsMergeRedirect() {
        let survivor = UUID()
        let tombstone = Dish(
            id: UUID(), name: "Brisket", restaurantID: restaurantID,
            mergedIntoDishID: survivor, createdAt: .init()
        )
        #expect(DishRowModel(dish: tombstone).dishID == survivor)
        #expect(PickedDish(tombstone).id == survivor)
    }
}
