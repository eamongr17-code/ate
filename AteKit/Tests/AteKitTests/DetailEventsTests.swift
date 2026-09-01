import Foundation
import Testing

@testable import AteKit

@Suite("Detail funnel events")
struct DetailEventsTests {
    @Test("event names and parameter keys are the ones the funnel is defined on")
    func eventContract() {
        let dishID = UUID()
        let dish = DetailEvents.dishDetailViewed(dishID: dishID, source: .feed)
        #expect(dish.name == "dish_detail_viewed")
        #expect(dish.parameters == ["dish_id": dishID.uuidString.lowercased(), "source": "feed"])

        let restaurantID = UUID()
        let restaurant = DetailEvents.restaurantDetailViewed(restaurantID: restaurantID, source: .diary)
        #expect(restaurant.name == "restaurant_detail_viewed")
        #expect(restaurant.parameters == ["restaurant_id": restaurantID.uuidString.lowercased(), "source": "diary"])

        #expect(DetailEvents.logCTATapped(from: .dishDetail).name == "log_cta_tapped")
        #expect(DetailEvents.logCTATapped(from: .dishDetail).parameters == ["from": "dish_detail"])
        #expect(DetailEvents.logCTATapped(from: .restaurantDetail).parameters == ["from": "restaurant_detail"])
    }

    @Test("ids are lowercased so an event value pastes straight into a Postgres query")
    func identifiersMatchPostgres() {
        let id = UUID()
        let value = DetailEvents.dishDetailViewed(dishID: id, source: .unknown).parameters["dish_id"]
        #expect(value == value?.lowercased())
        #expect(value?.contains("-") == true)
    }

    @Test("every entry point the app can navigate from has a stable wire value")
    func sourceValues() {
        #expect(DetailSource.allCases.map(\.rawValue) == ["feed", "search", "diary", "receipt", "unknown"])
    }
}
