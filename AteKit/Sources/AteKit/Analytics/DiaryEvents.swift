import Foundation

/// The diary's two funnel signals. Built here (so the names and parameters are asserted by tests
/// and can never drift silently) and sent by the app target's ``AnalyticsRecorder``.
///
/// Only two, deliberately: the question the diary answers for the funnel is "do people come back to
/// look at what they logged, and does it send them anywhere?". Page-load volume is already
/// answerable from the feed's equivalent.
public enum DiaryEvents {
    /// The diary became visible. Once per appearance, not once per page.
    public static func diaryViewed() -> AnalyticsEvent {
        AnalyticsEvent(name: "diary_viewed")
    }

    /// An entry was tapped. `dish_id` is the dish the tap *opens* — the canonical id, so a review of
    /// a since-merged dish reports the survivor and matches the `dish_detail_viewed` that follows.
    public static func diaryEntryTapped(dishID: UUID) -> AnalyticsEvent {
        AnalyticsEvent(name: "diary_entry_tapped", parameters: ["dish_id": dishID.uuidString.lowercased()])
    }
}
