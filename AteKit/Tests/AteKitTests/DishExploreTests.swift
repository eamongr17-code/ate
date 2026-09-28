import Foundation
import Testing
@testable import AteKit

/// A dish page's "More to explore" and "More like this", and the tag page a chip opens.
@MainActor
@Suite("Dish explore")
struct DishExploreTests {

    private static let dish = UUID()
    private static let place = UUID()

    private static func tag(_ kind: DishTag.Kind, _ label: String) -> DishTag {
        DishTag(kind: kind, slug: label.lowercased(), label: label)
    }

    private static func similar(_ name: String, score: Double? = nil, reviews: Int = 1, id: UUID = UUID()) -> SimilarDish {
        SimilarDish(dishID: id, name: name, restaurantID: place, restaurantName: "Bar Carolina",
                    score: score, reviewCount: reviews)
    }

    // MARK: - The chips

    @Test func chipsPrintStyleThenCuisineThenSuburbThenCity() {
        let tags = [
            Self.tag(.city, "Melbourne"), Self.tag(.cuisine, "Italian"), Self.tag(.style, "Pasta"),
            Self.tag(.suburb, "CBD"), Self.tag(.style, "Handmade"), Self.tag(.diet, "GF")
        ]
        #expect(DishTagOrder.explore(tags).map(\.label) == ["Pasta", "Handmade", "Italian", "CBD", "Melbourne", "GF"])
    }

    @Test func aTagIsOneChipAndAnEmptyLabelIsNone() {
        let tags = [Self.tag(.style, "Pasta"), Self.tag(.style, "Pasta"), DishTag(kind: .style, slug: "x", label: "")]
        #expect(DishTagOrder.explore(tags).map(\.label) == ["Pasta"])
    }

    @Test func aStyleIsPrintedInSentenceCaseAndEveryOtherKindAsSent() {
        #expect(DishTag(kind: .style, slug: "pasta", label: "pasta").title == "Pasta")
        #expect(DishTag(kind: .cuisine, slug: "wine-bar", label: "Wine bar").title == "Wine bar")
        #expect(DishTag(kind: .diet, slug: "gf", label: "GF").title == "GF")
        let route = DishTagRoute(DishTag(kind: .suburb, slug: "fitzroy-melbourne", label: "Fitzroy"))
        #expect(route.slug == "fitzroy-melbourne", "a slug goes back verbatim")
        #expect(route.label == "Fitzroy")
        #expect(DishTagRoute(DishTag(kind: .style, slug: "pasta", label: "pasta")).label == "Pasta")
    }

    @Test func aTagKindThisBuildDoesNotKnowIsDroppedNotFatal() throws {
        let json = Data("""
        [{"kind":"style","slug":"pasta","label":"Pasta"},
         {"kind":"mood","slug":"cosy","label":"Cosy"},
         {"kind":"city","slug":"melbourne","label":"Melbourne"}]
        """.utf8)
        let tags = try DishExploreClient.decodeTags(json)
        #expect(tags.map(\.kind) == [.style, .city])
    }

    // MARK: - The rows

    @Test func aSimilarRowDecodesTheContractShapeWithNoScoreAsNoScore() throws {
        let id = UUID()
        let json = Data("""
        [{"dish_id":"\(id.uuidString.lowercased())","name":"Cacio e pepe",
          "restaurant_id":"\(Self.place.uuidString.lowercased())","restaurant_name":"Bar Liberty",
          "score":null,"review_count":3,"cover_url":null}]
        """.utf8)
        let rows = try PostgRESTDate.decoder.decode([SimilarDish].self, from: json)
        #expect(rows.first?.dishID == id)
        #expect(rows.first?.score == nil, "never a zero")
        #expect(rows.first?.reviewCount == 3)
        #expect(rows.first?.coverURL == nil)
    }

