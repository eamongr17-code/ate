import Foundation
import Testing

@testable import AteKit

// MARK: - The contract, on the wire

@Suite("Feed edition — the wire")
struct FeedEditionWireTests {
    private static let dish = "11111111-1111-4111-8111-111111111111"
    private static let other = "22222222-2222-4222-8222-222222222222"
    private static let place = "33333333-3333-4333-8333-333333333333"

    @Test("top_ate: ranked 1…n whatever order the rows come in; saved and unscored read as sent")
    func topAte() throws {
        let json = """
        [{"rank":2,"dish_id":"\(Self.other)","name":"Prawn spaghetti","restaurant_id":"\(Self.place)",
          "restaurant_name":"Grossi Florentino","suburb":"CBD","score":null,"review_count":3,
          "cover_url":null,"saved":false},
         {"rank":1,"dish_id":"\(Self.dish)","name":"Tagliatelle al ragù","restaurant_id":"\(Self.place)",
          "restaurant_name":"Tipo 00","suburb":"CBD","score":4.9,"review_count":12,
          "cover_url":"https://x/y.jpg","saved":true}]
        """
        let lines = try FeedEditionClient.decodeTopAte(Data(json.utf8))
        #expect(lines.map(\.rank) == [1, 2])
        #expect(lines.map(\.number) == ["01", "02"])
        #expect(lines[0].dish.isSaved)
        #expect(lines[0].dish.score == 4.9)
        #expect(lines[1].dish.score == nil, "an unscored dish is never a zero (design rule 7)")
        #expect(lines[1].dish.coverURLString == nil)
    }

    @Test("new_to_record: the three kinds; an unknown kind drops its row, not the list")
    func newToRecord() throws {
        let json = """
        [{"dish_id":"\(Self.dish)","name":"Tiramisu","restaurant_name":"Bar Liberty","suburb":"Collingwood",
          "kind":"six","cover_url":null,"saved":false,"at":"2026-09-28T10:00:00.123456+00:00"},
         {"dish_id":"\(Self.other)","name":"Toro","restaurant_name":"Minamishima","suburb":null,
          "kind":"seven","cover_url":null,"saved":false,"at":"2026-09-28T10:00:00+00:00"}]
        """
        let rows = try FeedEditionClient.decodeNew(Data(json.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].kind == .six)
        #expect(rows[0].badge == "★6")
        #expect(rows[0].dish.restaurantID == nil, "new_to_record carries no restaurant id")
        #expect(NewDish.Kind.allBadges == ["★6", "★5", "New"])
    }

    @Test("because_you_loved: anchor on every row, or once around the rows; no rows is no shelf")
    func loved() throws {
        let rows = """
        [{"anchor_dish_id":"\(Self.dish)","anchor_name":"Tagliatelle","dish_id":"\(Self.other)",
          "name":"Penne alla vodka","restaurant_id":"\(Self.place)","restaurant_name":"Bar Carolina",
          "score":4.6,"review_count":4,"cover_url":null,"saved":true}]
        """
        let shelf = try #require(try FeedEditionClient.decodeLoved(Data(rows.utf8)))
        #expect(shelf.anchorName == "Tagliatelle")
        #expect(shelf.dishes.map(\.name) == ["Penne alla vodka"])
        #expect(shelf.dishes[0].isSaved)

        let wrapped = """
        {"anchor_dish_id":"\(Self.dish)","anchor_name":"Tagliatelle","dishes":[
          {"dish_id":"\(Self.other)","name":"Penne","restaurant_id":"\(Self.place)","restaurant_name":"Bar"}]}
        """
        #expect(try FeedEditionClient.decodeLoved(Data(wrapped.utf8))?.dishes.count == 1)
        #expect(try FeedEditionClient.decodeLoved(Data("[]".utf8)) == nil, "signed out, or no 5.0 yet")
    }

    @Test("cravings: a kind this build does not know is dropped; options need a group")
    func cravings() throws {
        let mine = """
        [{"kind":"style","slug":"pasta","label":"pasta"},{"kind":"mood","slug":"late","label":"Late night"}]
        """
        let cravings = try FeedEditionClient.decodeCravings(Data(mine.utf8))
        #expect(cravings.map(\.title) == ["Pasta"])
        let options = """
        [{"kind":"cuisine","slug":"italian","label":"Italian","group":"cuisines"},
         {"kind":"style","slug":"pasta","label":"pasta","group":"dishes"},
         {"kind":"style","slug":"x","label":"x","group":"weather"}]
        """
        let decoded = try FeedEditionClient.decodeOptions(Data(options.utf8))
        #expect(decoded.map(\.group) == [.cuisines, .dishes])
    }

