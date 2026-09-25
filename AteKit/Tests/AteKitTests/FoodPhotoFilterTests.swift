import Foundation
import Testing
@testable import AteKit

@Suite("Food photo filter")
struct FoodPhotoFilterTests {

    // Vision's own answers for three of the prototype photos and a landscape (macOS 26, iOS taxonomy).
    private static let burger = [PhotoLabel("food", 0.96), PhotoLabel("hamburger", 0.94), PhotoLabel("meat", 0.94)]
    private static let raguInItsPan = [
        PhotoLabel("utensil", 0.51), PhotoLabel("cookware", 0.51), PhotoLabel("pan", 0.51),
        PhotoLabel("food", 0.44), PhotoLabel("stir_fry", 0.38)
    ]
    private static let landscape = [PhotoLabel("outdoor", 0.92), PhotoLabel("sky", 0.86), PhotoLabel("hill", 0.77)]

    @Test("A dish is food, even when the pan it sits in outscores it")
    func dishes() {
        #expect(FoodPhotoRule.isFood(Self.burger))
        #expect(FoodPhotoRule.isFood(Self.raguInItsPan))
    }

    @Test("A landscape, a screenshot, a face: not food")
    func notFood() {
        #expect(FoodPhotoRule.isFood(Self.landscape) == false)
        #expect(FoodPhotoRule.isFood([PhotoLabel("document", 0.9), PhotoLabel("text", 0.8)]) == false)
        #expect(FoodPhotoRule.isFood([PhotoLabel("people", 0.9), PhotoLabel("adult", 0.7)]) == false)
        #expect(FoodPhotoRule.isFood([]) == false)
    }

    @Test("A food label under the threshold does not count; at it, it does")
    func threshold() {
        #expect(FoodPhotoRule.threshold == 0.3)
        #expect(FoodPhotoRule.isFood([PhotoLabel("food", 0.29)]) == false)
        #expect(FoodPhotoRule.isFood([PhotoLabel("food", 0.3)]))
    }

    @Test("A drink or a dessert counts without the food parent")
    func drinksAndSweets() {
        #expect(FoodPhotoRule.isFood([PhotoLabel("drink", 0.6)]))
        #expect(FoodPhotoRule.isFood([PhotoLabel("coffee", 0.5)]))
        #expect(FoodPhotoRule.isFood([PhotoLabel("dessert", 0.4)]))
        // Tableware alone is a set table, not a meal.
        #expect(FoodPhotoRule.isFood([PhotoLabel("tableware", 0.9), PhotoLabel("plate", 0.9)]) == false)
    }

    private static func item(_ id: String, minutesAgo: Double = 0) -> PhotoSuggestionItem {
        PhotoSuggestionItem(id: id, createdAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
    }

    @Test("Only food is kept, in the order given")
    func keepsFoodInOrder() async {
        let table: [String: [PhotoLabel]] = [
            "burger": Self.burger, "hill": Self.landscape, "ragu": Self.raguInItsPan
        ]
        let filter = FoodPhotoFilter { table[$0] }
        let items = ["burger", "hill", "ragu"].map { Self.item($0) }
        let result = await filter.filter(items)
        #expect(result.kept.map(\.id) == ["burger", "ragu"])
        #expect(result.dropped == 1)
        #expect(result.newlyClassified == 3)
    }

    @Test("Each asset is classified once; the second pass is all cache")
    func caches() async {
        let calls = Counter()
        let filter = FoodPhotoFilter { id in
            await calls.bump(id)
            return id == "burger" ? Self.burger : Self.landscape
        }
        let items = [Self.item("burger"), Self.item("hill")]
        _ = await filter.filter(items)
        let second = await filter.filter(items)
        #expect(await calls.byID == ["burger": 1, "hill": 1])
        #expect(second.kept.map(\.id) == ["burger"])
        #expect(second.newlyClassified == 0)
        #expect(await filter.knownVerdicts == ["burger": true, "hill": false])
    }

    @Test("Verdicts handed in from a previous launch are trusted, not re-asked")
    func seeded() async {
        let calls = Counter()
        let filter = FoodPhotoFilter(verdicts: ["old-burger": true, "old-hill": false]) { id in
            await calls.bump(id)
            return Self.burger
        }
        let result = await filter.filter([Self.item("old-burger"), Self.item("old-hill"), Self.item("new")])
        #expect(result.kept.map(\.id) == ["old-burger", "new"])
        #expect(await calls.byID == ["new": 1])
    }

    @Test("A photo that cannot be read is left out and asked about again next time")
    func unreadable() async {
        let calls = Counter()
        let filter = FoodPhotoFilter { id in
            await calls.bump(id)
            return nil
        }
        let first = await filter.filter([Self.item("icloud-only")])
        #expect(first.kept.isEmpty)
        #expect(first.dropped == 1)
        _ = await filter.filter([Self.item("icloud-only")])
        #expect(await calls.byID == ["icloud-only": 2])
        #expect(await filter.knownVerdicts.isEmpty)
    }

    @Test("suggestion_filtered carries what was left out and what was kept")
    func event() {
        let event = EntryEvents.suggestionFiltered(count: 7, kept: 5)
        #expect(event.name == "suggestion_filtered")
        #expect(event.parameters == ["count": "7", "kept": "5"])
        #expect(EntryEvents.suggestionFiltered(count: -1, kept: -1).parameters == ["count": "0", "kept": "0"])
    }

    private actor Counter {
        var byID: [String: Int] = [:]
        func bump(_ id: String) { byID[id, default: 0] += 1 }
    }
}