    @Test func aTagsDishesAreBestFirstWithTheUnscoredLast() {
        let low = Self.similar("Low", score: 3.5).tagCursor
        let high = Self.similar("High", score: 4.5).tagCursor
        let unscored = Self.similar("None", score: nil, reviews: 9).tagCursor
        let busier = Self.similar("Busier", score: 4.5, reviews: 5).tagCursor
        let six = Self.similar("Secret", score: 6).tagCursor
        let alpha = Self.similar("alpha", score: 4.5, reviews: 5).tagCursor
        #expect(TagDishCursor.isBefore(six, high), "a secret 6 above a 5")
        #expect(TagDishCursor.isBefore(alpha, busier), "then the name, case-folded")
        #expect(TagDishCursor.isBefore(high, low))
        #expect(TagDishCursor.isBefore(low, unscored), "an unscored dish is last, however many reviews")
        #expect(TagDishCursor.isBefore(busier, high), "the same score: more reviews first")
    }

    // MARK: - The dish page's sections

    @Test func bothSectionsHoldTheirSpaceUntilTheyAnswerThenArriveTogether() async {
        let reads = FakeDishExplore()
        reads.seed(dishID: Self.dish, tags: [Self.tag(.style, "Pasta")], similar: [Self.similar("Rigatoni", score: 4.7)])
        let store = DishExploreStore(dishID: Self.dish, reads: reads)
        #expect(store.isSettled == false)
        #expect(store.showsTags && store.showsSimilar, "held at their final size while they are read")
        await store.load()
        #expect(store.isSettled)
        #expect(store.tags.map(\.label) == ["Pasta"])
        #expect(store.similar.map(\.name) == ["Rigatoni"])
        #expect(reads.similarLimits == [10], "similar_dishes' own default")
    }

    @Test func aSectionWithNothingInItIsNotThere() async {
        let store = DishExploreStore(dishID: Self.dish, reads: FakeDishExplore())
        await store.load()
        #expect(store.showsTags == false)
        #expect(store.showsSimilar == false)
    }

    @Test func aFailedReadIsAnAbsentSectionNotAnError() async {
        let reads = FakeDishExplore()
        reads.seed(dishID: Self.dish, tags: [Self.tag(.city, "Melbourne")])
        reads.failSimilar(true)
        let store = DishExploreStore(dishID: Self.dish, reads: reads)
        await store.load()
        #expect(store.showsTags)
        #expect(store.showsSimilar == false)
    }

    @Test func aRefreshThatFailsKeepsWhatIsOnScreen() async {
        let reads = FakeDishExplore()
        reads.seed(dishID: Self.dish, tags: [Self.tag(.style, "Pasta")], similar: [Self.similar("Rigatoni")])
        let store = DishExploreStore(dishID: Self.dish, reads: reads)
        await store.load()
        reads.failTags(true)
        reads.failSimilar(true)
        await store.refresh()
        #expect(store.tags.count == 1)
        #expect(store.similar.count == 1)
    }

    @Test func theDishIsNeverLikeItselfAndACardIsNeverTwice() async {
        let twin = UUID()
        let reads = FakeDishExplore()
        reads.seed(dishID: Self.dish, similar: [
            Self.similar("Itself", id: Self.dish), Self.similar("Twin", id: twin), Self.similar("Twin", id: twin)
        ])
        let store = DishExploreStore(dishID: Self.dish, reads: reads)
        await store.load()
        #expect(store.similar.map(\.dishID) == [twin])
    }

    @Test func theSectionsAreReadOnce() async {
        let reads = FakeDishExplore()
        let store = DishExploreStore(dishID: Self.dish, reads: reads)
        await store.load()
        await store.load()
        #expect(reads.similarLimits.count == 1)
    }

    // MARK: - The tag page

    @Test func aTagPagePagesByItsKeyset() async {
        let reads = FakeDishExplore()
        let dishes = (0..<45).map { Self.similar("Dish \($0)", score: Double($0 % 10) / 2, reviews: $0) }
        reads.seed(tag: .style, slug: "pasta", dishes: dishes)
        let store = TagDishesStore(tag: DishTagRoute(Self.tag(.style, "Pasta")), reads: reads)
        await store.loadIfNeeded()
        #expect(store.phase == .ready)
        #expect(store.dishes.count == 20)
        await store.loadMore()
        await store.loadMore()
        #expect(store.dishes.count == 45)
        #expect(store.hasReachedEnd)
        #expect(Set(store.dishes.map(\.dishID)).count == 45, "no row twice")
        let expected = dishes.sorted { TagDishCursor.isBefore($0.tagCursor, $1.tagCursor) }.map(\.dishID)
        #expect(store.dishes.map(\.dishID) == expected, "the server's order, untouched")
        #expect(reads.tagCursors.first == .some(nil))
        #expect(reads.tagCursors.count == 3)
        #expect(reads.tagCursors[1] == store.dishes[19].tagCursor, "the next page starts after the last row")
    }

