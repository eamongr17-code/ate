import Foundation
import Testing
@testable import AteKit

@Suite("Diet — what a person always eats")
struct DietChoiceTests {
    @Test("the ten names, and the eater each counts")
    func names() {
        #expect(DietTag.allCases.map(\.dietName) == [
            "Gluten free", "Dairy free", "Vegetarian", "Vegan", "Nut free",
            "Pescatarian", "Halal", "Egg free", "Peanut free", "Shellfish free"
        ])
        #expect(DietTag.allCases.map(\.eaterWord) == [
            "gluten-free", "dairy-free", "vegetarian", "vegan", "nut-free",
            "pescatarian", "halal", "egg-free", "peanut-free", "shellfish-free"
        ])
    }

    @Test("picking order: the diets, then the allergies — every code once")
    func pickingOrder() {
        #expect(DietTag.diets == [.v, .vg, .pe, .ha, .df])
        #expect(DietTag.allergies == [.gf, .ef, .nf, .pf, .sf])
        #expect(Set(DietTag.pickingOrder) == Set(DietTag.allCases) && DietTag.pickingOrder.count == 10)
        #expect(DietTag.allergies.allSatisfy(\.isAllergy) && DietTag.diets.allSatisfy { $0.isAllergy == false })
    }

    @Test("Vegetarian covers Pescatarian; Nut free covers Peanut free")
    func otherCovers() throws {
        let vegetarian = try #require(DietChoice().toggling(.v))
        #expect(vegetarian.isCovered(.pe) && vegetarian.isCovered(.df) == false)
        let nuts = try #require(DietChoice([.pf]).toggling(.nf))
        #expect(nuts.codes == [.nf] && nuts.isCovered(.pf))
        #expect(nuts.isCovered(.sf) == false)
    }

    @Test("Vegan covers Vegetarian, Pescatarian, Dairy free and Egg free: lit, locked, never stored")
    func veganCovers() throws {
        let vegan = try #require(DietChoice().toggling(.vg))
        #expect(vegan.codes == [.vg])
        #expect(vegan.isCovered(.v) && vegan.isCovered(.df) && vegan.isCovered(.pe) && vegan.isCovered(.ef))
        #expect(vegan.isCovered(.gf) == false)
        #expect(vegan.toggling(.v) == nil, "a covered code does nothing")
        // Picking Vegan over Vegetarian takes Vegetarian out of the picks.
        let both = try #require(DietChoice([.v]).toggling(.vg))
        #expect(both.codes == [.vg])
        // …and a stored set that somehow holds both reads as Vegan alone.
        #expect(DietChoice([.v, .vg, .df]).codes == [.vg])
        // Vegan off: nothing is covered any more.
        let off = try #require(vegan.toggling(.vg))
        #expect(off.isEmpty && off.isCovered(.v) == false)
    }

    @Test("the Settings row says what is saved")
    func summary() {
        #expect(DietChoice([.vg]).summary == "Vegan")
        #expect(DietChoice([.nf, .gf]).summary == "Gluten free, Nut free")
        #expect(DietChoice().summary == "None")
        #expect(DietChoice([.pf, .ha]).summary == "Halal, Peanut free", "diets first, as Settings lists them")
    }
}

