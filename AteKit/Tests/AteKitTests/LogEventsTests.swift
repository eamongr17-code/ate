import Foundation
import Testing

@testable import AteKit

@Suite("Log funnel events (§8)")
struct LogEventsTests {
    @Test("the funnel's names are exactly the ones the brief specifies")
    func names() {
        let funnel: [LogEvent] = [
            .opened(entry: .tab),
            .whereResolved(source: .nearby, millisecondsFromOpen: 1_200),
            .whatResolved(source: .menu, dishIndex: 0),
            .ratingSet(value: 4.5, method: .drag, variant: .inlineOnCard),
            .dishAdded(dishIndex: 1),
            .dishRemoved(dishIndex: 1),
            .posted(dishCount: 2, hasNote: true, hasPhoto: false, secondsFromOpen: 13),
            .postFailed(reason: "offline", dishCount: 2, attempt: 1),
            .abandoned(step: .canvas, dishCount: 1, savedDraft: true),
            .draftResumed(ageMinutes: 20),
            .receiptShown(dishCount: 2),
            .receiptShared(dishCount: 2, activityType: "com.apple.UIKit.activity.Message")
        ]
        #expect(funnel.map(\.name) == [
            "log_opened", "log_where_resolved", "log_what_resolved", "log_rating_set",
            "log_dish_added", "log_dish_removed", "log_posted", "log_post_failed",
            "log_abandoned", "log_draft_resumed", "receipt_shown", "receipt_shared"
        ])
    }

    @Test("log_posted carries seconds_from_open — the friction north-star")
    func postedCarriesTheNorthStar() {
        let event = LogEvent.posted(dishCount: 2, hasNote: true, hasPhoto: false, secondsFromOpen: 13)
        #expect(event.parameters == [
            "dish_count": "2",
            "has_note": "true",
            "has_photo": "false",
            "seconds_from_open": "13"
        ])
    }

    @Test("a score is stringified as 4 / 4.5, never 4.500000 and never locale-decimal", arguments: [
        (4.0, "4"), (4.5, "4.5"), (0.5, "0.5"), (5.0, "5")
    ])
    func scoreFormatting(value: Double, expected: String) {
        let event = LogEvent.ratingSet(value: value, method: .tap, variant: .rateOnSelect)
        #expect(event.parameters["value"] == expected)
        #expect(event.parameters["variant"] == "rate_on_select")
        #expect(event.parameters["method"] == "tap")
    }

    @Test("resolution sources use the wire spellings")
    func sourceSpellings() {
        #expect(LogWhereSource.allCasesForTest.map(\.rawValue)
            == ["nearby", "recent", "search_place", "search_manual", "added_manual"])
        #expect(LogWhatSource.history.rawValue == "history")
        #expect(LogWhatSource.newDish.rawValue == "new_dish")
        #expect(LogStep.whereStep.rawValue == "where")
        #expect(LogEntryKind.resume.rawValue == "resume")
    }

    @Test("post failures collapse to a countable reason, never a raw server body")
    func failureReasons() {
        #expect(LogPostFailureReason.of(URLError(.notConnectedToInternet)) == "offline")
        #expect(LogPostFailureReason.of(URLError(.timedOut)) == "timeout")
        #expect(LogPostFailureReason.of(URLError(.badServerResponse)) == "network")
        #expect(LogPostFailureReason.of(AteAPIError.notAuthenticated) == "auth")
        #expect(LogPostFailureReason.of(TestError()) == "server")
    }

    private struct TestError: Error {}
}

extension LogWhereSource {
    /// Not `CaseIterable` in the shipping type — the order below is the funnel's documented order and
    /// exists only so this test can assert the whole set at once.
    static var allCasesForTest: [LogWhereSource] {
        [.nearby, .recent, .searchPlace, .searchManual, .addedManual]
    }
}
