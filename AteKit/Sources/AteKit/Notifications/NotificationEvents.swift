import Foundation

/// **"Ate with", heard about and answered** — the notifications funnel, built here so the names and
/// parameters are asserted by tests: `notifications_opened → ate_with_opened → ate_with_posted`, with
/// the X (`notification_dismissed`) and the one system ask (`push_permission_result`) beside it.
public enum NotificationEvents {
    /// Where a tag was opened from: a push, a tap on its row, or the row's "Add yours" pill.
    public enum Source: String, Sendable, CaseIterable {
        case push, list, pill
    }

    /// The list was shown. `unread` is the bell's number at the moment it was opened.
    public static func notificationsOpened(unread: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "notifications_opened", parameters: ["unread": String(unread)])
    }

    /// A tag's scoring sheet was opened.
    public static func ateWithOpened(from source: Source) -> AnalyticsEvent {
        AnalyticsEvent(name: "ate_with_opened", parameters: ["from": source.rawValue])
    }

    /// The person posted their own entry from a tag: how many of the tagger's dishes they scored,
    /// dropped, or kept unscored, and whether they wrote anything.
    public static func ateWithPosted(
        scored: Int, removed: Int, unscored: Int, hasWords: Bool, copied: Bool = false
    ) -> AnalyticsEvent {
        AnalyticsEvent(name: "ate_with_posted", parameters: [
            "scored": String(scored),
            "removed": String(removed),
            "unscored": String(unscored),
            "has_words": hasWords ? "true" : "false",
            "copied": copied ? "true" : "false"
        ])
    }

    /// "Copy their review" was tapped on a tag: how many scores it filled, and whether words came too.
    public static func ateWithReviewCopied(scores: Int, hasWords: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "ate_with_review_copied", parameters: [
            "scores": String(scores),
            "has_words": hasWords ? "true" : "false"
        ])
    }

    /// A row left the list without an answer: a swipe's Clear (`clear`), or Decline (`decline`).
    public static func notificationDismissed(how: Dismissal) -> AnalyticsEvent {
        AnalyticsEvent(name: "notification_dismissed", parameters: ["how": how.rawValue])
    }

    public enum Dismissal: String, Sendable {
        case clear
        case decline
    }

    /// The system's notification prompt was answered. `trigger` is what asked: opening the list, or tagging someone.
    public static func pushPermissionResult(granted: Bool, trigger: PermissionTrigger) -> AnalyticsEvent {
        AnalyticsEvent(name: "push_permission_result", parameters: [
            "granted": granted ? "true" : "false",
            "trigger": trigger.rawValue
        ])
    }

    /// The Journal's Notifications page was opened: how many rows each of its two groups held.
    public static func notificationsSectionOpened(tags: Int, photos: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "notifications_section_opened", parameters: [
            "tags": String(max(0, tags)),
            "photos": String(max(0, photos))
        ])
    }

    /// The photos group's heading was tapped for every sitting: how many there were.
    public static func photoSuggestionsAllOpened(count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "photo_suggestions_all_opened", parameters: ["count": String(max(0, count))])
    }

    /// A nearby-place chip on a photo sitting was tapped. `rank` is its position, from 1.
    public static func photoPlaceChipTapped(rank: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "photo_place_chip_tapped", parameters: ["rank": String(rank)])
    }

    public enum PermissionTrigger: String, Sendable {
        case notifications
        case tag
        /// A printed receipt, once the camera roll's ask is behind it.
        case receipt
        /// Settings → Notifications, while iOS had never asked.
        case settings
    }
}
