import Foundation

/// **The tagging half of "Ate with", counted.** Built here so the names and parameters are asserted
/// by tests; sent by the app's recorder.
public enum CompanionEvents {
    /// "Who were you with?" rose — from the composer's With key.
    public static func pickerOpened() -> AnalyticsEvent {
        AnalyticsEvent(name: "ate_with_picker_opened")
    }

    /// People were added to an entry: on a post, or an edit that added someone. Fired at the intent,
    /// not when the server agreed — a tag that waits offline still counts.
    public static func tagged(count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "ate_with_tagged", parameters: ["count": String(max(0, count))])
    }

    /// A tagged person took themselves off somebody's entry ("Remove me").
    public static func removedSelf() -> AnalyticsEvent {
        AnalyticsEvent(name: "ate_with_removed_self")
    }
}