@Suite("Diet — labels and counts on a dish")
struct DietLabelTests {
    @Test("diet_counts decodes leniently; an older server has none")
    func countsDecode() throws {
        let id = UUID()
        let place = UUID()
        let base = #"{"dish_id":"\#(id)","dish_name":"Mushroom Bao","restaurant_id":"\#(place)","#
            + #""restaurant_name":"Lucy Liu","tags":["gf"]"#
        let counted = try PostgRESTDate.decoder.decode(
            DishSummary.self, from: Data((base + #","diet_counts":{"vg":2,"xx":1,"nf":0,"df":1}}"#).utf8)
        )
        #expect(counted.dietCounts[.vg] == 2)
        #expect(counted.dietCounts.codes == [.df, .vg])
        #expect(counted.dietSignals == [.orderedBy(.df, count: 1), .orderedBy(.vg, count: 2)])
        let older = try PostgRESTDate.decoder.decode(DishSummary.self, from: Data((base + "}").utf8))
        #expect(older.dietCounts.isEmpty)
        let null = try PostgRESTDate.decoder.decode(
            DishSummary.self, from: Data((base + #","diet_counts":null}"#).utf8)
        )
        #expect(null.dietCounts.isEmpty)
    }

    @Test("a place's dish row carries diet_counts too")
    func menuCounts() throws {
        let row = #"{"dish_id":"\#(UUID())","dish_name":"Mushroom Bao","score":4.5,"#
            + #""people_count":4,"review_count":4,"tags":[],"diet_counts":{"vg":2}}"#
        let dish = try JSONDecoder().decode(MenuDish.self, from: Data(row.utf8))
        #expect(dish.dietCounts[.vg] == 2)
    }

    @Test("counts round-trip as {code: n}")
    func countsEncode() throws {
        let data = try JSONEncoder().encode(DietCounts([.vg: 2]))
        #expect(String(bytes: data, encoding: .utf8) == #"{"vg":2}"#)
        #expect(try JSONDecoder().decode(DietCounts.self, from: data) == DietCounts([.vg: 2]))
    }

    @Test("the literal line: 'Ordered by N … eaters', singular at one")
    func line() {
        #expect(DietSignal.orderedBy(.vg, count: 2).line == "Ordered by 2 vegan eaters")
        #expect(DietSignal.orderedBy(.gf, count: 1).line == "Ordered by 1 gluten-free eater")
        #expect(DietSignal.orderedBy(.nf, count: 2).line == "Ordered by 2 nut-free eaters")
        #expect(DietSignal.labelled(.vg).line == nil)
    }

    @Test("the \"?\" popover: the labels first, then every other counted code")
    func popoverLines() {
        let counts = DietCounts([.vg: 5, .ha: 4, .gf: 2, .nf: 6])
        #expect(DietCountLine.dish(tags: [.vg, .nf, .ha], counts: counts) == [
            DietCountLine(tag: .vg, people: 5), DietCountLine(tag: .nf, people: 6),
            DietCountLine(tag: .ha, people: 4), DietCountLine(tag: .gf, people: 2)
        ])
        // An older server counts only below the label: the label still gets its line, at 3+.
        #expect(DietCountLine.dish(tags: [.v], counts: DietCounts([.gf: 1])) == [
            DietCountLine(tag: .v, people: nil), DietCountLine(tag: .gf, people: 1)
        ])
        #expect(DietCountLine(tag: .v, people: nil).peopleText == "3+")
        #expect(DietCountLine(tag: .v, people: 4).peopleText == "4")
        #expect(DietCountLine.dish(tags: [], counts: DietCounts()).isEmpty)
    }

    @Test("the dish page says nothing more about a labelled code")
    func belowLabel() {
        let counts = DietCounts([.vg: 2, .gf: 1])
        #expect(DietSignal.belowLabel(tags: [.vg], counts: counts) == [.orderedBy(.gf, count: 1)])
    }

    @Test("with a place's chips on: labelled or counted passes, and says which")
    func filter() {
        let none = DietCounts()
        let two = DietCounts([.vg: 2])
        #expect(DietSignal.passes([.vg], tags: [.vg], counts: none))
        #expect(DietSignal.passes([.vg], tags: [], counts: two))
        #expect(DietSignal.passes([.vg], tags: [.gf], counts: none) == false)
        #expect(DietSignal.passes([.vg, .gf], tags: [.vg], counts: none) == false, "every chip that is on")
        #expect(DietSignal.passes([], tags: [], counts: none), "no chips on: every dish")
        #expect(DietSignal.forFilter([.vg], tags: [.vg], counts: none) == [.labelled(.vg)])
        #expect(DietSignal.forFilter([.vg], tags: [], counts: two) == [.orderedBy(.vg, count: 2)])
    }
}

