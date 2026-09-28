import Foundation
import Testing

@testable import AteKit

@Suite("Restaurant dish ranking")
struct DishRankingTests {
    // swiftlint:disable:next large_tuple
    private func ranked(_ specs: [(seed: String, name: String, score: Double?, count: Int)]) -> [String] {
        let dishes = specs.map { DetailFixtures.dish($0.seed, name: $0.name) }
        let stats = specs.map { DetailFixtures.dishStats($0.seed, score: $0.score, reviewCount: $0.count) }
        return DishRanking.rank(dishes: dishes, stats: stats).map(\.name)
    }

    @Test("by rating (0051): a lonely 5.0 leads a well-reviewed 4.4, and a 6 leads every 5")
    func ratingLeads() {
        let order = ranked([
            (seed: "dish-1", name: "Lonely 5.0", score: 5.0, count: 1),
            (seed: "dish-2", name: "Beloved 4.4", score: 4.4, count: 12),
            (seed: "dish-3", name: "Secret 6", score: 6.0, count: 1)
        ])
        #expect(order == ["Secret 6", "Lonely 5.0", "Beloved 4.4"])
    }

    @Test("review count breaks a tie on the printed score — 4.62 and 4.58 both read 4.6")
    func reviewCountBreaksPrintedTies() {
        let order = ranked([
            (seed: "dish-1", name: "Few", score: 4.62, count: 2),
            (seed: "dish-2", name: "Many", score: 4.58, count: 9),
            (seed: "dish-3", name: "Lower", score: 4.4, count: 30)
        ])
        #expect(order == ["Many", "Few", "Lower"])
    }

    @Test("an unrated dish sinks below every rated one — nil is not 0, and not first either")
    func unratedSinks() {
        let order = ranked([
            (seed: "dish-1", name: "Want to try", score: nil, count: 8),
            (seed: "dish-2", name: "Rated", score: 2.0, count: 3)
        ])
        #expect(order == ["Rated", "Want to try"], "unscored follows every scored dish, however often ordered")

        // And at an equal (zero) review count, a nil score sorts after a real one rather than
        // comparing as 0 and jumping the queue.
        let tie = ranked([
            (seed: "dish-1", name: "Unrated", score: nil, count: 0),
            (seed: "dish-2", name: "Scored", score: 0.5, count: 0)
        ])
        #expect(tie == ["Scored", "Unrated"])
    }

    @Test("ordering is total, so the list doesn't shuffle between refreshes")
    func orderIsStable() {
        // swiftlint:disable:next large_tuple
        let specs: [(seed: String, name: String, score: Double?, count: Int)] = [
            (seed: "dish-1", name: "Bravo", score: 4.0, count: 2),
            (seed: "dish-2", name: "alpha", score: 4.0, count: 2),
            (seed: "dish-3", name: "Charlie", score: 4.0, count: 2)
        ]
        #expect(ranked(specs) == ["alpha", "Bravo", "Charlie"])
        #expect(ranked(specs.reversed()) == ["alpha", "Bravo", "Charlie"])
    }

    @Test("a dish with no stats row still lists, as unrated")
    func missingStatsRow() {
        let dishes = [DetailFixtures.dish("dish-1", name: "Orphan"), DetailFixtures.dish("dish-2", name: "Known")]
        let stats = [DetailFixtures.dishStats("dish-2", score: 4.0, reviewCount: 2)]
        let result = DishRanking.rank(dishes: dishes, stats: stats)
        #expect(result.map(\.name) == ["Known", "Orphan"])
        #expect(result.last?.isRated == false)
        #expect(result.last?.score == nil)
        #expect(result.last?.reviewCount == 0)
    }

    @Test("merged-away dishes never appear on the menu")
    func tombstonesExcluded() {
        let dishes = [
            DetailFixtures.dish("dish-1", name: "Survivor"),
            DetailFixtures.dish("dish-2", name: "Merged away", mergedInto: DetailFixtures.id("dish-1"))
        ]
        let result = DishRanking.rank(dishes: dishes, stats: [])
        #expect(result.map(\.name) == ["Survivor"])
    }
}