    @Test func aTagWithNoDishesIsEmptyAndAFailedFirstPageSaysSo() async {
        let reads = FakeDishExplore()
        let empty = TagDishesStore(tag: DishTagRoute(Self.tag(.city, "Hobart")), reads: reads)
        await empty.loadIfNeeded()
        #expect(empty.phase == .empty)

        reads.failTagPages(times: 1)
        let failed = TagDishesStore(tag: DishTagRoute(Self.tag(.city, "Hobart")), reads: reads)
        await failed.loadIfNeeded()
        #expect(failed.phase == .failed(message: "Couldn't load these dishes."))
    }

    @Test func aLaterPageThatFailsKeepsTheRowsAndSaysSoInline() async {
        let reads = FakeDishExplore()
        reads.seed(tag: .style, slug: "pasta", dishes: (0..<25).map { Self.similar("Dish \($0)", score: 4) })
        let store = TagDishesStore(tag: DishTagRoute(Self.tag(.style, "Pasta")), reads: reads)
        await store.loadIfNeeded()
        reads.failTagPages(times: 1)
        await store.loadMore()
        #expect(store.dishes.count == 20)
        #expect(store.inlineErrorMessage == "Couldn't load more dishes.")
        await store.loadMore()
        #expect(store.dishes.count == 25)
        #expect(store.inlineErrorMessage == nil)
    }

    // MARK: - Instrumentation

    @Test func theExploreEventsCarryTheirKindAndPosition() {
        #expect(DetailEvents.dishTagOpened(kind: .suburb).name == "dish_tag_opened")
        #expect(DetailEvents.dishTagOpened(kind: .suburb).parameters == ["kind": "suburb"])
        #expect(DetailEvents.similarDishOpened(position: 2).name == "similar_dish_opened")
        #expect(DetailEvents.similarDishOpened(position: 2).parameters == ["position": "2"])
        #expect(DetailEvents.tagDishesViewed(kind: .style).parameters == ["kind": "style"])
    }

    // MARK: - The preview stand-in

    @Test func similarityWeighsStyleOverCuisineOverSuburbOverCity() {
        let pasta = Self.tag(.style, "Pasta"), italian = Self.tag(.cuisine, "Italian")
        let cbd = Self.tag(.suburb, "CBD"), melbourne = Self.tag(.city, "Melbourne")
        let style = Self.similar("Style")
        let cuisine = Self.similar("Cuisine")
        let place = Self.similar("Place")
        let nothing = Self.similar("Nothing")
        let both = Self.similar("Cuisine and place")
        let ranked = DishSimilarity.rank([
            .init(row: place, tags: [cbd, melbourne]),
            .init(row: nothing, tags: [Self.tag(.city, "Sydney")]),
            .init(row: cuisine, tags: [italian]),
            .init(row: both, tags: [italian, cbd]),
            .init(row: style, tags: [pasta])
        ], like: [pasta, italian, cbd, melbourne], excluding: Self.dish)
        #expect(ranked.map(\.name) == ["Style", "Cuisine and place", "Cuisine"],
                "a shared place alone is not enough to be like it")
    }

    @Test func thePreviewDishesHaveTagsAndNeighbours() async throws {
        let service = InMemorySocialService.seededWithSaves()
        let prawn = try #require(service.visibleEntriesEverywhere()
            .flatMap(\.items).first { $0.dishName == "Prawn spaghetti" }?.dishID)
        let tags = try await service.dishTags(dishID: prawn)
        #expect(tags.map(\.title) == ["Pasta", "Seafood", "Italian", "Melbourne"], "no suburb row for the CBD")
        let similar = try await service.similarDishes(dishID: prawn, limit: 10)
        #expect(similar.isEmpty == false)
        #expect(similar.contains { $0.dishID == prawn } == false)
        let pasta = try await service.dishesByTag(kind: .style, slug: "pasta", after: nil, pageSize: 20)
        #expect(pasta.items.contains { $0.dishID == prawn })
    }
}
