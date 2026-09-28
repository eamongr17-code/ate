import Foundation
import Testing

@testable import AteKit

@Suite("Search query hygiene")
struct SearchQueryTests {

    // MARK: - Gating (§11.1, §11.3)

    @Test("restaurants need 2 characters — 1 char changes nothing and fires no request", arguments: [
        ("", false), ("c", false), (" c ", false), ("ch", true), ("chin chin", true)
    ])
    func restaurantGate(raw: String, searches: Bool) {
        #expect(SearchQueryPolicy(subject: .restaurants).shouldSearch(raw) == searches)
    }

    @Test("dishes within a restaurant filter from 1 character", arguments: [
        ("", false), ("b", true), ("  b  ", true)
    ])
    func dishGate(raw: String, searches: Bool) {
        let policy = SearchQueryPolicy(subject: .dishes(restaurantID: UUID(), restaurantName: "Chin Chin"))
        #expect(policy.shouldSearch(raw) == searches)
    }

    @Test("the global Dishes scope needs 2 characters — a 1-char catalogue-wide LIKE is a scan")
    func globalDishGate() {
        #expect(SearchQueryPolicy(subject: .allDishes).shouldSearch("b") == false)
        #expect(SearchQueryPolicy(subject: .allDishes).shouldSearch("br"))
    }

    @Test("the query sent is trimmed; below the threshold nothing is sent at all")
    func normalisation() {
        let policy = SearchQueryPolicy(subject: .restaurants)
        #expect(policy.query(from: "  chin chin  ") == "chin chin")
        #expect(policy.query(from: " c ") == nil)
    }

    @Test("the debounce is the 250ms cost lever from places-integration.md")
    func debounce() {
        #expect(SearchQueryPolicy.debounce == .milliseconds(250))
    }

    @Test("subject names are stable strings, not a leaked enum description")
    func subjectNames() {
        #expect(SearchSubject.restaurants.telemetryName == "restaurants")
        #expect(SearchSubject.dishes(restaurantID: UUID(), restaurantName: "x").telemetryName == "dishes")
        #expect(SearchSubject.allDishes.telemetryName == "all_dishes")
    }
}
