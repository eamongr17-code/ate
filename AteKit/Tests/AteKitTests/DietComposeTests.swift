import Foundation
import Testing
@testable import AteKit

@Suite("Diet — turning a code off for one dish")
struct ComposerDietTests {
    private func words(_ plain: String, scoreAt score: TextSpan? = nil) -> EntryComposition {
        guard let score else { return EntryComposition(plain: plain, spans: []) }
        let pill = EntryTokenSpan(token: EntryToken(kind: .score(Rating(exactly: 4)!)), span: score)
        return EntryComposition(plain: plain, spans: [pill])
    }

    @Test("a vegan's dish shows VG lit; a tap turns it off for that dish, another turns it back on")
    func offAndOn() {
        var diet = ComposerDiet(diet: [.vg])
        let prawn = words("Prawn toast")
        #expect(diet.lit(in: prawn, atDisplayOffset: 11) == [.vg])
        #expect(diet.toggle(.vg, in: prawn, atDisplayOffset: 11) == .off(.vg))
        #expect(diet.lit(in: prawn, atDisplayOffset: 11) == [])
        #expect(diet.offTokens(in: prawn.plain) == [DietOffToken(offset: 6, length: 5, code: .vg)])
        #expect(diet.toggle(.vg, in: prawn, atDisplayOffset: 11) == .on(.vg))
        #expect(diet.offTokens(in: prawn.plain).isEmpty)
    }

    @Test("after the dish's score, it is still that dish — the token names the dish, not the score")
    func afterScore() {
        var diet = ComposerDiet(diet: [.vg])
        let prawn = words("Prawn toast 4.0 ", scoreAt: TextSpan(location: 12, length: 3))
        let end = prawn.displayString.utf16.count
        #expect(diet.toggle(.vg, in: prawn, atDisplayOffset: end) == .off(.vg))
        #expect(diet.offTokens(in: prawn.plain) == [DietOffToken(offset: 6, length: 5, code: .vg)])
    }

    @Test("another dish keeps its codes lit")
    func perDish() {
        var diet = ComposerDiet(diet: [.vg, .gf])
        let first = words("Prawn toast")
        _ = diet.toggle(.vg, in: first, atDisplayOffset: 11)
        let both = words("Prawn toast, tofu larb")
        diet.follow(from: first.plain, to: both.plain)
        #expect(diet.lit(in: both, atDisplayOffset: 22) == [.gf, .vg])
        #expect(diet.lit(in: both, atDisplayOffset: 11) == [.gf])
    }

    @Test("codes not in the diet, and a page with no dish, are the Diet key's as before")
    func notManaged() {
        var diet = ComposerDiet(diet: [.vg])
        #expect(diet.toggle(.gf, in: words("Prawn toast"), atDisplayOffset: 11) == nil)
        #expect(diet.toggle(.vg, in: words(""), atDisplayOffset: 0) == nil)
        #expect(diet.lit(in: words(""), atDisplayOffset: 0) == [])
        var none = ComposerDiet()
        #expect(none.lit(in: words("Prawn toast"), atDisplayOffset: 11) == [])
        #expect(none.toggle(.vg, in: words("Prawn toast"), atDisplayOffset: 11) == nil)
    }

    @Test("the mark follows its words; rewriting the dish's word forgets it")
    func follows() {
        var diet = ComposerDiet(diet: [.vg])
        _ = diet.toggle(.vg, in: words("Prawn toast"), atDisplayOffset: 11)
        diet.follow(from: "Prawn toast", to: "Mushroom bao 4.5. Prawn toast")
        #expect(diet.offTokens(in: "Mushroom bao 4.5. Prawn toast") == [DietOffToken(offset: 24, length: 5, code: .vg)])
        diet.follow(from: "Mushroom bao 4.5. Prawn toast", to: "Mushroom bao 4.5. Prawn toast was great")
        #expect(diet.offTokens(in: "Mushroom bao 4.5. Prawn toast was great").map(\.offset) == [24])
        diet.follow(from: "Mushroom bao 4.5. Prawn toast was great", to: "Mushroom bao 4.5. Prawn roast was great")
        #expect(diet.offs.isEmpty)
    }

    @Test("offsets are Unicode scalars, as the server counts")
    func scalars() {
        var diet = ComposerDiet(diet: [.vg])
        let bowl = words("🍜 Prawn toast")
        let end = bowl.displayString.utf16.count
        _ = diet.toggle(.vg, in: bowl, atDisplayOffset: end)
        #expect(diet.offTokens(in: bowl.plain) == [DietOffToken(offset: 8, length: 5, code: .vg)])
    }

