import Foundation
import Testing

@testable import AteKit

@Suite("Search query hygiene + telemetry")
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

    // MARK: - ilike patterns

    @Test("a contains-pattern is quoted so commas and parens can't break PostgREST parsing")
    func quotedPattern() {
        #expect(PostgRESTPattern.contains("Pasta, two ways") == "\"%Pasta, two ways%\"")
    }

    @Test("LIKE metacharacters are neutralised — typing '%' must not match the whole table", arguments: [
        ("50%", "\"%50_%\""),
        ("a_b", "\"%a_b%\""),
        ("a*b", "\"%a_b%\""),
        ("a\\b", "\"%a_b%\"")
    ])
    func metacharacters(query: String, pattern: String) {
        #expect(PostgRESTPattern.contains(query) == pattern)
    }

    @Test("an empty or whitespace query produces no pattern at all")
    func emptyPattern() {
        #expect(PostgRESTPattern.contains("") == nil)
        #expect(PostgRESTPattern.contains("   ") == nil)
    }

    @Test("a double quote in the query is escaped, not left to terminate the value")
    func quoteEscaping() {
        #expect(PostgRESTPattern.contains("the \"good\" one") == "\"%the \\\"good\\\" one%\"")
    }

    // MARK: - Telemetry (§11.6)

    @Test("every picker signal has the name growth-lead's funnel expects")
    func eventNames() {
        let subject = SearchSubject.dishes(restaurantID: UUID(), restaurantName: "Chin Chin")
        #expect(SearchEvent.opened(context: .browse, subject: .restaurants).name == "search_opened")
        #expect(SearchEvent.query(subject: subject, length: 3, resultCount: 2, milliseconds: 120).name
            == "search_query")
        #expect(SearchEvent.resultSelected(subject: subject, kind: "place", index: 0).name == "search_result_selected")
        #expect(SearchEvent.createShown(subject: subject).name == "search_create_shown")
        #expect(SearchEvent.createUsed(subject: subject).name == "search_create_used")
        #expect(SearchEvent.zeroResults(subject: subject, queryLength: 7).name == "search_zero_results")
        #expect(SearchEvent.dishCreateFallbackUsed(restaurantID: UUID()).name == "dish_create_fallback_used")
    }

    @Test("search_query carries the four parameters the funnel slices on")
    func queryParameters() {
        let event = SearchEvent.query(subject: .restaurants, length: 4, resultCount: 5, milliseconds: 312)
        #expect(event.parameters == [
            "subject": "restaurants", "length": "4", "result_count": "5", "ms": "312"
        ])
    }

    @Test("the create-fallback counter carries the restaurant it happened at")
    func createFallbackParameters() {
        let restaurantID = UUID()
        #expect(SearchEvent.dishCreateFallbackUsed(restaurantID: restaurantID).parameters
            == ["restaurant_id": restaurantID.uuidString])
    }

    @Test("subject names are stable strings, not a leaked enum description")
    func subjectNames() {
        #expect(SearchSubject.restaurants.telemetryName == "restaurants")
        #expect(SearchSubject.dishes(restaurantID: UUID(), restaurantName: "x").telemetryName == "dishes")
        #expect(SearchSubject.allDishes.telemetryName == "all_dishes")
    }
}
