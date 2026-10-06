import Foundation
import Testing

@testable import AteKit

/// The cravings rethink and the editorial category page (`design/rebuild/discover.html`, 4 Oct).

/// The reads, in memory: each able to fail, every write recorded.
private final class Reads: FeedEditionReading, TestFake, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    var cravings: [Craving] = []
    var options: [CravingOption] = []
    var dishes: [String: [FeedDish]] = [:]
    var fresh: [NewDish]?
    var receipts: [EntryCard]?
    var failing: Set<String> = []
    private(set) var calls: [String] = []
    private(set) var setTo: [[Craving]] = []

    private func note(_ call: String) throws {
        try lock.withLock {
            calls.append(call)
            if failing.contains(call) { throw Failure() }
        }
    }

    func topAte(city: String?, limit: Int) async throws -> [TopAteLine] {
        try note("top_ate")
        return [TopAteLine(rank: 1, dish: FeedDish(dishID: UUID(), name: "Ragù", restaurantName: "Tipo 00"))]
    }

    func becauseYouLoved(city: String?, limit: Int) async throws -> LovedShelf? { nil }

    func newToRecord(city: String?, since: Date, limit: Int) async throws -> [NewDish] { [] }

    func myCravings() async throws -> [Craving] {
        try note("my_cravings")
        return lock.withLock { cravings }
    }

    func cravingOptions() async throws -> [CravingOption] {
        try note("craving_options")
        return options
    }

    func setCravings(_ next: [Craving]) async throws -> [Craving] {
        try note("set_cravings")
        return lock.withLock {
            setTo.append(next)
            var seen: Set<String> = []
            cravings = next.filter { seen.insert($0.id).inserted }
            return cravings
        }
    }

    func cravingDishes(_ craving: Craving, city: String?, limit: Int) async throws -> [FeedDish] {
        try note("dishes_by_tag:\(craving.slug)")
        return Array((dishes[craving.slug] ?? []).prefix(limit))
    }

    func newToRecord(tag: Craving, city: String?, since: Date, limit: Int) async throws -> [NewDish] {
        try note("new_to_record:\(tag.slug)")
        guard let fresh else { throw FeedEditionReadUnavailable() }
        return fresh
    }

    func latestReceipts(tag: Craving, city: String?, limit: Int) async throws -> [EntryCard] {
        try note("get_entry_feed:\(tag.slug)")
        guard let receipts else { throw FeedEditionReadUnavailable() }
        return receipts
    }
}

private func craving(_ slug: String, _ kind: DishTag.Kind = .style) -> Craving {
    Craving(kind: kind, slug: slug, label: slug)
}

private func dish(_ name: String, at place: UUID? = UUID(), score: Double? = 4.5) -> FeedDish {
    FeedDish(dishID: UUID(), name: name, restaurantID: place, restaurantName: "Place \(name)", score: score)
}

// MARK: - Asked once

@MainActor
@Suite("Cravings — asked once")
struct CravingsAskTests {
    static let person = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let slugs = ["pasta", "dumplings", "curry", "ramen", "noodles", "pizza", "tacos", "pho"]

    fileprivate static func reads(following: [Craving] = []) -> Reads {
        let reads = Reads()
        reads.cravings = following
        reads.options = slugs.map { CravingOption(craving: craving($0), group: .dishes) }
        return reads
    }

    fileprivate static func store(
        _ reads: Reads,
        preferences: AtePreferences,
        signedIn: Bool = true,
        log: EventLog = EventLog(),
        person: UUID? = CravingsAskTests.person
    ) -> FeedEditionStore {
        FeedEditionStore(
            reads: reads, store: InMemoryKeyValueStore(), owner: { person }, isSignedIn: { signedIn },
            city: { "melbourne" }, analytics: log.recorder, preferences: preferences
        )
    }

    @Test("Following nothing and never answered: one card, the first six options, shown once")
    func shown() async {
        let log = EventLog()
        let store = Self.store(Self.reads(), preferences: AtePreferences(store: InMemoryKeyValueStore()), log: log)
        await store.loadIfNeeded()
        #expect(store.showsAsk)
        #expect(store.askOptions.map(\.craving.slug) == Array(Self.slugs.prefix(6)))
        #expect(store.showsFollowing == false, "nothing followed: no What you follow row")
        store.askAppeared()
        store.askAppeared()
        #expect(log.events(named: "cravings_ask_shown").count == 1)
        #expect(log.first(named: "cravings_ask_shown")?.parameters == ["options": "6"])
    }