    @Test("the sort request carries diet_off_tokens only when there are any")
    func request() throws {
        let id = UUID()
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SortEntryRequest(entryID: id, force: false)
        )) as? [String: Any]
        #expect(plain?["diet_off_tokens"] == nil)
        let off = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SortEntryRequest(entryID: id, force: false, dietOffTokens: [DietOffToken(offset: 6, length: 5, code: .vg)])
        )) as? [String: Any]
        let tokens = off?["diet_off_tokens"] as? [[String: Any]]
        #expect(tokens?.count == 1)
        #expect(tokens?.first?["offset"] as? Int == 6)
        #expect(tokens?.first?["length"] as? Int == 5)
        #expect(tokens?.first?["code"] as? String == "vg")
    }
}

@Suite("Diet — turning a code off on a saved entry")
struct ComposerDietEditTests {
    private let bao = UUID()
    private let prawn = UUID()

    /// "Mushroom bao 4.5. Prawn toast 4.0" — the bao vegan from the author's diet, GF typed elsewhere.
    private var items: [EntryCard.Item] {
        [
            EntryCard.Item(
                reviewID: bao, dishID: UUID(), dishName: "Mushroom bao", position: 1,
                mentionOffset: 0, mentionLength: 12, tags: [.gf, .vg], dietTags: [.vg]
            ),
            EntryCard.Item(
                reviewID: prawn, dishID: UUID(), dishName: "Prawn toast", position: 2,
                mentionOffset: 18, mentionLength: 11, tags: []
            )
        ]
    }

    @Test("the line's diet codes are lit on its dish, and turning one off PATCHes the rest")
    func removal() {
        let body = "Mushroom bao 4.5. Prawn toast 4.0"
        let words = EntryComposition(plain: body, spans: [])
        var diet = ComposerDiet(editing: items, body: body)
        #expect(diet.lit(in: words, atDisplayOffset: 12) == [.vg])
        #expect(diet.lit(in: words, atDisplayOffset: 33) == [])
        #expect(diet.toggle(.vg, in: words, atDisplayOffset: 33) == nil, "not the prawn toast's")
        #expect(diet.toggle(.vg, in: words, atDisplayOffset: 12) == .off(.vg))
        #expect(diet.hasRemovals)
        let diff = EditTagDiff(original: words, current: words, items: items, dietRemovals: diet.removals)
        #expect(diff.hasNewTags == false, "never a forced re-sort")
        #expect(diff.removals == [EditTagDiff.Removal(reviewID: bao, remaining: [.gf])])
        #expect(diet.toggle(.vg, in: words, atDisplayOffset: 12) == .on(.vg))
        #expect(diet.hasRemovals == false)
    }
}

@MainActor
@Suite("Diet — a place's chips")
struct PlaceDietFilterTests {
    private let placeID = UUID(uuidString: "B7E00000-0000-4000-8000-000000000002")!

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [AnalyticsEvent] = []
        var events: [AnalyticsEvent] { lock.withLock { log } }
        func record(_ event: AnalyticsEvent) { lock.withLock { log.append(event) } }
    }

    @Test("on by default: only labelled or counted dishes, each saying which; a tap shows everything")
    func filter() async {
        let source = FakePlaceDishSource()
        source.seed(
            place: PlaceSummary(restaurantID: placeID, name: "Lucy Liu"),
            dishes: [
                MenuDish(dishID: UUID(), name: "Mushroom Bao", score: 4.5, peopleCount: 4, reviewCount: 9,
                         dietCounts: DietCounts([.vg: 2])),
                MenuDish(dishID: UUID(), name: "Tofu Larb", score: 4.3, peopleCount: 7, reviewCount: 8, tags: [.vg]),
                MenuDish(dishID: UUID(), name: "Prawn Toast", score: 4.0, peopleCount: 5, reviewCount: 7)
            ]
        )
        let recorder = Recorder()
        let store = PlacePageStore(restaurantID: placeID, places: source) { recorder.record($0) }
        store.useDiet([.vg])
        await store.load()
        #expect(store.dietOn == [.vg])
        #expect(store.shownDishes.map(\.name) == ["Mushroom Bao", "Tofu Larb"])
        #expect(store.dietSignals(for: store.shownDishes[0]) == [.orderedBy(.vg, count: 2)])
        #expect(store.dietSignals(for: store.shownDishes[1]) == [.labelled(.vg)])
        store.toggleDiet(.vg)
        #expect(store.shownDishes.count == 3)
        #expect(store.dietSignals(for: store.shownDishes[2]).isEmpty)
        #expect(recorder.events.last == DietEvents.placeFilterToggled(.vg, isOn: false, restaurantID: placeID))
        // No diet, no chips.
        store.useDiet([])
        #expect(store.dietCodes.isEmpty && store.shownDishes.count == 3)
    }
}
