import Foundation
import Testing

@testable import AteKit

@Suite("Search scopes and windows")
struct SearchScopeTests {

    @Test("the four segments are the artboard's four, in its order")
    func segments() {
        #expect(SearchScope.allCases.map(\.title) == ["Places", "Dishes", "People", "Saved"])
    }

    @Test("every scope searches from two characters — the server's own floor")
    func minimumLengths() {
        #expect(SearchScope.allCases.allSatisfy { $0.minimumQueryLength == 2 })
    }

    @Test("only Places and Saved have anything to show before a key is pressed")
    func standingLists() {
        #expect(SearchScope.places.hasStandingList)
        #expect(SearchScope.saved.hasStandingList)
        #expect(SearchScope.dishes.hasStandingList == false)
        #expect(SearchScope.people.hasStandingList == false)
    }

    @Test("the scope's policy is the picker's policy, with the scope's own gate")
    func policy() {
        let dishes = SearchQueryPolicy(scope: .dishes)
        #expect(dishes.query(from: " d ") == nil)
        #expect(dishes.query(from: "  duck  ") == "duck")

        // One letter on the shelf is not a filter; it is still the whole shelf.
        let saved = SearchQueryPolicy(scope: .saved)
        #expect(saved.query(from: "r") == nil)
        #expect(saved.query(from: "ro") == "ro")
    }

    // MARK: - The wire, mapped

    private func decode<Row: Decodable>(_ json: String, as type: Row.Type) throws -> [Row] {
        try PostgRESTDate.decoder.decode([Row].self, from: Data(json.utf8))
    }

    @Test("a place row prints its locality and its average as sent — a null locality is no suburb")
    func placeRows() throws {
        let rows = try decode("""
        [{"restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","name":"Tipo 00","cuisine":"Italian",
          "locality":"Melbourne","avg_rating":4.3,"review_count":18,"people_count":6,"dish_count":9,
          "cover_url":null,"match_tier":1},
         {"restaurant_id":"2f2e3d4c-5b6a-4798-8899-aabbccddeeff","name":"Tipo Cafe","cuisine":null,
          "locality":null,"avg_rating":null,"review_count":0,"people_count":0,"dish_count":0,
          "cover_url":null,"match_tier":2}]
        """, as: SearchPlaceRow.self)

        let page = SearchPage.of(rows, limit: 2, row: PlaceResult.init, cursor: SearchCursor.init)

        #expect(page.rows.map(\.name) == ["Tipo 00", "Tipo Cafe"], "server order, never re-sorted")
        #expect(page.rows[0].locality == "Melbourne")
        #expect(page.rows[0].score == 4.3)
        #expect(page.rows[1].locality == nil)
        #expect(page.rows[1].score == nil, "nobody's score is an empty star, not a zero")
        // A full page names the LAST row's whole key as the next cursor.
        #expect(page.next == .place(
            matchTier: 2, reviewCount: 0, name: "Tipo Cafe",
            id: UUID(uuidString: "2f2e3d4c-5b6a-4798-8899-aabbccddeeff")!
        ))
    }

    @Test("a short read is the last page")
    func shortReadEnds() throws {
        let rows = try decode("""
        [{"restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","name":"Tipo 00","cuisine":null,
          "locality":"Melbourne","avg_rating":4.3,"review_count":18,"people_count":6,"dish_count":9,
          "cover_url":null,"distance_m":184.27}]
        """, as: NearbyPlaceRow.self)

        let full = SearchPage.of(rows, limit: 1, row: PlaceResult.init, cursor: SearchCursor.init)
        let short = SearchPage.of(rows, limit: 20, row: PlaceResult.init, cursor: SearchCursor.init)

        #expect(full.next == .nearby(
            distanceMeters: 184.27, id: UUID(uuidString: "1f2e3d4c-5b6a-4798-8899-aabbccddeeff")!
        ))
        #expect(short.isLastPage)
    }

    @Test("a dish row is the whole row in one call: dish, place, suburb, cover, score")
    func dishRows() throws {
        let rows = try decode("""
        [{"dish_id":"3f2e3d4c-5b6a-4798-8899-aabbccddeeff","dish_name":"Tagliatelle al ragù",
          "restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","restaurant_name":"Tipo 00",
          "restaurant_locality":"Melbourne","score":4.6,"review_count":5,"scored_count":4,
          "people_count":4,"cover_url":"https://x/y.jpg","match_tier":2},
         {"dish_id":"4f2e3d4c-5b6a-4798-8899-aabbccddeeff","dish_name":"Penne al ragù",
          "restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","restaurant_name":"Di Stasio",
          "restaurant_locality":null,"score":null,"review_count":1,"scored_count":0,
          "people_count":1,"cover_url":null,"match_tier":2}]
        """, as: SearchDishRow.self)

        let page = SearchPage.of(rows, limit: 20, row: DishResult.init, cursor: SearchCursor.init)

        #expect(page.rows[0].name == "Tagliatelle al ragù", "the menu's spelling comes back intact")
        #expect(page.rows[0].restaurantName == "Tipo 00")
        #expect(page.rows[0].coverURL?.absoluteString == "https://x/y.jpg")
        #expect(page.rows[1].score == nil)
        #expect(page.rows[1].coverURL == nil)
        #expect(page.isLastPage)
    }

    @Test("a person row carries its avatar and whether it is you")
    func personRows() throws {
        let rows = try decode("""
        [{"user_id":"5f2e3d4c-5b6a-4798-8899-aabbccddeeff","username":"crumbsmelb","name":"Jess Okafor",
          "avatar_url":null,"city":"Melbourne","is_me":false,"match_tier":1}]
        """, as: SearchPersonRow.self)

        let page = SearchPage.of(rows, limit: 1, row: PersonResult.init, cursor: SearchCursor.init)

        #expect(page.rows[0].handle == "crumbsmelb")
        #expect(page.rows[0].name == "Jess Okafor")
        #expect(page.rows[0].isMe == false)
        #expect(page.next == .person(
            matchTier: 1, username: "crumbsmelb", id: UUID(uuidString: "5f2e3d4c-5b6a-4798-8899-aabbccddeeff")!
        ))
    }

    @Test("a saved row is the shelf's own value, labelled by its locality and never its city")
    func savedRows() throws {
        let rows = try decode("""
        [{"dish_id":"3f2e3d4c-5b6a-4798-8899-aabbccddeeff","dish_name":"Roti canai",
          "restaurant_id":"1f2e3d4c-5b6a-4798-8899-aabbccddeeff","restaurant_name":"Mamak",
          "restaurant_city":"366 Lonsdale St, Melbourne VIC 3000","restaurant_locality":"Melbourne",
          "dish_score":4.2,"dish_cover_url":"https://x/a.jpg","source_entry_id":null,
          "source_user_id":null,"source_username":null,"saved_at":"2026-09-20T09:30:00.123456+00:00",
          "cover_url":"https://x/a.jpg"}]
        """, as: SearchSavedRow.self)

        let page = SearchPage.of(rows, limit: 1, row: SavedDish.init, cursor: SearchCursor.init)
        let dish = try #require(page.rows.first)

        #expect(dish.restaurantCity == "Melbourne", "the street line must never be printed")
        #expect(dish.dishScore == 4.2)
        #expect(dish.sourceUsername == nil, "a save from a gone author keeps the dish, loses the byline")
        #expect(page.next == .saved(savedAt: dish.savedAt, dishID: dish.dishID))
    }
}