    @Test("p_city is only sent when there is a city; set_cravings sends kind and slug")
    func parameters() {
        #expect(FeedEditionClient.cityParameters(nil, limit: 8)["p_city"] == nil)
        #expect(FeedEditionClient.cityParameters("melbourne", limit: 8)["p_city"] == .string("melbourne"))
        #expect(DishExploreClient.tagParameters(kind: .style, slug: "pasta", city: nil, limit: 10)["p_city"] == nil)
        #expect(DishExploreClient.tagParameters(kind: .style, slug: "pasta", city: "sydney", limit: 10)["p_city"]
            == .string("sydney"))
        let set = FeedEditionClient.cravingsParameter([Craving(kind: .cuisine, slug: "italian", label: "Italian")])
        #expect(set == .array([.object(["kind": .string("cuisine"), "slug": .string("italian")])]))
    }

    @Test("Because you loved reads the dish mid-sentence, leaving acronyms alone")
    func lovedTitle() {
        #expect(LovedShelf.midSentence("Tagliatelle") == "tagliatelle")
        #expect(LovedShelf.midSentence("BBQ pork") == "BBQ pork")
        #expect(LovedShelf.midSentence("X") == "X")
        let shelf = LovedShelf(anchorDishID: UUID(), anchorName: "Tagliatelle", dishes: [])
        #expect(shelf.title == "Because you loved tagliatelle")
    }

    @Test("A craving shelf's See all is the tag's own page, in the Feed's city")
    func seeAllRoute() {
        let route = Craving(kind: .style, slug: "pasta", label: "pasta").route(city: "melbourne")
        #expect(route == DishTagRoute(kind: .style, slug: "pasta", label: "Pasta", city: "melbourne"))
    }
}

private extension NewDish.Kind {
    static var allBadges: [String] {
        [Self.six, .five, .new].map { NewDish(kind: $0, dish: FeedDish(dishID: UUID(), name: "", restaurantName: ""),
                                              at: .now).badge }
    }
}

// MARK: - The store

/// An edition in memory: every section seeded, each one able to fail. Anything not seeded is empty.
private final class Edition: FeedEditionReading, TestFake, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    var top: [TopAteLine] = []
    var loved: LovedShelf?
    var fresh: [NewDish] = []
    var cravings: [Craving] = []
    var shelves: [String: [FeedDish]] = [:]
    var failing: Set<String> = []
    private(set) var calls: [String] = []
    private(set) var sinces: [Date] = []
    private(set) var cities: [String?] = []
    private(set) var setTo: [[Craving]] = []

    private func note(_ call: String) throws {
        try lock.withLock {
            calls.append(call)
            if failing.contains(call) { throw Failure() }
        }
    }

    func topAte(city: String?, limit: Int) async throws -> [TopAteLine] {
        try note("top_ate")
        lock.withLock { cities.append(city) }
        return top
    }

    func becauseYouLoved(city: String?, limit: Int) async throws -> LovedShelf? {
        try note("because_you_loved")
        return loved
    }

    func newToRecord(city: String?, since: Date, limit: Int) async throws -> [NewDish] {
        try note("new_to_record")
        lock.withLock { sinces.append(since) }
        return fresh
    }

    func myCravings() async throws -> [Craving] {
        try note("my_cravings")
        return cravings
    }

    func setCravings(_ cravings: [Craving]) async throws -> [Craving] {
        try note("set_cravings")
        lock.withLock { setTo.append(cravings) }
        var seen: Set<String> = []
        return cravings.filter { seen.insert($0.id).inserted }
    }

    func cravingDishes(_ craving: Craving, city: String?, limit: Int) async throws -> [FeedDish] {
        try note("dishes_by_tag:\(craving.slug)")
        return shelves[craving.slug] ?? []
    }
}

@MainActor
@Suite("Feed edition — the store")
struct FeedEditionStoreTests {
    private static let pasta = Craving(kind: .style, slug: "pasta", label: "pasta")
    private static let dessert = Craving(kind: .style, slug: "dessert", label: "dessert")
    private static let ramen = Craving(kind: .style, slug: "ramen", label: "ramen")

    private static func dish(_ name: String, saved: Bool = false) -> FeedDish {
        FeedDish(dishID: UUID(), name: name, restaurantName: "Tipo 00", score: 4.5, isSaved: saved)
    }