    @Test("A tap follows at once; the third pick folds the card, for good, for this person")
    func threePicks() async {
        let reads = Self.reads()
        let log = EventLog()
        let keys = InMemoryKeyValueStore()
        let store = Self.store(reads, preferences: AtePreferences(store: keys), log: log)
        await store.loadIfNeeded()
        let options = store.askOptions

        await store.pickFromAsk(options[1])
        #expect(reads.setTo.last == [options[1].craving], "followed immediately with set_cravings")
        #expect(store.showsAsk, "one pick: the card stands")
        #expect(store.cravings == [options[1].craving])
        #expect(store.showsFollowing)

        await store.pickFromAsk(options[2])
        await store.pickFromAsk(options[0])
        #expect(reads.setTo.last == [options[1], options[2], options[0]].map(\.craving), "in the order picked")
        #expect(store.showsAsk == false, "the third pick folds it")
        #expect(log.events(named: "cravings_ask_picked").map(\.parameters)
            == [["pick": "1"], ["pick": "2"], ["pick": "3"]])
        #expect(log.events(named: "craving_followed").last?.parameters == ["source": "ask", "count": "3"])

        // Next launch, same phone: everything unfollowed again, and still never asked twice.
        reads.cravings = []
        let next = Self.store(reads, preferences: AtePreferences(store: keys))
        await next.loadIfNeeded()
        #expect(next.showsAsk == false)
        // …but somebody else on the phone is asked.
        let other = Self.store(reads, preferences: AtePreferences(store: keys), person: UUID())
        await other.loadIfNeeded()
        #expect(other.showsAsk)
    }

    @Test("A picked pill tapped again unfollows and does not count toward the three")
    func untap() async {
        let reads = Self.reads()
        let store = Self.store(reads, preferences: AtePreferences(store: InMemoryKeyValueStore()))
        await store.loadIfNeeded()
        let option = store.askOptions[0]
        await store.pickFromAsk(option)
        await store.pickFromAsk(option)
        #expect(store.askPicks.isEmpty)
        #expect(reads.setTo.last == [])
        #expect(store.showsAsk)
    }

    @Test("The close folds it for good and is counted with its picks")
    func close() async {
        let keys = InMemoryKeyValueStore()
        let log = EventLog()
        let reads = Self.reads()
        let store = Self.store(reads, preferences: AtePreferences(store: keys), log: log)
        await store.loadIfNeeded()
        await store.pickFromAsk(store.askOptions[3])
        store.dismissAsk()
        #expect(store.showsAsk == false)
        #expect(log.first(named: "cravings_ask_dismissed")?.parameters == ["picks": "1"])
        #expect(AtePreferences(store: keys).hasAnsweredCravingsAsk(Self.person))
        await store.refresh()
        #expect(store.showsAsk == false, "a refresh does not bring it back")
    }

    @Test("A refused pick puts the pill back")
    func refused() async {
        let reads = Self.reads()
        let store = Self.store(reads, preferences: AtePreferences(store: InMemoryKeyValueStore()))
        await store.loadIfNeeded()
        reads.failing = ["set_cravings"]
        await store.pickFromAsk(store.askOptions[0])
        #expect(store.askPicks.isEmpty)
        #expect(store.showsAsk)
    }

    @Test("Never asked: somebody who follows something, a browser, or no options")
    func notAsked() async {
        let following = Self.store(Self.reads(following: [craving("curry")]),
                                   preferences: AtePreferences(store: InMemoryKeyValueStore()))
        await following.loadIfNeeded()
        #expect(following.showsAsk == false)
        #expect(following.showsFollowing)

        let browsing = Self.reads()
        let signedOut = Self.store(browsing, preferences: AtePreferences(store: InMemoryKeyValueStore()),
                                   signedIn: false)
        await signedOut.loadIfNeeded()
        #expect(signedOut.showsAsk == false)
        #expect(browsing.calls.contains("craving_options") == false)

        let bare = Self.reads()
        bare.options = []
        let empty = Self.store(bare, preferences: AtePreferences(store: InMemoryKeyValueStore()))
        await empty.loadIfNeeded()
        #expect(empty.showsAsk == false)
    }

    @Test("Back on the Feed: a set changed on a category page brings its shelf")
    func refreshCravings() async {
        let reads = Self.reads(following: [craving("curry")])
        reads.dishes = ["curry": [dish("Rendang")], "ramen": [dish("Tonkotsu")]]
        let store = Self.store(reads, preferences: AtePreferences(store: InMemoryKeyValueStore()))
        await store.loadIfNeeded()
        #expect(store.visibleShelves.map(\.craving.slug) == ["curry"])
        reads.cravings = [craving("ramen"), craving("curry")]
        await store.refreshCravings()
        #expect(store.visibleShelves.map(\.craving.slug) == ["ramen", "curry"])
    }
}

