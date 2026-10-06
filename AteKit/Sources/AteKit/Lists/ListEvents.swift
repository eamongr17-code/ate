import Foundation

/// **Lists, counted.** Built here so the names and parameters are asserted by tests; sent by the
/// app's recorder. Fired when the server agreed, except `list_shared`, which the share sheet fires.
public enum ListEvents {
    public static func created() -> AnalyticsEvent {
        AnalyticsEvent(name: "list_created")
    }

    /// A New list affordance was tapped — the shelf's dashed card, or the glass group's list-plus.
    public static func ctaTapped(from source: CTASource) -> AnalyticsEvent {
        AnalyticsEvent(name: "list_cta_tapped", parameters: ["source": source.rawValue])
    }

    public enum CTASource: String, Sendable {
        /// The dashed New list card first on the Lists shelf.
        case shelf
        /// The list-plus in the Journal's glass group.
        case glass
    }

    public static func renamed() -> AnalyticsEvent {
        AnalyticsEvent(name: "list_renamed")
    }

    /// `items` is how many dishes the list held when it went.
    public static func deleted(items: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "list_deleted", parameters: ["items": String(max(0, items))])
    }

    /// Dishes added in one go — the picker's "Add N dishes", or one tick on the Add to a list sheet.
    public static func itemAdded(count: Int, from source: AddSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "list_item_added", parameters: [
            "count": String(max(0, count)), "from": source.rawValue
        ])
    }

    public enum AddSource: String, Sendable {
        /// The list page's picker.
        case picker
        /// The Add to a list sheet, from a dish anywhere.
        case sheet
    }

    /// `undone` — sent again as `true` when Undo put it back.
    public static func itemRemoved(listSize: Int, undone: Bool = false) -> AnalyticsEvent {
        AnalyticsEvent(name: "list_item_removed", parameters: [
            "list_size": String(max(0, listSize)), "undone": undone ? "true" : "false"
        ])
    }

    public static func reordered(listSize: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "list_reordered", parameters: ["list_size": String(max(0, listSize))])
    }

    /// The share image was handed to the system sheet. `lines` is how many dishes it printed.
    public static func shared(lines: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "list_shared", parameters: ["lines": String(max(0, lines))])
    }
}

/// **Searching your own journal, counted.**
public enum JournalSearchEvents {
    /// The magnifier opened the field.
    public static func opened() -> AnalyticsEvent {
        AnalyticsEvent(name: "journal_search_opened")
    }

    /// A completed, debounced query's first page. Once per query, not per page; never the words.
    public static func searched(queryLength: Int, resultCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "journal_searched", parameters: [
            "query_length": String(max(0, queryLength)),
            "result_count": bucket(resultCount)
        ])
    }

    /// A result was opened. `position` is its 1-based place in the results.
    public static func resultOpened(position: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "journal_search_result_opened", parameters: ["position": String(max(1, position))])
    }

    /// The first page's size, bucketed: a page is at most 20, so `20+` means "more to page".
    public static func bucket(_ count: Int) -> String {
        switch count {
        case ..<1: "0"
        case 1: "1"
        case 2...5: "2-5"
        case 6...19: "6-19"
        default: "20+"
        }
    }
}