@Suite("Diet — your own entries")
struct DietOwnEntryTests {
    private func item(tags: [String], diet: [String]?) throws -> EntryCard.Item {
        var json = #"{"review_id":"\#(UUID())","dish_id":"\#(UUID())","dish_name":"Mushroom Bao","position":1,"#
            + #""tags":[\#(tags.map { "\"\($0)\"" }.joined(separator: ","))]"#
        if let diet { json += #","diet_tags":[\#(diet.map { "\"\($0)\"" }.joined(separator: ","))]"# }
        return try JSONDecoder().decode(EntryCard.Item.self, from: Data((json + "}").utf8))
    }

    @Test("diet_tags decode; the author doesn't see them, everyone else does")
    func hidden() throws {
        let bao = try item(tags: ["vg", "gf"], diet: ["vg"])
        #expect(bao.dietTags == [.vg])
        #expect(bao.shownTags(isMine: true) == [.gf])
        #expect(bao.shownTags(isMine: false) == [.vg, .gf])
        #expect(bao.typedTags == [.gf])
        let older = try item(tags: ["v"], diet: nil)
        #expect(older.dietTags.isEmpty)
        #expect(older.shownTags(isMine: true) == [.v])
        // A diet code that is not on the line any more (turned off) is not hidden from anything.
        let off = try item(tags: [], diet: ["vg"])
        #expect(off.dietTags.isEmpty)
    }

    @Test("a diet code is never looked for in the words — only typed ones are chips")
    func notInTheWords() {
        let card = EntryCard(
            id: UUID(), authorID: UUID(), body: "Prawn toast V 4.0", orderNumber: 1, sortStatus: .sorted,
            createdAt: Date(),
            items: [EntryCard.Item(
                reviewID: UUID(), dishID: UUID(), dishName: "Prawn toast", score: Rating(exactly: 4), position: 1,
                mentionOffset: 0, mentionLength: 11, tags: [.v], dietTags: [.v]
            )]
        )
        #expect(EntryBodyTokens.composition(for: card).tags.isEmpty)
    }
}

@Suite("Diet — events")
struct DietEventsTests {
    @Test("each event carries its name and parameters")
    func names() {
        #expect(DietEvents.set(source: .onboarding, codes: [.gf, .vg])
            == AnalyticsEvent(name: "diet_set", parameters: ["source": "onboarding", "codes": "gf,vg"]))
        #expect(DietEvents.set(source: .settings, codes: [])
            == AnalyticsEvent(name: "diet_set", parameters: ["source": "settings", "codes": "none"]))
        #expect(DietEvents.turnedOff(.vg, isEdit: false)
            == AnalyticsEvent(name: "diet_tag_turned_off", parameters: ["code": "vg", "edit": "false"]))
        #expect(DietEvents.turnedOn(.vg, isEdit: true)
            == AnalyticsEvent(name: "diet_tag_turned_on", parameters: ["code": "vg", "edit": "true"]))
        let place = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!
        #expect(DietEvents.placeFilterToggled(.vg, isOn: false, restaurantID: place) == AnalyticsEvent(
            name: "place_diet_filter_toggled",
            parameters: ["code": "vg", "on": "false", "restaurant_id": "b7e00000-0000-4000-8000-000000000001"]
        ))
        #expect(DietEvents.countsOpened(surface: .dish)
            == AnalyticsEvent(name: "diet_counts_opened", parameters: ["surface": "dish"]))
        #expect(DietEvents.countsOpened(surface: .place, code: .pf)
            == AnalyticsEvent(name: "diet_counts_opened", parameters: ["surface": "place", "code": "pf"]))
    }
}

@MainActor
@Suite("Diet — the store")
struct DietStoreTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [AnalyticsEvent] = []
        var events: [AnalyticsEvent] { lock.withLock { log } }
        func record(_ event: AnalyticsEvent) { lock.withLock { log.append(event) } }
    }

    @Test("Settings: a tap saves the whole set at once, and is counted")
    func toggleSaves() async {
        let account = InMemoryAccountService()
        let recorder = Recorder()
        let store = DietStore(account: account) { recorder.record($0) }
        await store.loadIfNeeded()
        #expect(store.choice == DietChoice())
        #expect(await store.toggle(.vg))
        #expect(account.storedDiet == [.vg])
        #expect(store.choice?.summary == "Vegan")
        #expect(await store.toggle(.gf))
        #expect(account.storedDiet == [.gf, .vg])
        // A covered code does nothing, and writes nothing.
        #expect(await store.toggle(.v))
        #expect(account.storedDiet == [.gf, .vg])
        #expect(recorder.events.last == DietEvents.set(source: .settings, codes: [.gf, .vg]))
        #expect(recorder.events.count == 2)
    }

    @Test("a refused write puts the tick back")
    func refused() async {
        let account = InMemoryAccountService()
        let store = DietStore(account: account)
        await store.loadIfNeeded()
        account.failure = URLError(.notConnectedToInternet)
        #expect(await store.toggle(.nf) == false)
        #expect(store.codes == [])
    }

    @Test("onboarding: Next writes the picks; None of these writes nothing")
    func onboarding() async throws {
        let account = InMemoryAccountService()
        let recorder = Recorder()
        let store = DietStore(account: account) { recorder.record($0) }
        store.declined()
        #expect(account.storedDiet == [])
        #expect(recorder.events == [DietEvents.set(source: .onboarding, codes: [])])
        let picked = try #require(DietChoice().toggling(.gf)?.toggling(.vg))
        #expect(await store.save(picked, source: .onboarding))
        #expect(account.storedDiet == [.gf, .vg])
        #expect(store.codes == [.gf, .vg])
    }
}