// MARK: - The category page

@MainActor
@Suite("Category page — the edition")
struct TagEditionTests {
    static let curry = DishTagRoute(kind: .style, slug: "curry", label: "Curry", city: "melbourne")

    fileprivate static func store(
        _ reads: Reads, signedIn: Bool = true, log: EventLog = EventLog(), broadcast: SavedDishBroadcast? = nil
    ) -> TagEditionStore {
        TagEditionStore(tag: curry, reads: reads, isSignedIn: { signedIn }, analytics: log.recorder,
                        savedDishes: broadcast)
    }

    @Test("Places known for it: one card per place, its best dish, in the order served")
    func places() {
        let hoJiak = UUID(), tonka = UUID()
        let rows = [dish("Rendang", at: hoJiak), dish("Dal", at: tonka), dish("Fish head", at: hoJiak),
                    dish("Nowhere", at: nil)]
        let places = TagEdition.places(from: rows)
        #expect(places.map(\.dish.name) == ["Rendang", "Dal"])
        #expect(places.map(\.restaurantID) == [hoJiak, tonka])
        #expect(TagEdition.places(from: rows, limit: 1).count == 1)
    }

    @Test("The subtitle: the city it is read in, Everywhere, or nothing on a place's own tag")
    func cityTitle() {
        let reads = Reads()
        func title(_ tag: DishTagRoute) -> String? {
            TagEditionStore(tag: tag, reads: reads, isSignedIn: { true }, analytics: EventLog().recorder,
                            savedDishes: nil).cityTitle
        }
        #expect(title(Self.curry) == "Melbourne")
        #expect(title(DishTagRoute(kind: .style, slug: "curry", label: "Curry")) == "Everywhere")
        #expect(title(DishTagRoute(kind: .suburb, slug: "northcote-melbourne", label: "Northcote")) == nil)
        #expect(title(DishTagRoute(kind: .city, slug: "melbourne", label: "Melbourne")) == nil)
    }

    @Test("New in: a style mid-sentence, a cuisine as its own name")
    func newTitle() {
        #expect(TagEdition.newTitle(Self.curry) == "New in curry")
        #expect(TagEdition.newTitle(DishTagRoute(kind: .cuisine, slug: "vietnamese", label: "Vietnamese"))
            == "New in Vietnamese")
    }

    @Test("One read feeds the hero, ranks 2 to 8 and See all; new and receipts stand alone")
    func sections() async {
        let reads = Reads()
        reads.dishes = ["curry": (1...12).map { dish("Curry \($0)") }]
        reads.fresh = [NewDish(kind: .six, dish: dish("Vindaloo"), at: .now)]
        reads.receipts = Array(repeating: EntryCard.previewSorted, count: 1)
        reads.cravings = [craving("curry")]
        let store = Self.store(reads)
        await store.loadIfNeeded()
        #expect(store.phase == .ready)
        #expect(store.top.count == 8)
        #expect(store.hasMore)
        #expect(store.newDishes.count == 1)
        #expect(store.receipts.count == 1)
        #expect(store.isFollowing)
    }

    @Test("A read that fails or is not there yet hides its section, never the page")
    func hidden() async {
        let reads = Reads()
        reads.dishes = ["curry": [dish("Rendang")]]
        reads.fresh = nil
        reads.receipts = nil
        let store = Self.store(reads)
        await store.loadIfNeeded()
        #expect(store.phase == .ready)
        #expect(store.newDishes.isEmpty && store.receipts.isEmpty)
        #expect(store.hasMore == false)
    }

    @Test("The dishes read decides the page: failed with a retry, or empty")
    func states() async {
        let reads = Reads()
        reads.failing = ["dishes_by_tag:curry"]
        let store = Self.store(reads)
        await store.loadIfNeeded()
        #expect(store.phase == .failed(TagEditionStore.failureMessage))
        reads.failing = []
        await store.refresh()
        #expect(store.phase == .empty)
    }

    @Test("Follow adds the tag to the set as it stands; Following takes it out; both are counted")
    func follow() async {
        let reads = Reads()
        reads.cravings = [craving("pasta")]
        let log = EventLog()
        let store = Self.store(reads, log: log)
        await store.loadIfNeeded()
        #expect(store.isFollowing == false)
        reads.cravings = [craving("pasta"), craving("ramen")]  // changed elsewhere meanwhile
        await store.toggleFollow()
        #expect(store.isFollowing)
        #expect(reads.setTo.last?.map(\.slug) == ["pasta", "ramen", "curry"])
        #expect(log.first(named: "craving_followed")?.parameters == ["source": "tag_page", "count": "3"])
        await store.toggleFollow()
        #expect(store.isFollowing == false)
        #expect(reads.setTo.last?.map(\.slug) == ["pasta", "ramen"])
        #expect(log.first(named: "craving_unfollowed")?.parameters == ["source": "tag_page", "count": "2"])
    }

    @Test("A refused Follow flips back; signed out the set is never read")
    func refusedAndSignedOut() async {
        let reads = Reads()
        reads.failing = ["set_cravings"]
        let store = Self.store(reads)
        await store.loadIfNeeded()
        await store.toggleFollow()
        #expect(store.isFollowing == false)

        let browsing = Reads()
        let signedOut = Self.store(browsing, signedIn: false)
        await signedOut.loadIfNeeded()
        #expect(browsing.calls.contains("my_cravings") == false)
    }

    @Test("A save made anywhere flips the dish on the page")
    func saves() async {
        let reads = Reads()
        let rendang = dish("Rendang")
        reads.dishes = ["curry": [rendang]]
        let broadcast = SavedDishBroadcast()
        let store = Self.store(reads, broadcast: broadcast)
        await store.loadIfNeeded()
        broadcast.send(dishID: rendang.dishID, isSaved: true)
        #expect(store.top[0].isSaved)
        #expect(store.places[0].dish.isSaved)
    }

    @Test("The route: a ranked See all, and an old route with no page reads as the edition")
    func route() throws {
        #expect(Self.curry.ranked.page == .ranked)
        #expect(Self.curry.ranked.slug == "curry")
        let old = #"{"kind":"style","slug":"curry","label":"Curry"}"#
        let decoded = try JSONDecoder().decode(DishTagRoute.self, from: Data(old.utf8))
        #expect(decoded.page == .edition)
        #expect(Craving(Self.curry).id == "style:curry")
    }

    @Test("The wire: the tag filter is p_kind and p_slug, the slug verbatim")
    func wire() {
        let parameters = FeedEditionClient.tagParameters(Craving(kind: .cuisine, slug: "south-indian", label: "x"))
        #expect(parameters == ["p_kind": .string("cuisine"), "p_slug": .string("south-indian")])
    }
}

