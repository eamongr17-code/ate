import Foundation
import Supabase
import Testing
@testable import AteKit

@Suite("Your top dishes")
struct TopDishesTests {
    private static func dish(_ name: String, _ score: Double, id: UUID = UUID()) -> ScoredDish {
        ScoredDish(
            reviewID: UUID(), dishID: id, dishName: name, restaurantID: UUID(), restaurantName: "Somewhere",
            score: score, createdAt: Date(timeIntervalSince1970: 1_789_000_000), coverURL: nil
        )
    }

    private static func histogram(_ counts: [Double: Int]) -> ScoreHistogram {
        ScoreHistogram(counts.map { ScoreBucket(score: $0.key, dishCount: $0.value, reviewCount: $0.value) })
    }

    @Test("only the bars at 4.0 and up that hold a dish are read, best first — a 6 leads")
    func scores() {
        let chart = Self.histogram([6: 1, 5: 2, 4.5: 0, 4: 3, 3.5: 9])
        #expect(TopDishes.scores(in: chart) == [6, 5, 4])
        #expect(TopDishes.scores(in: Self.histogram([3: 4])).isEmpty, "nothing middling makes the list")
        #expect(TopDishes.scores(in: .empty).isEmpty)
        #expect(TopDishes.scores(in: nil) == [6, 5, 4.5, 4], "no chart: every score a top dish can have")
    }

    @Test("four at most, best score first, one tile per dish, reading no further than needed")
    func read() async {
        let pasta = UUID()
        let asked = Asked()
        let pages: [Double: [ScoredDish]] = [
            6: [Self.dish("Prawn spaghetti", 6)],
            5: [Self.dish("Pasta", 5, id: pasta), Self.dish("Pasta again", 5, id: pasta), Self.dish("Toast", 5)],
            4.5: [Self.dish("Cake", 4.5), Self.dish("Pie", 4.5)],
            4: [Self.dish("Soup", 4)]
        ]
        let picked = await TopDishes.read(scores: [6, 5, 4.5, 4]) { score in
            asked.note(score)
            return pages[score] ?? []
        }
        #expect(picked?.map(\.dishName) == ["Prawn spaghetti", "Pasta", "Toast", "Cake"])
        #expect(asked.scores == [6, 5, 4.5], "4.0 is never read once four are in hand")
    }

    /// The scores a read was asked for, from a `@Sendable` page reader.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [Double] = []
        var scores: [Double] { lock.withLock { asked } }
        func note(_ score: Double) { lock.withLock { asked.append(score) } }
    }

    @Test("a failed read is skipped; all of them failing is no answer, not an empty section")
    func failures() async {
        struct Nope: Error {}
        let partly = await TopDishes.read(scores: [6, 5]) { score in
            if score == 6 { throw Nope() }
            return [Self.dish("Toast", 5)]
        }
        #expect(partly?.map(\.dishName) == ["Toast"])
        let none = await TopDishes.read(scores: [6, 5]) { _ in throw Nope() }
        #expect(none == nil)
        let nothing = await TopDishes.read(scores: []) { _ in [] }
        #expect(nothing == [], "nothing at 4.0 and up: no section")
    }
}
