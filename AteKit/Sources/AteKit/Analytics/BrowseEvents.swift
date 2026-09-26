import Foundation

/// Round 4's browse signals: the journal's filter and sort, and the photo preview. Built here so the
/// names and parameters are asserted by tests; sent by the app's ``AnalyticsRecorder``.
///
/// Both carry the exploration `variant` they were seen in, so the TestFlight numbers can speak to
/// which entry point and which preview Eamon should keep.
public enum BrowseEvents {
    /// The journal was re-queried: a sort picked, a filter added or a pill removed. Names only —
    /// never a place, a score or a month, which are the person's own record.
    public static func journalQueried(_ query: JournalQuery, variant: String, resultCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "journal_queried", parameters: [
            "sort": query.sort.rawValue,
            "filters": query.filterNames,
            "variant": variant,
            "result_count": String(resultCount)
        ])
    }

    /// The filter surface was opened — the sheet (A) or a pill's menu (B).
    public static func journalFilterOpened(variant: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "journal_filter_opened", parameters: ["variant": variant])
    }

    /// A photo was opened large. `photo_count` is how many the viewer can swipe through.
    public static func photoPreviewOpened(variant: String, photoCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "photo_preview_opened", parameters: [
            "variant": variant,
            "photo_count": String(photoCount)
        ])
    }

    /// The entry page drew from the card it was opened with, before its own read answered.
    /// `seeded=false` is an entry opened by id alone (a dish page's review), which drew skeletons.
    public static func entryOpened(seeded: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "entry_opened", parameters: ["seeded": seeded ? "true" : "false"])
    }
}