// MARK: - What you follow

@MainActor
@Suite("What you follow")
struct FollowingTests {
    fileprivate static func reads() -> Reads {
        let reads = Reads()
        reads.cravings = [craving("curry"), craving("dumplings"), craving("pasta")]
        reads.dishes = ["curry": [dish("Rendang")], "pasta": [dish("Ragù")]]
        return reads
    }

    @Test("The set in shelf order, each with its #1 dish when it has one")
    func rows() async {
        let store = FollowingStore(reads: Self.reads(), city: "melbourne")
        await store.loadIfNeeded()
        #expect(store.rows.map(\.craving.slug) == ["curry", "dumplings", "pasta"])
        #expect(store.rows.map { $0.top?.name } == ["Rendang", nil, "Ragù"])
    }

    @Test("A swipe unfollows with the whole set; a refusal puts the row back")
    func unfollow() async {
        let reads = Self.reads()
        let log = EventLog()
        let store = FollowingStore(reads: reads, city: nil, analytics: log.recorder)
        await store.loadIfNeeded()
        await store.unfollow("style:dumplings")
        #expect(reads.setTo.last?.map(\.slug) == ["curry", "pasta"])
        #expect(log.first(named: "craving_unfollowed")?.parameters == ["source": "following", "count": "2"])
        reads.failing = ["set_cravings"]
        await store.unfollow("style:curry")
        #expect(store.rows.map(\.craving.slug) == ["curry", "pasta"])
    }

    @Test("A drag reorders the shelves")
    func move() async {
        let reads = Self.reads()
        let log = EventLog()
        let store = FollowingStore(reads: reads, city: nil, analytics: log.recorder)
        await store.loadIfNeeded()
        await store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(reads.setTo.last?.map(\.slug) == ["pasta", "curry", "dumplings"])
        #expect(store.rows.map(\.craving.slug) == ["pasta", "curry", "dumplings"])
        #expect(log.first(named: "cravings_reordered")?.parameters == ["count": "3"])
    }

    @Test("Empty, and unreachable")
    func states() async {
        let none = Reads()
        let empty = FollowingStore(reads: none, city: nil)
        await empty.loadIfNeeded()
        #expect(empty.isEmpty)
        let down = Reads()
        down.failing = ["my_cravings"]
        let failed = FollowingStore(reads: down, city: nil)
        await failed.loadIfNeeded()
        #expect(failed.phase == .failed(TagEditionStore.failureMessage))
    }
}