    private static func seeded() -> Edition {
        let edition = Edition()
        edition.top = [TopAteLine(rank: 1, dish: dish("Tagliatelle")), TopAteLine(rank: 2, dish: dish("Tiramisu"))]
        edition.loved = LovedShelf(anchorDishID: UUID(), anchorName: "Tagliatelle", dishes: [dish("Penne")])
        edition.fresh = [NewDish(kind: .six, dish: dish("Toro"), at: .now)]
        edition.cravings = [pasta, dessert, ramen]
        edition.shelves = ["pasta": [dish("Ragù")], "dessert": [dish("Cheesecake")]]
        return edition
    }

    private static func store(
        _ reads: Edition,
        signedIn: Bool = true,
        keys: InMemoryKeyValueStore = InMemoryKeyValueStore(),
        log: EventLog = EventLog(),
        broadcast: SavedDishBroadcast? = nil,
        now: Date = Date(timeIntervalSince1970: 2_000_000_000)
    ) -> FeedEditionStore {
        let owner = UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        return FeedEditionStore(
            reads: reads, store: keys, owner: { owner }, isSignedIn: { signedIn }, city: { "melbourne" },
            analytics: log.recorder, savedDishes: broadcast, now: { now }
        )
    }

    @Test("Signed in: every section, a shelf per craving with dishes, in the cravings' order")
    func signedIn() async {
        let store = Self.store(Self.seeded())
        await store.loadIfNeeded()
        #expect(store.showsTopAte && store.showsLoved && store.showsNew && store.showsChooseCravings)
        #expect(store.visibleShelves.map(\.craving.slug) == ["pasta", "dessert"],
                "ramen has no dishes, so no shelf — a section with no rows does not render")
        #expect(store.city == "melbourne")
    }

    @Test("Signed out: The Top Ate only — the personal sections are neither read nor shown")
    func signedOut() async {
        let reads = Self.seeded()
        let store = Self.store(reads, signedIn: false)
        await store.loadIfNeeded()
        #expect(store.showsTopAte)
        #expect(store.showsLoved == false && store.showsNew == false && store.visibleShelves.isEmpty)
        #expect(store.showsChooseCravings == false)
        #expect(reads.calls == ["top_ate"])
    }

    @Test("A read that fails is an absent section on first load, and keeps what is up on a refresh")
    func failures() async {
        let reads = Self.seeded()
        reads.failing = ["because_you_loved"]
        let store = Self.store(reads)
        await store.loadIfNeeded()
        #expect(store.showsLoved == false)
        #expect(store.showsTopAte, "one section's failure does not take the others down")

        reads.failing = []
        await store.refresh()
        #expect(store.showsLoved)
        reads.failing = ["top_ate", "because_you_loved"]
        await store.refresh()
        #expect(store.topAte.count == 2 && store.showsLoved, "a failed refresh keeps the page")
    }

    @Test("Nothing anywhere: the edition is empty and the cravings row still stands")
    func empty() async {
        let store = Self.store(Edition())
        await store.loadIfNeeded()
        #expect(store.isEmpty)
        #expect(store.showsChooseCravings)
    }

    @Test("New to the record asks since the last open, and this open is remembered for the next")
    func lastOpened() async {
        let keys = InMemoryKeyValueStore()
        let first = Date(timeIntervalSince1970: 2_000_000_000)
        let reads = Self.seeded()
        let store = Self.store(reads, keys: keys, now: first)
        await store.loadIfNeeded()
        #expect(reads.sinces == [first.addingTimeInterval(-FeedEditionStore.firstLookBack)],
                "a first open looks back a week")
        await store.refresh()
        #expect(reads.sinces.last == reads.sinces.first, "a refresh keeps asking about the same since")

        let later = first.addingTimeInterval(3600)
        let next = Self.store(reads, keys: keys, now: later)
        await next.loadIfNeeded()
        #expect(reads.sinces.last == first, "the next session asks from this one's open")
    }

    @Test("A save made anywhere flips the dish in every section that shows it")
    func saves() async {
        let reads = Self.seeded()
        let shared = Self.dish("Tagliatelle")
        reads.top = [TopAteLine(rank: 1, dish: shared)]
        reads.shelves = ["pasta": [shared]]
        let broadcast = SavedDishBroadcast()
        let store = Self.store(reads, broadcast: broadcast)
        await store.loadIfNeeded()
        broadcast.send(dishID: shared.dishID, isSaved: true)
        #expect(store.topAte[0].dish.isSaved)
        #expect(store.visibleShelves[0].dishes[0].isSaved)
        broadcast.send(dishID: shared.dishID, isSaved: false)
        #expect(store.topAte[0].dish.isSaved == false)
    }

    @Test("Choosing cravings replaces the whole set, is counted, and reads the new shelves")
    func chooseCravings() async {
        let reads = Self.seeded()
        let log = EventLog()
        let store = Self.store(reads, log: log)
        await store.loadIfNeeded()
        let saved = await store.saveCravings([Self.dessert])
        #expect(saved)
        #expect(reads.setTo == [[Self.dessert]])
        #expect(store.cravings == [Self.dessert])
        #expect(store.visibleShelves.map(\.craving.slug) == ["dessert"])
        #expect(log.first(named: "cravings_set")?.parameters == ["count": "1"])

        _ = await store.saveCravings([Self.dessert, Self.dessert])
        #expect(store.cravings == [Self.dessert], "the set is the server's answer — duplicates collapsed")

        reads.failing = ["set_cravings"]
        let refused = await store.saveCravings([])
        #expect(refused == false)
        #expect(store.cravings == [Self.dessert], "a refusal leaves the set as it was")
        #expect(log.events(named: "cravings_set").count == 2)
    }

    @Test("feed_section_viewed: once per section per visit")
    func sectionViewed() async {
        let log = EventLog()
        let store = Self.store(Self.seeded(), log: log)
        store.beginVisit()
        store.sectionAppeared(.topAte)
        store.sectionAppeared(.topAte)
        store.sectionAppeared(.cravingShelf)
        #expect(log.events(named: "feed_section_viewed").map { $0.parameters["section"] }
            == ["top_ate", "craving_shelf"])
        store.beginVisit()
        store.sectionAppeared(.topAte)
        #expect(log.events(named: "feed_section_viewed").count == 3)
    }

    @Test("See all's tag page is read in the Feed's city; a dish page's chip reads everywhere")
    func tagPageCity() async {
        let reads = FakeDishExplore()
        let shelf = TagDishesStore(tag: Self.pasta.route(city: "melbourne"), reads: reads)
        await shelf.loadIfNeeded()
        let chip = TagDishesStore(tag: DishTagRoute(DishTag(kind: .style, slug: "pasta", label: "pasta")), reads: reads)
        await chip.loadIfNeeded()
        #expect(reads.tagCities == ["melbourne", nil])
    }

    @Test("A new city starts from nothing")
    func reload() async {
        let reads = Self.seeded()
        let store = Self.store(reads)
        await store.loadIfNeeded()
        reads.top = []
        await store.reload()
        #expect(store.showsTopAte == false)
    }
}

// MARK: - The picker and the events

@Suite("Feed edition — the picker and events")
struct CravingPickerTests {
    private static func option(_ slug: String, _ group: CravingOption.Group) -> CravingOption {
        CravingOption(craving: Craving(kind: group == .cuisines ? .cuisine : .style, slug: slug, label: slug),
                      group: group)
    }

    @Test("Groups print dishes, cuisines, moods — and a group with no chips is not there")
    func groups() {
        let picker = CravingPicker(options: [Self.option("italian", .cuisines), Self.option("pasta", .dishes)],
                                   selected: [])
        #expect(picker.groups.map(\.group) == [.dishes, .cuisines])
    }

    @Test("A toggle ticks and unticks; new cravings join the end of the set")
    func toggles() {
        let pasta = Self.option("pasta", .dishes), ramen = Self.option("ramen", .dishes)
        var picker = CravingPicker(options: [pasta, ramen], selected: [ramen.craving])
        picker.toggle(pasta)
        #expect(picker.selection.map(\.slug) == ["ramen", "pasta"])
        #expect(picker.isOn(pasta))
        picker.toggle(ramen)
        #expect(picker.selection.map(\.slug) == ["pasta"])
    }

    @Test("set_cravings keeps 24 at most, so the 25th chip does not tick")
    func cap() {
        let options = (0...CravingPicker.maximum).map { Self.option("tag\($0)", .dishes) }
        var picker = CravingPicker(options: options, selected: [])
        options.forEach { picker.toggle($0) }
        #expect(picker.selection.count == CravingPicker.maximum)
        #expect(picker.isOn(options[CravingPicker.maximum]) == false)
    }

    @Test("The edition's events, by name")
    func events() {
        #expect(FeedEvents.sectionViewed(.becauseYouLoved)
            == AnalyticsEvent(name: "feed_section_viewed", parameters: ["section": "because_you_loved"]))
        #expect(FeedEvents.dishSaved(.newToRecord)
            == AnalyticsEvent(name: "feed_dish_saved", parameters: ["section": "new_to_record"]))
        #expect(FeedEvents.cravingsSet(count: 3) == AnalyticsEvent(name: "cravings_set", parameters: ["count": "3"]))
    }
}
